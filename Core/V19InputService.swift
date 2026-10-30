import Foundation
#if canImport(V19NativeIME)
import V19NativeIME
#endif

/// One formal SDK/model owner per process. UIKit never enters preparation or inference.
actor V19InputService {
    static let shared = V19InputService()
    private var initialization: Task<V19IMEKernel, Error>?
    private var version: UInt64 = 0
    func prepare() async throws -> V19IMEKernel {
        if let initialization { return try await initialization.value }
        let task = Task.detached(priority: .userInitiated) {
            guard let model = InputResources.url("V19FullPinyinFP16", extension: "mlmodelc"),
                  let config = InputResources.url("runtime_config", extension: "json", directory: "V19") else {
                throw V19Error.resource("V19 model/resources are unavailable")
            }
            return try await V19IMEKernel.prepare(compiledModelURL: model,
                resourceDirectory: config.deletingLastPathComponent(), configuration: V19Configuration())
        }
        initialization = task
        do { return try await task.value }
        catch { initialization = nil; throw error }
    }
    private func cancel(_ requested: UInt64) async {
        guard requested == version, let initialization else { return }
        if let kernel = try? await initialization.value, requested == version { await kernel.cancelPending() }
    }
    private func convert(_ result: V19Result, kernel: V19IMEKernel,
                         requested: UInt64, characters: Bool) async throws -> V19CandidateBatch {
        var output: [Candidate] = [], seen = Set<String>()
        for item in result.candidates {
            let selection = try await kernel.select(candidateID: item.id, from: result,
                prefixCharacterCount: characters ? 1 : nil)
            guard requested == version, !Task.isCancelled else { throw CancellationError() }
            if !characters || seen.insert(selection.selectedText).inserted {
                output.append(Candidate(text: selection.selectedText, reading: selection.selectedReading,
                    consumed: selection.consumedRawUTF16Range.length, score: item.score,
                    nativeChoice: V19Choice(raw: result.rawInput, selection: selection,
                        recommended: item.id == result.recommendedID)))
            }
        }
        return V19CandidateBatch(items: output, completedPaths: result.completedPaths, isFinal: result.isFinal)
    }
    private func progress(_ result: V19Result, kernel: V19IMEKernel, requested: UInt64,
                          characters: Bool, updated: @Sendable (V19CandidateBatch) -> Void) async {
        guard requested == version else { return }
        guard let batch = try? await convert(result, kernel: kernel, requested: requested, characters: characters),
              requested == version else { return }
        updated(batch)
    }
    func candidates(raw: String, context: String, characters: Bool,
                    updated: @escaping @Sendable (V19CandidateBatch) -> Void) async throws -> V19CandidateBatch {
        version &+= 1
        let requested = version
        let kernel = try await prepare()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            guard let result = try await kernel.candidates(rawPinyin: raw,
                    committedLeftContext: context, inputVersion: requested, requestedCount: 8,
                    onUpdate: { result in
                        _ = Task<Void, Never> { await self.progress(result, kernel: kernel, requested: requested,
                            characters: characters, updated: updated) }
                    }), requested == version, !Task.isCancelled else { throw CancellationError() }
            return try await convert(result, kernel: kernel, requested: requested, characters: characters)
        }, onCancel: { Task { await self.cancel(requested) } })
    }
}

struct V19CandidateBatch: Sendable {
    let items: [Candidate]
    let completedPaths: Int
    let isFinal: Bool
}
