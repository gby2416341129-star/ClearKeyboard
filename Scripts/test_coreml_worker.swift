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
        let report: [String: Any] = ["status": "passed", "deadlineRequests": deadlines,
            "healthyAfterDeadlines": true, "cachedRecoveryWithoutPrediction": true,
            "cancelDoesNotCountAsFault": true, "actualRuntimeErrorCounted": true,
            "successResetsConsecutiveFaults": true, "threeRealFaultsDisableBackend": true,
            "scope": "macOS real Core ML CPU_ONLY and the production worker method; no iOS runtime, ANE or phone latency"]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
