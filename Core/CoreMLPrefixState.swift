import Foundation
#if canImport(CoreML)
import CoreML

/// Serial-worker-owned attention states. A node stores one causal position;
/// sibling candidates share its ancestors without recalculating the prefix.
final class CoreMLPrefixState {
    private struct Node {
        let parent: String?
        let position: Int
        let keys: [Float], values: [Float], probabilities: [Float]
        var touched: UInt64
    }
    private let model: MLModel
    private let vocabulary: [Character: Int]
    private var nodes: [String: Node] = [:]
    private var clock: UInt64 = 0
    private let tokens, positions, pastK, pastV, writeMask, attentionMask: MLMultiArray
    private let provider: MLDictionaryFeatureProvider
    private(set) var predictionCount = 0
    private(set) var lastPredictionMilliseconds = 0.0
    var cachedPositions: Int { nodes.count }

    init(model: MLModel, vocabulary: [String]) throws {
        self.model = model
        self.vocabulary = Dictionary(uniqueKeysWithValues: vocabulary.enumerated().compactMap {
            $0.offset > 2 && $0.element.count == 1 ? ($0.element.first!, $0.offset) : nil
        })
        tokens = try MLMultiArray(shape: [8, 1], dataType: .float32)
        positions = try MLMultiArray(shape: [8, 1], dataType: .float32)
        pastK = try MLMultiArray(shape: [8, 8, 16, 448], dataType: .float32)
        pastV = try MLMultiArray(shape: [8, 8, 16, 448], dataType: .float32)
        writeMask = try MLMultiArray(shape: [8, 16], dataType: .float32)
        attentionMask = try MLMultiArray(shape: [8, 16], dataType: .float32)
        provider = try MLDictionaryFeatureProvider(dictionary: [
            "tokens": MLFeatureValue(multiArray: tokens), "positions": MLFeatureValue(multiArray: positions),
            "past_k": MLFeatureValue(multiArray: pastK), "past_v": MLFeatureValue(multiArray: pastV),
            "write_mask": MLFeatureValue(multiArray: writeMask), "attention_mask": MLFeatureValue(multiArray: attentionMask)])
    }

    func next(_ prefixes: [String], abandoned: () -> Bool) throws -> [Float]? {
        guard !prefixes.isEmpty, prefixes.count <= 8, prefixes.allSatisfy({ $0.count < 16 }), !abandoned() else { return nil }
        var needed = Set<String>(), keep = Set<String>()
        for prefix in prefixes {
            guard prefix.allSatisfy({ vocabulary[$0] != nil }) else { return nil }
            var current = prefix
            while true {
                keep.insert(current)
                if nodes[current] == nil { needed.insert(current) }
                if current.isEmpty { break }
                current.removeLast()
            }
        }
        // Build missing ancestors before their children, including a single
        // shared BOS. A request of eight 15-character paths needs <= 121 nodes.
        for depth in 0..<16 {
            let level = needed.filter { $0.count == depth }.sorted()
            for start in stride(from: 0, to: level.count, by: 8) {
                guard !abandoned() else { return nil }
                let batch = Array(level[start..<min(start + 8, level.count)])
                guard makeRoom(for: batch.count, keeping: keep), try predict(batch, abandoned: abandoned) else { return nil }
            }
        }
        guard !abandoned() else { return nil }
        var output: [Float] = []; output.reserveCapacity(prefixes.count * 12_288)
        for prefix in prefixes {
            guard var node = nodes[prefix] else { return nil }
            clock &+= 1; node.touched = clock; nodes[prefix] = node
            output.append(contentsOf: node.probabilities)
        }
        return output
    }

    private func makeRoom(for count: Int, keeping: Set<String>) -> Bool {
        while nodes.count + count > 128 {
            let parents = Set(nodes.values.compactMap(\.parent))
            let leaves = nodes.filter { !keeping.contains($0.key) && !parents.contains($0.key) }
            guard let oldest = leaves.min(by: { $0.value.touched == $1.value.touched
                ? $0.key < $1.key : $0.value.touched < $1.value.touched }) else { return false }
            nodes.removeValue(forKey: oldest.key)
        }
        return true
    }

