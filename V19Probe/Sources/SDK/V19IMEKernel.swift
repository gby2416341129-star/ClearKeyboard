import Foundation
import CoreML
import CryptoKit
#if canImport(CV19IMECore)
import CV19IMECore
#endif

private struct V19Manifest: Decodable {
    let source_checkpoint_sha256: String
    let resource_binary_sha256: String
    let context_length: Int
    let target_length: Int
    let max_segmentations: Int
    let beam: Int
    let per_position_chars: Int
    let topk: Int
}
private final class V19Runner: @unchecked Sendable {
    static let sourceSHA = "d9d1c4974a513236d72f489d0b13f51cb6c7a94b4f2cd5d51400d314dfba80a7"
    let resources: OpaquePointer
    let model: MLModel
    private let modelLock = NSLock()
    let probeResourcePreparationMS: Double
    let probeCoreMLLoadMS: Double
    var probeLastPredictionMS: [Double] = []
    init(compiledModelURL: URL, resourceDirectory: URL?, configuration: V19Configuration) throws {
        let probeResourceStart = ProcessInfo.processInfo.systemUptime
        let directory: URL
        if let supplied = resourceDirectory { directory = supplied }
        else {
            #if SWIFT_PACKAGE
            guard let root = Bundle.module.resourceURL else { throw V19Error.resource("Swift Package resource bundle is missing") }
            directory = root.appendingPathComponent("Resources", isDirectory: true)
            #else
            throw V19Error.resource("Pass the keyboard-target resource directory when integrating sources manually")
            #endif
        }
        let manifest = try JSONDecoder().decode(V19Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("runtime_config.json")))
        let bytes = try Data(contentsOf: directory.appendingPathComponent("V19Resources.bin"), options: .mappedIfSafe)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard manifest.source_checkpoint_sha256 == Self.sourceSHA, digest == manifest.resource_binary_sha256,
              manifest.context_length == 32, manifest.target_length == 64, manifest.max_segmentations == 8,
              manifest.beam == 32, manifest.per_position_chars == 8, manifest.topk == 8 else {
            throw V19Error.resource("V19 runtime resources/hash/search contract mismatch")
        }
        var error = [CChar](repeating: 0, count: 1024)
        let handle = bytes.withUnsafeBytes { data in
            error.withUnsafeMutableBufferPointer { out in
                v19_resources_create(data.bindMemory(to: UInt8.self).baseAddress, data.count, out.baseAddress, out.count)
            }
        }
        guard let handle else { throw V19Error.resource(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }) }
        do {
            guard String(cString: v19_source_fingerprint(handle)) == Self.sourceSHA else { throw V19Error.resource("Binary tables belong to another checkpoint") }
            guard compiledModelURL.pathExtension == "mlmodelc" else { throw V19Error.resource("Add the supplied .mlpackage to the keyboard Xcode target; pass the built .mlmodelc URL") }
            let config = MLModelConfiguration(); config.computeUnits = configuration.computeUnits
            probeResourcePreparationMS = (ProcessInfo.processInfo.systemUptime - probeResourceStart) * 1000
            let probeLoadStart = ProcessInfo.processInfo.systemUptime
            let loaded = try MLModel(contentsOf: compiledModelURL, configuration: config)
            probeCoreMLLoadMS = (ProcessInfo.processInfo.systemUptime - probeLoadStart) * 1000
            let metadata = loaded.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
            guard metadata?["checkpoint_sha256"] == Self.sourceSHA, metadata?["source_step"] == "38750" else { throw V19Error.model("Core ML model is not the locked V19 best export") }
            for (name, shape) in [("context_ids", [1,32]), ("pinyin_ids", [1,64]), ("context_mask", [1,32]), ("pinyin_mask", [1,64])] {
                guard let input = loaded.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint,
                      input.shape.map({ $0.intValue }) == shape, input.dataType == .int32 else { throw V19Error.model("Unexpected input contract for \(name)") }
            }
            guard let output = loaded.modelDescription.outputDescriptionsByName["character_logits"]?.multiArrayConstraint,
                  output.shape.map({ $0.intValue }) == [1,64,8192], output.dataType == .float32 else { throw V19Error.model("Unexpected character_logits contract") }
            self.resources = handle; self.model = loaded
        } catch { v19_resources_destroy(handle); throw error }
    }
    deinit { v19_resources_destroy(resources) }
    private func array(_ values: [Int32], width: Int) throws -> MLMultiArray {
        let result = try MLMultiArray(shape: [1, NSNumber(value: width)], dataType: .int32)
        let pointer = result.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<width { pointer[i] = values[i] }
        return result
    }
    private func predict(_ features: MLFeatureProvider) throws -> MLMultiArray {
        modelLock.lock(); defer { modelLock.unlock() }
        // A request may have been cancelled while waiting for an older prediction.
        try Task.checkCancellation()
        let probePredictionStart = ProcessInfo.processInfo.systemUptime
        let output = try model.prediction(from: features)
        probeLastPredictionMS.append((ProcessInfo.processInfo.systemUptime - probePredictionStart) * 1000)
        guard let logits = output.featureValue(for: "character_logits")?.multiArrayValue,
              logits.dataType == .float32, logits.shape.map({ $0.intValue }) == [1,64,8192] else { throw V19Error.model("Invalid logits tensor returned by Core ML") }
        return logits
    }
    func run(raw: String, context: String, version: UInt64, limit: Int, generation: UInt64) throws -> V19Result {
        try Task.checkCancellation()
        probeLastPredictionMS.removeAll(keepingCapacity: true)
        guard limit > 0 else { throw V19Error.contract("requestedCount must be positive; V19 supports at most8") }
        let input: V19Input
        do { input = try V19Input.normalize(raw) }
        catch { return V19Result(inputVersion: version, rawInput: raw, normalizedPinyin: "", normalizationMap: [], candidates: [], recommendedID: nil, status: .unsupportedInput, reason: error.localizedDescription, syllablePathsExamined: 0, requestedCount: limit, maximumSupportedCount: 8, generation: generation) }
        var error = [CChar](repeating: 0, count: 1024)
        let request = raw.withCString { original in input.normalized.withCString { normalized in
            input.starts.withUnsafeBufferPointer { starts in input.ends.withUnsafeBufferPointer { ends in
                error.withUnsafeMutableBufferPointer { out in v19_request_create(resources, original, raw.utf8.count, normalized, input.normalized.utf8.count, starts.baseAddress, ends.baseAddress, out.baseAddress, out.count) }
            } }
        } }
        guard let request else { throw V19Error.contract(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }) }
        defer { v19_request_destroy(request) }
        let pathCount = Int(v19_path_count(request))
        if pathCount == 0 { return V19Result(inputVersion: version, rawInput: raw, normalizedPinyin: input.normalized, normalizationMap: input.map, candidates: [], recommendedID: nil, status: raw.isEmpty ? .emptyInput : .noCompleteSyllablePath, reason: "No complete legal full-pinyin path under the frozen V19 parser", syllablePathsExamined: 0, requestedCount: limit, maximumSupportedCount: 8, generation: generation) }
        // Python takes the last32 Unicode code points, not32 grapheme clusters.
        let contextScalars = Array(context.unicodeScalars.suffix(32))
        var contextIDs = [Int32](repeating: 0, count: 32), contextMask = contextIDs
        for (i, scalar) in contextScalars.enumerated() { contextIDs[i] = Int32(v19_character_id(resources, scalar.value)); contextMask[i] = 1 }
        let cx = try array(contextIDs, width: 32), cm = try array(contextMask, width: 32)
        for path in 0..<pathCount {
            try Task.checkCancellation()
            let count = Int(v19_path_length(request, Int32(path)))
            var py = [Int32](repeating: 0, count: 64), mask = py
            for i in 0..<count { py[i] = v19_path_syllable(request, Int32(path), Int32(i)); mask[i] = 1 }
            let provider = try MLDictionaryFeatureProvider(dictionary: ["context_ids": MLFeatureValue(multiArray: cx), "pinyin_ids": MLFeatureValue(multiArray: try array(py, width: 64)), "context_mask": MLFeatureValue(multiArray: cm), "pinyin_mask": MLFeatureValue(multiArray: try array(mask, width: 64))])
            let logits = try predict(provider)
            try Task.checkCancellation()
            let status: Int32
            if logits.strides[1].intValue == 8192 && logits.strides[2].intValue == 1 {
                status = v19_decode_path(request, Int32(path), logits.dataPointer.assumingMemoryBound(to: Float.self), logits.count, 8192, 1)
            } else {
                // A safe layout adapter for a strided Core ML output; never changes values.
                var contiguous = [Float](repeating: 0, count: 64 * 8192)
                let source = logits.dataPointer.assumingMemoryBound(to: Float.self)
                for i in 0..<64 { for c in 0..<8192 { contiguous[i*8192+c] = source[i*logits.strides[1].intValue+c*logits.strides[2].intValue] } }
                status = contiguous.withUnsafeBufferPointer { v19_decode_path(request, Int32(path), $0.baseAddress, $0.count, 8192, 1) }
            }
            guard status == 0 else { throw V19Error.model(String(cString: v19_request_error(request))) }
        }
        let count = v19_finish(request, Int32(min(8, limit)))
        guard count >= 0 else { throw V19Error.model(String(cString: v19_request_error(request))) }
        let consumed = V19Range(start: 0, end: raw.utf8.count), consumed16 = V19Range(start: 0, end: raw.utf16.count)
        var candidates: [V19Candidate] = []
        for i in 0..<Int(count) {
            var alignment: [V19Alignment] = []
            for character in 0..<Int(v19_candidate_character_count(request, Int32(i))) {
                let range = V19Range(start: Int(v19_alignment_raw_start(request, Int32(i), Int32(character))), end: Int(v19_alignment_raw_end(request, Int32(i), Int32(character))))
                alignment.append(V19Alignment(characterUTF16Range: V19Range(start: character, end: character+1), rawUTF8Range: range, rawUTF16Range: try V19Input.utf16Range(range, in: raw), normalizedUTF8Range: V19Range(start: Int(v19_alignment_normalized_start(request, Int32(i), Int32(character))), end: Int(v19_alignment_normalized_end(request, Int32(i), Int32(character)))), syllable: String(cString: v19_alignment_syllable(request, Int32(i), Int32(character)))))
            }
            candidates.append(V19Candidate(id: String(cString: v19_candidate_id(request, Int32(i))), text: String(cString: v19_candidate_text(request, Int32(i))), reading: String(cString: v19_candidate_reading(request, Int32(i))), score: v19_candidate_score(request, Int32(i)), consumedRawUTF8Range: consumed, consumedRawUTF16Range: consumed16, fullConsumption: true, remainingPinyin: "", matchType: "exact_full_pinyin", alignment: alignment, inputVersion: version))
        }
        return V19Result(inputVersion: version, rawInput: raw, normalizedPinyin: input.normalized, normalizationMap: input.map, candidates: candidates, recommendedID: candidates.first?.id, status: candidates.isEmpty ? .noCandidateAfterConstraints : .ok, reason: candidates.isEmpty ? "No candidate survived the unchanged V19 reading constraints" : nil, syllablePathsExamined: pathCount, requestedCount: limit, maximumSupportedCount: 8, generation: generation)
    }
}

