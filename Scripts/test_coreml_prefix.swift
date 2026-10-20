import Foundation
import CoreML

@main struct PrefixChecks {
    static func main() throws {
        func expect(_ value: Bool, _ message: String) {
            if !value { fatalError(message) }
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let config = MLModelConfiguration(); config.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: directory.appendingPathComponent("ClearSentence25M.mlmodelc"), configuration: config)
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as! [String: String]
        let vocab = try JSONSerialization.jsonObject(with: metadata["vocab"]!.data(using: .utf8)!) as! [String]
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("CoreML25M-validation.json"))) as! [String: Any]
        let sequences = fixture["sequences"] as! [String], expected = fixture["expected"] as! [[String: Any]]
        let state = try CoreMLPrefixState(model: model, vocabulary: vocab)
        var saved: [Int: [Float]] = [:], maxError = 0.0, samples = 0
        for step in 0..<16 {
            let output = try state.next(sequences.map { String($0.prefix(step)) }, abandoned: { false })!
            saved[step] = output
            for item in expected where item["step"] as! Int == step {
                let row = item["row"] as! Int, token = item["token"] as! Int, value = item["value"] as! Double
                let error = abs(Double(output[row * 12_288 + token]) - value)
                maxError = max(maxError, error); samples += 1
                expect(error < 0.025, "Incremental state diverged from the original weights")
            }
            expect(state.cachedPositions <= 128, "State cache exceeded its bound")
        }
        let depths = [15, 0, 4, 1, 9, 15, 1, 4]
        let reordered = (0..<8).map { String(sequences[7 - $0].prefix(depths[$0])) }
        let count = state.predictionCount
        let mixed = try state.next(reordered, abandoned: { false })!
        expect(state.predictionCount == count, "Cached mixed-length prefixes were recomputed")
        for row in 0..<8 {
            let reference = saved[depths[row]]!
            for token in 0..<12_288 {
                expect(mixed[row * 12_288 + token] == reference[(7 - row) * 12_288 + token], "A sibling used another prefix's state")
            }
        }
        expect(try state.next(["🦄"], abandoned: { false }) == nil, "An unknown character was accepted")
        expect(try state.next([String(repeating: "我", count: 16)], abandoned: { false }) == nil, "An overlong prefix was truncated")
        expect(try state.next([""], abandoned: { true }) == nil, "Cancelled prediction returned a result")
        expect(state.predictionCount == count, "A rejected request ran the model")
        let original = saved[15]!
        for index in 0..<150 {
            let prefix = (0..<8).map { (index & (1 << $0)) == 0 ? "你" : "我" }.joined()
            expect(try state.next([prefix], abandoned: { false }) != nil, "Leaf eviction failed")
            expect(state.cachedPositions <= 128, "Eviction retained too many states")
        }
        let restored = try state.next(sequences, abandoned: { false })!
        expect(restored.count == original.count, "Restored batch has wrong shape")
        for index in original.indices { expect(abs(restored[index] - original[index]) < 0.0001, "Eviction corrupted a shared ancestor") }
        // An interrupted multi-step request keeps completed ancestors. The
        // next request resumes the same real model, without replaying them.
        let interrupted = try CoreMLPrefixState(model: model, vocabulary: vocab)
        expect(try interrupted.next(sequences, abandoned: { interrupted.predictionCount >= 2 }) == nil,
            "An interrupted request returned a partial result")
        expect(interrupted.predictionCount == 2, "Cancellation did not stop between model steps")
        let resumed = try interrupted.next(sequences, abandoned: { false })!
        expect(interrupted.predictionCount == 16, "Resumption recomputed completed causal ancestors")
        for index in original.indices { expect(abs(resumed[index] - original[index]) < 0.0001, "Resumption used an incomplete state") }
        let report: [String: Any] = ["status": "passed", "sampledValues": samples,
            "maximumSampleError": maxError, "cacheLimit": 128, "cachedPositions": state.cachedPositions,
            "modelCalls": state.predictionCount, "mixedDepthReuse": true, "evictionPreservesResults": true,
            "cancelledAndInvalidRequestsDoNotPredict": true,
            "interruptedPredictionResumesWithoutReplay": true,
            "scope": "macOS Swift release and Core ML CPU_ONLY; not iPhone, ANE or UI latency"]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
