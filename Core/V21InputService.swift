import Foundation
#if canImport(V21NativeIME)
import V21NativeIME
#endif

/// One formal SDK/model owner per process. UIKit never enters preparation or inference.
actor V21InputService {
    static let shared = V21InputService()
    private var initialization: Task<V21IMEKernel, Error>?
    private var version: UInt64 = 0
    func prepare() async throws -> V21IMEKernel {
        if let initialization { return try await initialization.value }
        let task = Task.detached(priority: .userInitiated) {
            guard let model = InputResources.url("V21PinyinCompactFP16", extension: "mlmodelc"),
                  let config = InputResources.url("runtime_config", extension: "json", directory: "V21") else {
                throw V21Error.resource("V21 model/resources are unavailable")
            }
            return try await V21IMEKernel.prepare(compiledModelURL: model,
                resourceDirectory: config.deletingLastPathComponent(), configuration: V21Configuration())
        }
        initialization = task
        do { return try await task.value }
        catch { initialization = nil; throw error }
    }
    private func convert(_ result: V21Result, requested: UInt64,
                         characters: Bool) throws -> V21CandidateBatch {
        guard requested == version, !Task.isCancelled else { throw CancellationError() }
        let receipts = try result.selections(prefixCharacterCount: characters ? 1 : nil)
        var output: [Candidate] = [], seen = Set<String>()
        for (item, selection) in zip(result.candidates, receipts) {
            if !characters || seen.insert(selection.selectedText).inserted {
                output.append(Candidate(text: selection.selectedText, reading: selection.selectedReading,
                    consumed: selection.consumedRawUTF16Range.length, score: item.score,
                    nativeChoice: V21Choice(raw: result.rawInput, selection: selection,
                        recommended: item.id == result.recommendedID, completionSuffix: item.completionSuffix)))
            }
        }
        return V21CandidateBatch(items: output, completedPaths: result.completedPaths, isFinal: result.isFinal)
    }
    private func progress(_ result: V21Result, requested: UInt64,
                          characters: Bool, updated: @Sendable (V21CandidateBatch) -> Void) async {
        guard requested == version else { return }
        guard let batch = try? convert(result, requested: requested, characters: characters),
              requested == version else { return }
        updated(batch)
    }
    func candidates(raw: String, context: String, characters: Bool,
                    updated: @escaping @Sendable (V21CandidateBatch) -> Void) async throws -> V21CandidateBatch {
        version &+= 1
        let requested = version
        let kernel = try await prepare()
        guard requested == version, !Task.isCancelled else { throw CancellationError() }
        // The SDK binds cancellation to this task's own signal. A global cancel here
        // could arrive after another request and invalidate its newer receipt.
        guard let result = try await kernel.candidates(rawPinyin: raw,
                committedLeftContext: context, inputVersion: requested, requestedCount: 8,
                onUpdate: { result in
                    _ = Task<Void, Never> { await self.progress(result, requested: requested,
                        characters: characters, updated: updated) }
                }), requested == version, !Task.isCancelled else { throw CancellationError() }
        return try convert(result, requested: requested, characters: characters)
    }
}

struct V21CandidateBatch: Sendable {
    let items: [Candidate]
    let completedPaths: Int
    let isFinal: Bool
}
