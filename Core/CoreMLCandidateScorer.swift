import Foundation
#if canImport(CoreML)
import CoreML

/// Worker-owned teacher-forced comparison. One prediction evaluates the entire
/// first-screen pool; completed scalar scores survive a caller's cancellation.
final class CoreMLCandidateScorer {
    enum Failure: Error { case invalidOutput }
    private struct Cached { let score: Float; var touched: UInt64 }
    private let model: MLModel
    private let vocabulary: [Character: Int32]
    private let tokens, targets, valid: MLMultiArray
    private let provider: MLDictionaryFeatureProvider
    private var cache: [String: Cached] = [:]
    private var clock: UInt64 = 0
    private(set) var predictionCount = 0
    private(set) var lastPredictionMilliseconds = 0.0
    var cachedSentences: Int { cache.count }

    init(model: MLModel, vocabulary: [String]) throws {
        self.model = model
        self.vocabulary = Dictionary(uniqueKeysWithValues: vocabulary.enumerated().compactMap {
            $0.offset > 2 && $0.element.count == 1 ? ($0.element.first!, Int32($0.offset)) : nil
        })
        tokens = try MLMultiArray(shape: [4, 16], dataType: .int32)
        targets = try MLMultiArray(shape: [4, 16], dataType: .int32)
        valid = try MLMultiArray(shape: [4, 16], dataType: .float32)
        provider = try MLDictionaryFeatureProvider(dictionary: [
            "tokens": MLFeatureValue(multiArray: tokens), "targets": MLFeatureValue(multiArray: targets),
            "valid_mask": MLFeatureValue(multiArray: valid)])
    }

    func clearScores() { cache.removeAll(keepingCapacity: true) }
    func score(_ sentences: [String], abandoned: () -> Bool) throws -> [Float]? {
        guard !sentences.isEmpty, sentences.count <= 4, !abandoned(),
              sentences.allSatisfy({ !$0.isEmpty && $0.count <= 16 && $0.allSatisfy({ vocabulary[$0] != nil }) }) else { return nil }
        var missing: [String] = []
        for text in sentences where cache[text] == nil && !missing.contains(text) { missing.append(text) }
        if !missing.isEmpty {
            let t = tokens.dataPointer.assumingMemoryBound(to: Int32.self)
            let y = targets.dataPointer.assumingMemoryBound(to: Int32.self)
            let mask = valid.dataPointer.assumingMemoryBound(to: Float.self)
            t.update(repeating: 0, count: 64); y.update(repeating: 0, count: 64); mask.update(repeating: 0, count: 64)
            for (row, text) in missing.enumerated() {
                var previous: Int32 = 2
                for (column, char) in text.enumerated() {
                    let offset = row * 16 + column, token = vocabulary[char]!
                    t[offset] = previous; y[offset] = token; mask[offset] = 1; previous = token
                }
            }
            guard !abandoned() else { return nil }
            let start = ProcessInfo.processInfo.systemUptime
            let result = try model.prediction(from: provider)
            lastPredictionMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            predictionCount += 1
            guard let values = result.featureValue(for: "mean_scores")?.multiArrayValue,
                  values.dataType == .float32, values.shape.map(\.intValue) == [4] else { throw Failure.invalidOutput }
            let scores = missing.indices.map { values[$0].floatValue }
            guard scores.allSatisfy({ $0.isFinite && $0 <= 0 }) else { throw Failure.invalidOutput }
            for (row, text) in missing.enumerated() {
                if cache.count >= 128, let oldest = cache.min(by: { $0.value.touched < $1.value.touched }) { cache.removeValue(forKey: oldest.key) }
                clock &+= 1; cache[text] = Cached(score: scores[row], touched: clock)
            }
        }
        guard !abandoned() else { return nil }
        return sentences.map { text in
            clock &+= 1; var value = cache[text]!; value.touched = clock; cache[text] = value; return value.score
        }
    }
}
#endif
