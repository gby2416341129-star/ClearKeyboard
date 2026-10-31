import Foundation
import Dispatch
#if canImport(V21NativeIME)
import V21NativeIME
#endif

/// One formal SDK/model owner per process. UIKit never enters preparation or inference.
actor V21InputService {
    static let shared = V21InputService()
    private var initialization: Task<V21IMEKernel, Error>?
    private var version: UInt64 = 0
    private var measurement: V22MeasurementSession?
    private var measurementTask: Task<Void, Never>?
    private var measurementRunning = false
    private var measurementStopRequested = false
    private var clocks: [UInt64: (input: UInt64, waitStart: UInt64, waitEnd: UInt64)] = [:]
    func prepare() async throws -> V21IMEKernel {
        if let initialization { return try await initialization.value }
        let task = Task.detached(priority: .userInitiated) {
            guard let model = InputResources.url("V22PinyinB1FP16", extension: "mlmodelc"),
                  let config = InputResources.url("runtime_config", extension: "json", directory: "V22") else {
                throw V21Error.resource("V22 model/resources are unavailable")
            }
            return try await V21IMEKernel.prepare(compiledModelURL: model,
                resourceDirectory: config.deletingLastPathComponent(), configuration: V21Configuration(performanceSink: { KernelMeasurement.shared.receive($0) }))
        }
        initialization = task
        do { return try await task.value }
        catch { initialization = nil; KernelMeasurement.shared.preparationFailed(error); throw error }
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
        let timing = clocks[requested].map { clock in
            V22AppTiming(inputVersion: requested, inputNS: clock.input, prepareWaitStartNS: clock.waitStart,
                prepareWaitEndNS: clock.waitEnd, phase: result.isFinal ? "final_applied" : "preview_applied")
        }
        return V21CandidateBatch(items: output, completedPaths: result.completedPaths, isFinal: result.isFinal, timing: timing)
    }
    private func progress(_ result: V21Result, requested: UInt64,
                          characters: Bool, updated: @Sendable (V21CandidateBatch) -> Void) async {
        guard requested == version else { return }
        guard let batch = try? convert(result, requested: requested, characters: characters),
              requested == version else { return }
        updated(batch)
    }
    func candidates(raw: String, context: String, characters: Bool, inputNS: UInt64,
                    updated: @escaping @Sendable (V21CandidateBatch) -> Void) async throws -> V21CandidateBatch {
        guard !measurementRunning else { throw V21Error.contract("Stop manual SDK measurement before live App preview input") }
        version &+= 1
        let requested = version
        let waitStart = DispatchTime.now().uptimeNanoseconds
        let kernel = try await prepare()
        clocks[requested] = (inputNS, waitStart, DispatchTime.now().uptimeNanoseconds)
        if clocks.count > 64 { for key in clocks.keys.sorted().prefix(clocks.count - 64) { clocks[key] = nil } }
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
    func startMeasurement() async throws {
        guard !measurementRunning else { throw V21Error.contract("A manual measurement is already running") }
        // Mark before awaiting preparation, so a second Start cannot create a concurrent session.
        measurementRunning = true
        measurementStopRequested = false
        do {
            guard let url = InputResources.url("ordinary_probes_160", extension: "json", directory: "V22") else {
                throw V21Error.resource("Missing supplied finite measurement inputs")
            }
            let probes = try JSONDecoder().decode([V22MeasurementProbe].self, from: Data(contentsOf: url))
            guard (1...200).contains(probes.count) else { throw V21Error.contract("Invalid finite measurement count") }
            let kernel = try await prepare()
            guard !measurementStopRequested else { throw CancellationError() }
            let session = V22MeasurementSession(kernel: kernel, recorder: KernelMeasurement.shared.recorder, configurationLabel: "all; user-started; main-App process")
            let first = version + 1; version += UInt64(probes.count)
            measurement = session
            measurementTask = Task {
                do { try await session.run(probes: probes, firstVersion: first) }
                catch { KernelMeasurement.shared.preparationFailed(error) }
                self.measurementRunning = false
            }
        } catch { measurementRunning = false; throw error }
    }
    func stopMeasurement() async {
        measurementStopRequested = true
        measurementTask?.cancel()
        if let measurement { await measurement.stop() }
    }
    func exportMeasurement() async throws -> URL? {
        guard let measurement else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("V22-finite-session.json")
        try await measurement.export(to: url)
        return url
    }
}

struct V21CandidateBatch: Sendable {
    let items: [Candidate]
    let completedPaths: Int
    let isFinal: Bool
    var timing: V22AppTiming? = nil
}
