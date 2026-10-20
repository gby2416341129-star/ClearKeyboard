import Foundation
import CoreML

// The standalone check never starts the iOS loader or memory observer.
// This link stub is unreachable here; actual prediction uses real Core ML.
func cr_trim_sentence_cache() {}

@main struct WorkerChecks {
    static func main() throws {
        func expect(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let failureURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: directory.appendingPathComponent("ClearSentence25M.mlmodelc"), configuration: configuration)
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as! [String: String]
        let vocabulary = try JSONSerialization.jsonObject(with: metadata["vocab"]!.data(using: .utf8)!) as! [String]
        let worker = CoreMLSentence()
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("CoreML25M-validation.json"))) as! [String: Any]
        let validationSequences = fixture["sequences"] as! [String]
        let numerical = fixture["expected"] as! [[String: Any]]
        let checked = try worker.checkedPrefix(directory: directory, function: "step", sequences: validationSequences, expected: numerical, units: .cpuOnly)
        expect(checked?.numericalValidation == true, "High-precision fallback did not pass the production selector")
        let incorrect = numerical.map { row -> [String: Any] in var changed = row; changed["value"] = (row["value"] as! Double) + 1; return changed }
        let rejected = try worker.checkedPrefix(directory: directory, function: "step", sequences: validationSequences, expected: incorrect, units: .cpuOnly)
        expect(rejected?.numericalValidation == false && rejected?.enabled == false,
            "Production selector enabled a backend that failed numerical validation")
        let faster = try worker.checkedPrefix(directory: directory, function: "step_fast", sequences: validationSequences, expected: numerical, units: .cpuOnly)
        let checkedScore = try worker.checkedScorer(directory: directory, vocabulary: vocabulary, metadata: checked!.metadata, units: .cpuOnly)
        expect(checkedScore?.numericalValidation == true, "Whole-sentence selector failed source verification")
        let preciseScore = try worker.checkedScorer(directory: directory, vocabulary: vocabulary, metadata: checked!.metadata, units: .cpuOnly, function: "score_f32")
        expect(preciseScore?.numericalValidation == true, "Float32 sentence fallback failed source verification")
        let selectedScore = worker.chooseScorer(directory: directory, vocabulary: vocabulary, metadata: checked!.metadata, units: .cpuOnly)
        if let selectedScore {
            expect(selectedScore.numericalValidation && selectedScore.withinBudget && selectedScore.enabled,
                "Selection retained a slow or inaccurate scoring function")
        }
        // CI hardware may reject both functions under the shipping 10 ms gate.
        // Exercise successful selection with a test-only allowance as well;
        // its prediction still uses the actual model and unchanged numerics.
        let selectedForTest = worker.chooseScorer(directory: directory, vocabulary: vocabulary, metadata: checked!.metadata, units: .cpuOnly, limitMS: 1000)
        expect(selectedForTest?.enabled == true && selectedForTest?.numericalValidation == true,
            "Successful model selection could not retain a verified scorer")
        worker.prefixState = try CoreMLPrefixState(model: model, vocabulary: vocabulary)
        worker.ready = true
        let sequences = ["我们明天再讨论", "你今天吃饭了吗", "他们已经回家了", "她正在准备晚饭"]
        var deadlines = 0
        for prefix in sequences {
            let output = worker.next([prefix], milliseconds: 0.25, cancelled: { false })
            expect(output == nil, "A deliberately expired request returned values")
            worker.queue.sync {}
            worker.lock.lock(); let ready = worker.ready, failures = worker.failures; worker.lock.unlock()
            expect(ready && failures == 0, "Ordinary deadlines disabled a healthy model")
            deadlines += 1
        }
        let reference = try worker.queue.sync { try worker.prefixState!.next([sequences[0]], abandoned: { false })! }
        let count = worker.queue.sync { worker.prefixState!.predictionCount }
        let cached = worker.next([sequences[0]], milliseconds: 8, cancelled: { false })
        expect(cached == reference, "A healthy model did not recover after deadline pressure")
        worker.queue.sync {}
        expect(worker.prefixState!.predictionCount == count, "A cached recovery ran the model again")
        expect(worker.next([sequences[0]], milliseconds: 8, cancelled: { true }) == nil,
            "A cancelled call returned values")
        expect(worker.failures == 0 && worker.ready, "Cancellation changed model health")

        // A model whose required feature is missing causes a real Core ML
        // prediction error, so this checks the exception path rather than
        // calling a fault counter directly.
        let bad = try MLModel(contentsOf: failureURL, configuration: configuration)
        let goodState = worker.prefixState!
        func injectBadState() throws {
            let state = try CoreMLPrefixState(model: bad, vocabulary: vocabulary)
            worker.queue.sync { worker.prefixState = state }
        }
        try injectBadState()
        expect(worker.next(["我"], milliseconds: 8, cancelled: { false }) == nil, "A faulty model returned values")
        worker.queue.sync {}
        expect(worker.failures == 1 && worker.ready, "A real runtime fault was not counted")
        worker.queue.sync { worker.prefixState = goodState }
        expect(worker.next([sequences[0]], milliseconds: 8, cancelled: { false }) == reference,
            "Recovery could not return the original values")
        worker.queue.sync {}
        expect(worker.failures == 0 && worker.ready, "Successful prediction did not reset consecutive faults")
        try injectBadState()
        for number in 1...3 {
            expect(worker.next(["我"], milliseconds: 8, cancelled: { false }) == nil, "A runtime fault returned a partial result")
            worker.queue.sync {}
            expect(worker.failures == number, "Real consecutive faults were lost")
        }
        expect(!worker.ready, "Repeated real model faults did not disable the backend")
        let scoreConfiguration = MLModelConfiguration(); scoreConfiguration.computeUnits = .cpuOnly; scoreConfiguration.functionName = "score"
        let scoreModel = try MLModel(contentsOf: directory.appendingPathComponent("ClearSentence25M.mlmodelc"), configuration: scoreConfiguration)
        let scoreState = try CoreMLCandidateScorer(model: scoreModel, vocabulary: vocabulary)
        worker.queue.sync { worker.candidateScorer = scoreState }
        worker.lock.lock(); worker.scoreReady = true; worker.failures = 0; worker.lock.unlock()
        let sentences = Array(sequences.prefix(4))
        for _ in 0..<4 {
            worker.queue.sync { scoreState.clearScores() }
            expect(worker.score(sentences, milliseconds: 0.21, cancelled: { false }) == nil,
                "A score call ignored its deadline")
            worker.queue.sync {}
            expect(worker.scoreReady && worker.failures == 0, "A score deadline disabled a healthy model")
        }
        let scoreReference = try worker.queue.sync { try scoreState.score(sentences, abandoned: { false })! }
        let scoreCalls = scoreState.predictionCount
        expect(worker.score(sentences, milliseconds: 12, cancelled: { false }) == scoreReference,
            "Scoring did not recover through its complete-result cache")
        worker.queue.sync {}
        expect(scoreState.predictionCount == scoreCalls, "Score recovery replayed prediction")
        expect(worker.score(sentences, milliseconds: 12, cancelled: { true }) == nil && worker.failures == 0,
            "Cancelled score call affected model health")
        let badScorer = try CoreMLCandidateScorer(model: bad, vocabulary: vocabulary)
        worker.queue.sync { worker.candidateScorer = badScorer }
        for number in 1...3 {
            expect(worker.score(["我们"], milliseconds: 12, cancelled: { false }) == nil,
                "A score runtime error returned partial results")
            worker.queue.sync {}
            expect(worker.failures == number, "Score runtime exceptions were not counted")
        }
        expect(!worker.scoreReady, "Three real score faults did not disable scoring")
        let report: [String: Any] = ["status": "passed", "deadlineRequests": deadlines,
            "healthyAfterDeadlines": true, "cachedRecoveryWithoutPrediction": true,
            "cancelDoesNotCountAsFault": true, "actualRuntimeErrorCounted": true,
            "successResetsConsecutiveFaults": true, "threeRealFaultsDisableBackend": true,
            "wholeSentenceDeadlineRequests": 4, "wholeSentenceCachedRecovery": true,
            "wholeSentenceRealFaultsDisableBackend": true,
            "highPrecisionSelectorPassed": true, "numericalFailureCannotEnableBackend": true,
            "fastPrefixNumericalValidation": faster?.numericalValidation ?? false,
            "fastPrefixMaximumError": faster?.maximumError ?? -1,
            "scoringFunctionSelectedOnCPU": selectedScore?.function ?? "none_within_budget",
            "successfulSelectionWithTestOnlyAllowance": selectedForTest?.function ?? "failed",
            "scope": "macOS real Core ML CPU_ONLY and the production worker method; no iOS runtime, ANE or phone latency"]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