    private func predict(_ batch: [String], abandoned: () -> Bool) throws -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        let k = pastK.dataPointer.assumingMemoryBound(to: Float.self)
        let v = pastV.dataPointer.assumingMemoryBound(to: Float.self)
        let t = tokens.dataPointer.assumingMemoryBound(to: Float.self)
        let p = positions.dataPointer.assumingMemoryBound(to: Float.self)
        let write = writeMask.dataPointer.assumingMemoryBound(to: Float.self)
        let mask = attentionMask.dataPointer.assumingMemoryBound(to: Float.self)
        k.update(repeating: 0, count: pastK.count); v.update(repeating: 0, count: pastV.count)
        write.update(repeating: 0, count: writeMask.count)
        mask.update(repeating: -10_000, count: attentionMask.count)
        for row in 0..<8 {
            let key = batch[min(row, batch.count - 1)], position = key.count
            p[row] = Float(position); t[row] = key.last.flatMap { vocabulary[$0] }.map(Float.init) ?? 2
            write[row * 16 + position] = 1
            mask.advanced(by: row * 16).update(repeating: 0, count: position + 1)
            var ancestor: String? = key.isEmpty ? nil : String(key.dropLast())
            while let prefix = ancestor {
                guard let node = nodes[prefix], node.position < position else { return false }
                for layer in 0..<8 {
                    let offset = ((layer * 8 + row) * 16 + node.position) * 448
                    node.keys.withUnsafeBufferPointer { k.advanced(by: offset).update(from: $0.baseAddress!.advanced(by: layer * 448), count: 448) }
                    node.values.withUnsafeBufferPointer { v.advanced(by: offset).update(from: $0.baseAddress!.advanced(by: layer * 448), count: 448) }
                }
                ancestor = node.parent
            }
        }
        guard !abandoned() else { return false }
        let prediction = try model.prediction(from: provider)
        predictionCount += 1
        func output(_ name: String, shape: [Int], strides: [Int]) -> MLMultiArray? {
            guard let array = prediction.featureValue(for: name)?.multiArrayValue,
                  array.dataType == .float32, array.shape.map(\.intValue) == shape,
                  array.strides.map(\.intValue) == strides else { return nil }
            return array
        }
        guard let scores = output("log_probs", shape: [8, 12_288], strides: [12_288, 1]),
              let newK = output("new_k", shape: [8, 8, 448], strides: [3_584, 448, 1]),
              let newV = output("new_v", shape: [8, 8, 448], strides: [3_584, 448, 1]) else { return false }
        let scoreBuffer = scores.dataPointer.assumingMemoryBound(to: Float.self)
        let keyBuffer = newK.dataPointer.assumingMemoryBound(to: Float.self)
        let valueBuffer = newV.dataPointer.assumingMemoryBound(to: Float.self)
        var completed: [(String, Node)] = []
        for (row, key) in batch.enumerated() {
            let probabilities = Array(UnsafeBufferPointer(start: scoreBuffer.advanced(by: row * 12_288), count: 12_288))
            let keys = Array(UnsafeBufferPointer(start: keyBuffer.advanced(by: row * 3_584), count: 3_584))
            let values = Array(UnsafeBufferPointer(start: valueBuffer.advanced(by: row * 3_584), count: 3_584))
            guard probabilities.allSatisfy(\.isFinite), keys.allSatisfy(\.isFinite), values.allSatisfy(\.isFinite) else { return false }
            clock &+= 1
            completed.append((key, Node(parent: key.isEmpty ? nil : String(key.dropLast()), position: key.count,
                keys: keys, values: values, probabilities: probabilities, touched: clock)))
        }
        // Only complete numerical states enter the cache. A cancelled caller
        // never receives a partial result; finished shared ancestors may be reused.
        for (key, node) in completed { nodes[key] = node }
        lastPredictionMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        return !abandoned()
    }
}
#endif