/// Keep one kernel for the lifetime of the keyboard-extension process.
public actor V19IMEKernel {
    private var runner: V19Runner?
    private var generation: UInt64 = 0
    private var latestInputVersion: UInt64 = 0
    private var pending: Task<V19Result, Error>?
    private init(runner: V19Runner) { self.runner = runner }
    public static func prepare(compiledModelURL: URL, resourceDirectory: URL? = nil, configuration: V19Configuration = V19Configuration()) async throws -> V19IMEKernel {
        let runner = try await Task.detached(priority: .userInitiated) { try V19Runner(compiledModelURL: compiledModelURL, resourceDirectory: resourceDirectory, configuration: configuration) }.value
        return V19IMEKernel(runner: runner)
    }
    /// nil means this request became obsolete/cancelled. Do not replace the current UI with nil.
    public func candidates(rawPinyin: String, committedLeftContext: String, inputVersion: UInt64, requestedCount: Int = 8) async throws -> V19Result? {
        guard let runner else { throw V19Error.released }
        guard inputVersion >= latestInputVersion else { return nil }
        latestInputVersion = inputVersion; generation &+= 1; let token = generation
        pending?.cancel()
        let work = Task.detached(priority: .userInitiated) { try runner.run(raw: rawPinyin, context: committedLeftContext, version: inputVersion, limit: requestedCount, generation: token) }
        pending = work
        do { let result = try await work.value; guard token == generation && inputVersion == latestInputVersion else { return nil }; return result }
        catch is CancellationError { return nil }
    }
    public func resetComposition(inputVersion: UInt64) {
        latestInputVersion = max(latestInputVersion, inputVersion); generation &+= 1; pending?.cancel(); pending = nil
    }
    public func cancelPending() { generation &+= 1; pending?.cancel(); pending = nil }
    public func releaseResources() { generation &+= 1; pending?.cancel(); pending = nil; runner = nil }
    // Standalone diagnostic app only: reads existing model and timing metadata.
    // Called sequentially after the measured request has finished.
    func probeLoadedModel() throws -> MLModel {
        guard let runner else { throw V19Error.released }; return runner.model
    }
    func probeLoadTimes() throws -> [Double] {
        guard let runner else { throw V19Error.released }
        return [runner.probeResourcePreparationMS, runner.probeCoreMLLoadMS]
    }
    func probeLastPredictionTimes() throws -> [Double] {
        guard let runner else { throw V19Error.released }; return runner.probeLastPredictionMS
    }
    /// Optional segmented selection is derived from an already-returned candidate.
    /// It does not add prefix candidates or change the default V19 search/ranking.
    public func select(candidateID: String, from result: V19Result, prefixCharacterCount: Int? = nil) throws -> V19Selection {
        guard runner != nil else { throw V19Error.released }
        guard result.generation == generation, result.inputVersion == latestInputVersion else { throw V19Error.invalidSelection("Candidate result belongs to an obsolete input") }
        guard let candidate = result.candidates.first(where: { $0.id == candidateID }) else { throw V19Error.invalidSelection("Unknown candidate ID") }
        let n = prefixCharacterCount ?? candidate.alignment.count
        guard n > 0 && n <= candidate.alignment.count else { throw V19Error.invalidSelection("Invalid selected prefix length") }
        let full = n == candidate.alignment.count
        let alignment = Array(candidate.alignment.prefix(n)), text = String(candidate.text.prefix(n)), reading = alignment.map(\.syllable).joined(separator: " ")
        let end = full ? result.rawInput.utf8.count : alignment[n-1].rawUTF8Range.end
        let range = V19Range(start: 0, end: end)
        return V19Selection(inputVersion: result.inputVersion, candidateID: full ? candidate.id : V19Input.candidateID(raw: result.rawInput, text: text, reading: reading, consumedEnd: end), selectedText: text, selectedReading: reading, consumedRawUTF8Range: range, consumedRawUTF16Range: try V19Input.utf16Range(range, in: result.rawInput), remainingPinyin: try V19Input.suffix(after: end, in: result.rawInput), fullConsumption: full, alignment: alignment)
    }
}
