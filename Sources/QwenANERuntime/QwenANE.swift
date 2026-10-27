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
    public struct HeadOutput: Codable, Sendable {
        public let name: String
        public let offset: Int
        public let length: Int
        public init(name: String, offset: Int, length: Int) {
            self.name = name; self.offset = offset; self.length = length
        }
    }
    public struct HeadModel: Codable, Sendable {
        public let name: String
        public let outputs: [HeadOutput]
        public init(name: String, outputs: [HeadOutput]) {
            self.name = name; self.outputs = outputs
        }
    }
    public static let contextLength = 2048
    public static let vocabularySize = 248_320
    public static let hiddenSize = 1024
    private let models: [MLModel]
    private let headModels: [(model: MLModel, layout: HeadModel)]
    private let bodyOutput: String
    private let headInput: String
    private let progress: (@Sendable (String) -> Void)?
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
                embeddingEncoding: EmbeddingEncoding = .fp16,
                headModels: [HeadModel] = [], bodyOutput: String? = nil,
                headInput: String = "normed_hidden",
                computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
                progress: (@Sendable (String) -> Void)? = nil) throws {
        try Self.validateLayout(headModels)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        func load(_ name: String) throws -> MLModel {
            progress?("load:start:\(name)")
            let start = ProcessInfo.processInfo.systemUptime
            let model = try MLModel(contentsOf: compiledDirectory.appendingPathComponent(name + ".mlmodelc"),
                                    configuration: configuration)
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            progress?("load:complete:\(name):\(ms)")
            return model
        }
        var loaded: [MLModel] = []
        for suffix in ["a", "b", "c", "d"] {
            loaded.append(try load("chunk_\(suffix)"))
        }
        let outputName = bodyOutput ?? (headModels.isEmpty ? "logits" : "normed_hidden")
        try Self.validate(loaded, outputName: outputName, splitHead: !headModels.isEmpty)
        var loadedHeads: [(model: MLModel, layout: HeadModel)] = []
        for layout in headModels {
            let model = try load(layout.name)
            try Self.validateHead(model, layout: layout, inputName: headInput)
            loadedHeads.append((model, layout))
        }
        let mapped = try Data(contentsOf: embeddingURL, options: .alwaysMapped)
        let expected = embeddingEncoding == .fp16
            ? Self.vocabularySize * Self.hiddenSize * 2
            : Self.vocabularySize * Self.hiddenSize + Self.vocabularySize * 2
        guard mapped.count == expected else {
            throw ANEError.invalid("Embedding size \(mapped.count), expected \(expected)")
        }
        models = loaded
        self.headModels = loadedHeads
        self.bodyOutput = outputName
        self.headInput = headInput
        self.progress = progress
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
            let pending = Array(prompt.dropFirst(tokens.count))
            for (index, token) in pending.enumerated() {
                try Task.checkCancellation()
                // Intermediate prefill tokens only update the recurrent/KV
                // states. The separate full-vocabulary head is needed once,
                // on the final token, preserving exactly the same final logits.
                if let scores = try step(token: token, at: tokens.count,
                                         produceLogits: index == pending.count - 1) {
                    lastLogits = scores
                }
                tokens.append(token)
            }
            guard let result = lastLogits else {
                throw ANEError.invalid("No logits produced")
            }
            try Task.checkCancellation()
            return result
        } catch {
            // A cancelled/failed call can have partially mutated a chunk's
            // opaque KV state. Recreate every chunk before the next request.
            try? reset()
            throw error
        }
    }

    private func step(token: Int32, at offset: Int, produceLogits: Bool) throws -> [Float]? {
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
            let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
            let output = try measuredPrediction(name: "chunk_\(["a", "b", "c", "d"][chunk])", offset: offset) {
                try models[chunk].prediction(from: provider,
                    using: kvStates[chunk], options: MLPredictionOptions())
            }
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
        guard produceLogits else { return nil }
        guard let output = finalOutput?.featureValue(for: bodyOutput)?.multiArrayValue else {
            throw ANEError.invalid("Missing body output \(bodyOutput)")
        }
        if headModels.isEmpty {
            return try Self.floatValues(output, count: Self.vocabularySize)
        }
        guard output.shape.map(\.intValue) == [1, 1, Self.hiddenSize] else {
            throw ANEError.invalid("Split head requires normalized hidden [1,1,1024]")
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            headInput: MLFeatureValue(multiArray: output)
        ])
        var logits = [Float](repeating: 0, count: Self.vocabularySize)
        for head in headModels {
            try Task.checkCancellation()
            let prediction = try measuredPrediction(name: head.layout.name, offset: offset) {
                try head.model.prediction(from: input)
            }
            for tile in head.layout.outputs {
                guard let scores = prediction.featureValue(for: tile.name)?.multiArrayValue else {
                    throw ANEError.invalid("Missing \(head.layout.name).\(tile.name)")
                }
                let values = try Self.floatValues(scores, count: tile.length)
                logits.replaceSubrange(tile.offset..<(tile.offset + tile.length), with: values)
            }
        }
        return logits
    }

    private func measuredPrediction(name: String, offset: Int,
                                    operation: () throws -> MLFeatureProvider) throws -> MLFeatureProvider {
        let start = ProcessInfo.processInfo.systemUptime
        progress?("inference:start:\(name):\(offset)")
        do {
            let output = try operation()
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            progress?("inference:complete:\(name):\(offset):\(ms)")
            return output
        } catch {
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            progress?("inference:failed:\(name):\(offset):\(ms)")
            throw error
        }
    }

    private static func floatValues(_ scores: MLMultiArray, count: Int) throws -> [Float] {
        guard scores.count == count else {
            throw ANEError.invalid("Output count \(scores.count), expected \(count)")
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
        var values = [Float](repeating: 0, count: count)
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

    private static func validate(_ models: [MLModel], outputName: String, splitHead: Bool) throws {
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
            let name = index < models.count - 1 ? "hidden" : outputName
            let shape = index < models.count - 1 || splitHead
                ? [1, 1, Self.hiddenSize] : [1, 1, Self.vocabularySize]
            let output = description.outputDescriptionsByName[name]?.multiArrayConstraint
            guard output?.shape.map(\.intValue) == shape, output?.dataType == .float16 else {
                throw ANEError.invalid("Chunk \(index) output mismatch: \(name)")
            }
        }
    }

    private static func validateLayout(_ layouts: [HeadModel]) throws {
        guard !layouts.isEmpty else { return }
        guard Set(layouts.map(\.name)).count == layouts.count else {
            throw ANEError.invalid("Duplicate output-head model name")
        }
        for layout in layouts {
            guard layout.name.hasPrefix("head_"),
                  layout.name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                  !layout.outputs.isEmpty,
                  Set(layout.outputs.map(\.name)).count == layout.outputs.count else {
                throw ANEError.invalid("Invalid output-head layout \(layout.name)")
            }
        }
        let tiles = layouts.flatMap(\.outputs).sorted { $0.offset < $1.offset }
        var next = 0
        for tile in tiles {
            guard tile.offset == next, tile.length > 0, tile.length <= 8192,
                  tile.offset <= Self.vocabularySize - tile.length else {
                throw ANEError.invalid("Output tiles must cover the full vocabulary without gaps or overlap")
            }
            next += tile.length
        }
        guard next == Self.vocabularySize else {
            throw ANEError.invalid("Output tiles omit vocabulary entries")
        }
    }

    private static func validateHead(_ model: MLModel, layout: HeadModel, inputName: String) throws {
        let description = model.modelDescription
        let input = description.inputDescriptionsByName[inputName]?.multiArrayConstraint
        guard Set(description.inputDescriptionsByName.keys) == [inputName],
              input?.shape.map(\.intValue) == [1, 1, Self.hiddenSize],
              input?.dataType == .float16, description.stateDescriptionsByName.isEmpty,
              Set(description.outputDescriptionsByName.keys) == Set(layout.outputs.map(\.name)) else {
            throw ANEError.invalid("\(layout.name) input/state/output contract mismatch")
        }
        for tile in layout.outputs {
            let output = description.outputDescriptionsByName[tile.name]?.multiArrayConstraint
            guard output?.shape.map(\.intValue) == [1, 1, tile.length], output?.dataType == .float16 else {
                throw ANEError.invalid("\(layout.name).\(tile.name) output contract mismatch")
            }
        }
    }
}
