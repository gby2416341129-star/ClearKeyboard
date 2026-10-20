import Foundation
import CoreML

@main struct ScorerChecks {
    static func main() throws {
        func expect(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let config = MLModelConfiguration(); config.computeUnits = .cpuOnly; config.functionName = "score"
        let model = try MLModel(contentsOf: directory.appendingPathComponent("ClearSentence25M.mlmodelc"), configuration: config)
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as! [String: String]
        let vocabulary = try JSONSerialization.jsonObject(with: metadata["vocab"]!.data(using: .utf8)!) as! [String]
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("CoreML25M-score-validation.json"))) as! [String: Any]
        let rows = reference["rows"] as! [[String: Any]], texts = rows.map { $0["text"] as! String }
        let state = try CoreMLCandidateScorer(model: model, vocabulary: vocabulary)
        var maximumError = 0.0
        for start in stride(from: 0, to: 8, by: 4) {
            let output = try state.score(Array(texts[start..<start + 4]), abandoned: { false })!
            for row in 0..<4 { maximumError = max(maximumError, abs(Double(output[row]) - (rows[start + row]["score"] as! Double))) }
        }
        expect(maximumError < 0.025, "Whole-candidate scores differ from independent native int8 inference")
        let expected = try state.score(Array(texts.prefix(4)), abandoned: { false })!
        let calls = state.predictionCount
        let reverse = try state.score(Array(texts.prefix(4).reversed()), abandoned: { false })!
        let duplicate = try state.score([texts[0], texts[0]], abandoned: { false })!
        expect(reverse == Array(expected.reversed()) && duplicate == [expected[0], expected[0]], "Ordering or duplicate rows changed scores")
        expect(state.predictionCount == calls, "Complete cached scalar scores reran inference")
        for invalid in [[], [""], ["🦄"], [String(repeating: "我", count: 17)], Array(repeating: texts[0], count: 5)] as [[String]] {
            expect(try state.score(invalid, abandoned: { false }) == nil, "Invalid input returned partial scores")
        }
        expect(try state.score(["还没有见过"], abandoned: { true }) == nil, "Cancelled request predicted")
        expect(state.predictionCount == calls, "Invalid or pre-cancelled request entered the model")
        state.clearScores(); var checkpoints = 0
        let interrupted = try state.score(Array(texts.prefix(4)), abandoned: { checkpoints += 1; return checkpoints >= 3 })
        expect(interrupted == nil && state.cachedSentences == 4, "Interrupted call exposed values or discarded completed inference")
        let afterCancel = state.predictionCount
        expect(try state.score(Array(texts.prefix(4)), abandoned: { false }) == expected, "Completed cancelled scores could not be reused")
        expect(state.predictionCount == afterCancel, "Recovery replayed finished prediction")
        for value in 0..<150 {
            let text = (0..<8).map { (value & (1 << $0)) == 0 ? "你" : "我" }.joined()
            expect(try state.score([text], abandoned: { false }) != nil, "Cache pressure lost a score")
            expect(state.cachedSentences <= 128, "Scalar cache exceeded its bound")
        }
        let regenerated = try state.score(Array(texts.prefix(4)), abandoned: { false })!
        expect(zip(regenerated, expected).allSatisfy { abs($0.0 - $0.1) < 0.0001 }, "Cache eviction changed numerical results")
        print("PASS: real Core ML whole-candidate scores, ordering, duplicate rows, bounded cache, cancellation and completed-score recovery; macOS CPU only")
    }
}
