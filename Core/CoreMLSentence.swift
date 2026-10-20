import Foundation
#if canImport(CoreML)
import CoreML
import os
#endif
#if canImport(CRime)
import CRime
#endif

/// Optional bounded prefix predictor. Loading and prediction never run on the
/// main thread or retain C pointers; the input worker owns the deadline.
final class CoreMLSentence {
    static let shared = CoreMLSentence()
    private let queue = DispatchQueue(label: "clear.coreml", qos: .userInitiated)
    private let lock = NSCondition()
    private var started = false, ready = false, busy = false, constrained = false
    private var failures = 0, epoch = 0
    private var memoryObserver: NSObjectProtocol?
    var revision: Int { lock.lock(); defer { lock.unlock() }; return epoch }
    #if canImport(CoreML)
    private var prefixState: CoreMLPrefixState?
    #endif
    private final class Request {
        let lock = NSLock(), signal = DispatchSemaphore(value: 0)
        var result: [Float]?, abandoned = false, faulted = false
    }
    func start(directory: URL) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true; lock.unlock()
        memoryObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"), object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.ready = false; self.constrained = true; self.lock.broadcast(); self.lock.unlock()
            self.queue.async {
                #if canImport(CoreML)
                self.prefixState = nil
                #endif
            }
            DispatchQueue.global(qos: .utility).async { cr_trim_sentence_cache() }
        }
        #if canImport(CoreML) && os(iOS)
        queue.async { [self] in
            do {
                // Check the extension's remaining allowance, not total phone RAM.
                guard os_proc_available_memory() >= 64 * 1_024 * 1_024 else { return }
                let bytes = try Data(contentsOf: directory.appendingPathComponent("CoreML25M-validation.json"))
                guard let validation = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      validation["format"] as? String == "clear-kv-v1",
                      let sequences = validation["sequences"] as? [String], sequences.count == 8,
                      sequences.allSatisfy({ $0.count == 15 }),
                      let expected = validation["expected"] as? [[String: Any]], expected.count >= 200 else { return }
                let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuAndNeuralEngine
                let accelerated = try MLModel(contentsOf: directory.appendingPathComponent("ClearSentence25M.mlmodelc"), configuration: configuration)
                guard let metadata = accelerated.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
                      metadata["source_sha256"] == "0a6ecba69bf1d39c7eb49549c716477dd6c03fdf05757773e1f50435262fb469",
                      metadata["state_format"] == "clear-kv-v1: layers,batch,time,hidden -> batch,layers,hidden",
                      let encoded = metadata["vocab"]?.data(using: .utf8),
                      let vocab = try JSONSerialization.jsonObject(with: encoded) as? [String], vocab.count == 12_288 else { return }
                let state = try CoreMLPrefixState(model: accelerated, vocabulary: vocab)
                var timings: [Double] = [], validated = 0
                for step in 0..<16 {
                    guard let output = try state.next(sequences.map { String($0.prefix(step)) }, abandoned: { false }) else { return }
                    for item in expected where item["step"] as? Int == step {
                        guard let row = item["row"] as? Int, let token = item["token"] as? Int,
                              let value = item["value"] as? Double,
                              (0..<8).contains(row), (0..<12_288).contains(token),
                              output[row * 12_288 + token].isFinite,
                              abs(Double(output[row * 12_288 + token]) - value) < 0.025 else { return }
                        validated += 1
                    }
                    if step >= 14 { timings.append(state.lastPredictionMilliseconds) }
                }
                guard validated == expected.count else { return }
                let enabled = timings.max().map { $0 < 4 } ?? false
                let diagnostics: [String: Any] = ["model": "25M", "stateFormat": "clear-kv-v1", "predictionMS": timings,
                    "numericalValidation": "passed", "enabled": enabled,
                    "actualANEPlacementVerified": false, "energyMeasured": false]
                if let bytes = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]),
                   let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                    try? bytes.write(to: cache.appendingPathComponent("ClearKeyboard-CoreML25M.json"), options: .atomic)
                }
                guard enabled else { return }
                lock.lock(); let limited = constrained; lock.unlock()
                guard !limited else { return }
                prefixState = state
                lock.lock(); ready = true; lock.unlock()
                cr_set_sentence_predictor({ pointers, count, output, vocabularySize, milliseconds, cancelled, cancelContext, _ in
                    guard let pointers, let output, count > 0, count <= 8, vocabularySize == 12_288 else { return 0 }
                    var prefixes: [String] = []
                    for index in 0..<Int(count) {
                        guard let pointer = pointers[index] else { return 0 }
                        prefixes.append(String(cString: pointer))
                    }
                    guard let values = CoreMLSentence.shared.next(prefixes, milliseconds: milliseconds,
                        cancelled: { (cancelled?(cancelContext) ?? 0) != 0 }), values.count == Int(count) * 12_288 else { return 0 }
                    values.withUnsafeBufferPointer { source in output.update(from: source.baseAddress!, count: source.count) }
                    return 1
                }, nil)
                lock.lock(); epoch += 1; lock.unlock()
            } catch { }
        }
        #endif
    }
    func next(_ prefixes: [String], milliseconds: Double, cancelled: () -> Bool) -> [Float]? {
        #if canImport(CoreML)
        guard !prefixes.isEmpty, prefixes.count <= 8, prefixes.allSatisfy({ $0.count < 16 }),
              milliseconds > 0.2, !cancelled() else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        // A cancelled key may leave one prediction finishing on the serial
        // queue. Give that bounded operation time to release its slot instead
        // of discarding the latest key merely because the old one is busy.
        // This worker wait never blocks the main thread or grows a request queue.
        let allowance = min(milliseconds, 8) / 1_000
        let idleDeadline = started + min(allowance / 2, 0.004)
        lock.lock()
        while ready && busy && !cancelled() && ProcessInfo.processInfo.systemUptime < idleDeadline {
            let remaining = idleDeadline - ProcessInfo.processInfo.systemUptime
            _ = lock.wait(until: Date(timeIntervalSinceNow: min(0.001, max(0, remaining))))
        }
        guard ready, !busy, !cancelled(), ProcessInfo.processInfo.systemUptime - started < allowance else { lock.unlock(); return nil }
        busy = true; lock.unlock()
        let request = Request()
        queue.async { [self] in
            defer { lock.lock(); busy = false; lock.broadcast(); lock.unlock(); request.signal.signal() }
            request.lock.lock(); let abandoned = request.abandoned; request.lock.unlock()
            guard !abandoned, let prefixState else { return }
            var faulted = false
            let result: [Float]? = autoreleasepool {
                do {
                    return try prefixState.next(prefixes, abandoned: {
                        request.lock.lock(); defer { request.lock.unlock() }; return request.abandoned
                    })
                } catch { faulted = true; return nil }
            }
            request.lock.lock()
            if !request.abandoned { request.result = result; request.faulted = faulted }
            request.lock.unlock()
        }
        while ProcessInfo.processInfo.systemUptime - started < allowance, !cancelled() {
            let remaining = allowance - (ProcessInfo.processInfo.systemUptime - started)
            if request.signal.wait(timeout: .now() + min(0.00015, max(0, remaining))) == .success {
                request.lock.lock(); let result = request.result, faulted = request.faulted; request.lock.unlock()
                if result != nil { lock.lock(); failures = 0; lock.unlock() }
                else if faulted { failed() }
                return result
            }
        }
        request.lock.lock(); request.abandoned = true; request.lock.unlock()
        // An ordinary deadline or cancellation says nothing about model
        // integrity. Its finished ancestors remain usable by the latest key.
        // Only a thrown runtime/cache/numerical error counts as a fault.
        #endif
        return nil
    }
    private func failed() { lock.lock(); failures += 1; if failures >= 3 { ready = false }; lock.broadcast(); lock.unlock() }
}
