// MLKV I/O and RoPE adapted from john-rocky/CoreML-LLM, MIT.
// See THIRD_PARTY_NOTICES.txt. Independent prototype; no keyboard project edits.
import Accelerate
import CoreML
import Foundation

public enum ANEError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

/// Serialized token-to-logits backend. The host supplies the matching Qwen
/// tokenizer and its existing constrained candidate decoder. No chat sampling,
/// repetition penalty, private ANE API, polling loop, or automatic GPU fallback.
/// Synchronous prediction keeps each state mutation atomic on this actor.
@available(iOS 18.0, macOS 15.0, *)
public actor QwenANE {
    public enum EmbeddingEncoding: String, Sendable {
        case fp16
        case int8Rowwise = "int8_rowwise_fp16_scale"
    }
    public static let contextLength = 2048
    public static let vocabularySize = 248_320
    public static let hiddenSize = 1024
    private let models: [MLModel]
    private var kvStates: [MLState]
    private var recurrent: [[String: MLMultiArray]]
    private let embedding: Data
    private let embeddingEncoding: EmbeddingEncoding
    private let hidden: MLMultiArray
    private let cosine: MLMultiArray
    private let sine: MLMultiArray
    private let mask: MLMultiArray
    private let position: MLMultiArray
    private var tokens: [Int32] = []
    private var lastLogits: [Float]?

    public init(compiledDirectory: URL, embeddingURL: URL,
                embeddingEncoding: EmbeddingEncoding = .fp16) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        var loaded: [MLModel] = []
        for suffix in ["a", "b", "c", "d"] {
            let url = compiledDirectory.appendingPathComponent("chunk_\(suffix).mlmodelc")
            loaded.append(try MLModel(contentsOf: url, configuration: configuration))
        }
        try Self.validate(loaded)
        let mapped = try Data(contentsOf: embeddingURL, options: .alwaysMapped)
        let expected = embeddingEncoding == .fp16
            ? Self.vocabularySize * Self.hiddenSize * 2
            : Self.vocabularySize * Self.hiddenSize + Self.vocabularySize * 2
        guard mapped.count == expected else {
            throw ANEError.invalid("Embedding size \(mapped.count), expected \(expected)")
        }
        models = loaded
        kvStates = loaded.map { $0.makeState() }
        recurrent = try Self.zeroRecurrent(loaded)
        embedding = mapped
        self.embeddingEncoding = embeddingEncoding
        hidden = try MLMultiArray(shape: [1, 1, 1024], dataType: .float16)
        cosine = try MLMultiArray(shape: [1, 1, 64], dataType: .float16)
        sine = try MLMultiArray(shape: [1, 1, 64], dataType: .float16)
        mask = try MLMultiArray(shape: [1, 1, 1, 2048], dataType: .float16)
        position = try MLMultiArray(shape: [1], dataType: .int32)
    }

    public func reset() throws {
        let fresh = try Self.zeroRecurrent(models)
        kvStates = models.map { $0.makeState() }
        recurrent = fresh
        tokens.removeAll(keepingCapacity: true)
        lastLogits = nil
    }

    /// Exact extension reuses the entire cached prefix. Any rewrite, deletion,
    /// or changed context resets and replays; MLState cannot rewind an SSM.
    /// Cancel the caller's Task when the keyboard disappears or input changes.
    public func logits(for prompt: [Int32]) throws -> [Float] {
        guard !prompt.isEmpty, prompt.count <= Self.contextLength,
              prompt.allSatisfy({ $0 >= 0 && Int($0) < Self.vocabularySize }) else {
            throw ANEError.invalid("Prompt must contain 1...2048 valid Qwen token IDs")
        }
        let isExtension = prompt.count >= tokens.count &&
            Array(prompt.prefix(tokens.count)) == tokens
        if !isExtension { try reset() }
        do {
            for token in prompt.dropFirst(tokens.count) {
                try Task.checkCancellation()
                lastLogits = try step(token: token, at: tokens.count)
                tokens.append(token)
            }
            guard let result = lastLogits else {
                throw ANEError.invalid("No logits produced")
            }
            return result
        } catch {
            // A cancelled/failed call can have partially mutated a chunk's
            // opaque KV state. Recreate every chunk before the next request.
            try? reset()
            throw error
        }
    }

    private func step(token: Int32, at offset: Int) throws -> [Float] {
        embedding.withUnsafeBytes { source in
            switch embeddingEncoding {
            case .fp16:
                hidden.dataPointer.copyMemory(
                    from: source.baseAddress!.advanced(by: Int(token) * Self.hiddenSize * 2),
                    byteCount: Self.hiddenSize * 2)
            case .int8Rowwise:
                let row = Int(token) * Self.hiddenSize
                let values = source.baseAddress!.assumingMemoryBound(to: Int8.self)
                let scaleOffset = Self.vocabularySize * Self.hiddenSize + Int(token) * 2
                let bits = source.loadUnaligned(fromByteOffset: scaleOffset, as: UInt16.self).littleEndian
                let scale = Float(Float16(bitPattern: bits))
                let destination = hidden.dataPointer.assumingMemoryBound(to: Float16.self)
                for index in 0..<Self.hiddenSize {
                    destination[index] = Float16(Float(values[row + index]) * scale)
                }
            }
        }
        for index in 0..<32 {
            let angle = Float(offset) * powf(10_000_000, -Float(2 * index) / 64)
            for destination in [index, index + 32] {
                cosine.dataPointer.assumingMemoryBound(to: Float16.self)[destination] = Float16(cosf(angle))
                sine.dataPointer.assumingMemoryBound(to: Float16.self)[destination] = Float16(sinf(angle))
            }
        }
        let maskPointer = mask.dataPointer.assumingMemoryBound(to: Float16.self)
        for index in 0..<Self.contextLength {
            maskPointer[index] = index <= offset ? 0 : -10_000
        }
        position.dataPointer.assumingMemoryBound(to: Int32.self)[0] = Int32(offset)
        var currentHidden = MLFeatureValue(multiArray: hidden)
        var finalOutput: MLFeatureProvider?
        for chunk in models.indices {
            try Task.checkCancellation()
            var inputs: [String: MLFeatureValue] = [
                "hidden_in": currentHidden,
                "cos": MLFeatureValue(multiArray: cosine),
                "sin": MLFeatureValue(multiArray: sine),
                "causal_mask": MLFeatureValue(multiArray: mask),
                "current_pos": MLFeatureValue(multiArray: position)
            ]
            for (name, array) in recurrent[chunk] {
                inputs[name] = MLFeatureValue(multiArray: array)
            }
            let output = try models[chunk].prediction(
                from: MLDictionaryFeatureProvider(dictionary: inputs),
                using: kvStates[chunk], options: MLPredictionOptions())
            for name in Array(recurrent[chunk].keys) {
                guard let value = output.featureValue(for: "new_" + name)?.multiArrayValue else {
                    throw ANEError.invalid("Missing state output new_\(name)")
                }
                recurrent[chunk][name] = value
            }
            if chunk < models.count - 1 {
                guard let next = output.featureValue(for: "hidden") else {
                    throw ANEError.invalid("Missing hidden output from chunk \(chunk)")
                }
                currentHidden = next
            }
            finalOutput = output
        }
        try Task.checkCancellation()
        guard let scores = finalOutput?.featureValue(for: "logits")?.multiArrayValue,
              scores.count == Self.vocabularySize else {
            throw ANEError.invalid("Expected full-vocabulary logits; reject legacy top-K export")
        }
        // Use Accelerate for the 248K-element transfer. Respect strides before
        // using the contiguous path; never assume an arbitrary array is dense.
        var contiguousStride = 1
        var contiguous = true
        for dimension in scores.shape.indices.reversed() {
            let length = scores.shape[dimension].intValue
            if length > 1 && scores.strides[dimension].intValue != contiguousStride {
                contiguous = false
            }
            contiguousStride *= length
        }
        var values = [Float](repeating: 0, count: Self.vocabularySize)
        if contiguous && scores.dataType == .float16 {
            var source = vImage_Buffer(data: scores.dataPointer, height: 1,
                width: vImagePixelCount(values.count), rowBytes: values.count * 2)
            let code = values.withUnsafeMutableBufferPointer { buffer in
                var destination = vImage_Buffer(data: buffer.baseAddress, height: 1,
                    width: vImagePixelCount(buffer.count), rowBytes: buffer.count * 4)
                return vImageConvert_Planar16FtoPlanarF(&source, &destination, 0)
            }
            guard code == kvImageNoError else { throw ANEError.invalid("Logits conversion failed") }
        } else {
            for index in values.indices { values[index] = scores[index].floatValue }
        }
        guard values.allSatisfy(\.isFinite) else { throw ANEError.invalid("Non-finite model output") }
        return values
    }

    private static func zeroRecurrent(_ models: [MLModel]) throws -> [[String: MLMultiArray]] {
        try models.map { model in
            var state: [String: MLMultiArray] = [:]
            for (name, description) in model.modelDescription.inputDescriptionsByName
                where name.hasPrefix("conv_state_") || name.hasPrefix("rec_state_") {
                guard let constraint = description.multiArrayConstraint,
                      constraint.dataType == .float16 else {
                    throw ANEError.invalid("Unsupported state type for \(name)")
                }
                let array = try MLMultiArray(shape: constraint.shape, dataType: .float16)
                array.dataPointer.initializeMemory(as: UInt8.self, repeating: 0, count: array.count * 2)
                state[name] = array
            }
            return state
        }
    }

    private static func validate(_ models: [MLModel]) throws {
        for (index, model) in models.enumerated() {
            let description = model.modelDescription
            let expected: [String: [Int]] = [
                "hidden_in": [1, 1, 1024], "cos": [1, 1, 64], "sin": [1, 1, 64],
                "causal_mask": [1, 1, 1, 2048], "current_pos": [1]
            ]
            for (name, shape) in expected {
                let constraint = description.inputDescriptionsByName[name]?.multiArrayConstraint
                guard constraint?.shape.map(\.intValue) == shape,
                      constraint?.dataType == (name == "current_pos" ? .int32 : .float16) else {
                    throw ANEError.invalid("Chunk \(index) input mismatch: \(name)")
                }
            }
            let states = description.stateDescriptionsByName
            guard Set(states.keys) == ["kv_cache"] else {
                throw ANEError.invalid("Chunk \(index) requires one kv_cache MLState")
            }
        }
        guard models.last?.modelDescription.outputDescriptionsByName["logits"] != nil else {
            throw ANEError.invalid("Last chunk must emit full logits")
        }
    }
}
