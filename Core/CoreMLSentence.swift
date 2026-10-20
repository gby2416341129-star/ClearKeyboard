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
    private let lock = NSLock()
    private var started = false, ready = false, busy = false, constrained = false
    private var failures = 0, epoch = 0
    private var memoryObserver: NSObjectProtocol?
    var revision: Int { lock.lock(); defer { lock.unlock() }; return epoch }
    #if canImport(CoreML)
    private var model: MLModel?
    private var vocabulary: [Character: Int] = [:]
    #endif
    private final class Request {
        let lock = NSLock(), signal = DispatchSemaphore(value: 0)
        var result: [Float]?, abandoned = false
    }
    func start(directory: URL) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true; lock.unlock()
        memoryObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"), object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.ready = false; self.constrained = true; self.lock.unlock()
            self.queue.async {
                #if canImport(CoreML)
                self.model = nil
                #endif
            }
            DispatchQueue.global(qos: .utility).async { cr_trim_sentence_cache() }
        }
        #if canImport(CoreML)
        queue.async { [self] in
            do {
                // Check the extension's remaining allowance, not total phone RAM.
                guard os_proc_available_memory() >= 64 * 1_024 * 1_024 else { return }
                let bytes = try Data(contentsOf: directory.appendingPathComponent("CoreML25M-validation.json"))
                guard let validation = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let inputs = validation["inputs"] as? [String: Any],
                      let expected = validation["expected"] as? [[String: Any]], !expected.isEmpty else { return }
                var features: [String: MLFeatureValue] = [:]
                for (name, shape) in [("tokens", [8, 16]), ("positions", [8, 2])] {
                    guard let raw = inputs[name] else { return }
                    let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
                    let values = flatten(raw)
                    guard values.count == array.count else { return }
                    for i in values.indices { array[i] = NSNumber(value: values[i]) }
                    features[name] = MLFeatureValue(multiArray: array)
                }
                let provider = try MLDictionaryFeatureProvider(dictionary: features)
                let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuAndNeuralEngine
                let accelerated = try MLModel(contentsOf: directory.appendingPathComponent("ClearSentence25M.mlmodelc"), configuration: configuration)
                guard let metadata = accelerated.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
                      metadata["source_sha256"] == "0a6ecba69bf1d39c7eb49549c716477dd6c03fdf05757773e1f50435262fb469",
                      let encoded = metadata["vocab"]?.data(using: .utf8),
                      let vocab = try JSONSerialization.jsonObject(with: encoded) as? [String], vocab.count == 12_288 else { return }
                var timings: [Double] = []
                for iteration in 0..<3 {
                    let start = ProcessInfo.processInfo.systemUptime
                    let prediction = try accelerated.prediction(from: provider)
                    guard let output = prediction.featureValue(for: "log_probs")?.multiArrayValue,
                          output.count == 8 * 12_288 else { return }
                    for item in expected {
                        guard let row = item["row"] as? Int, let token = item["token"] as? Int,
                              let value = item["value"] as? Double,
                              (0..<8).contains(row), (0..<12_288).contains(token),
                              output[row * 12_288 + token].doubleValue.isFinite,
                              abs(output[row * 12_288 + token].doubleValue - value) < 0.025 else { return }
                    }
                    if iteration > 0 { timings.append((ProcessInfo.processInfo.systemUptime - start) * 1_000) }
                }
                let enabled = timings.max().map { $0 < 4 } ?? false
                let diagnostics: [String: Any] = ["model": "25M", "predictionMS": timings,
                    "numericalValidation": "passed", "enabled": enabled,
                    "actualANEPlacementVerified": false, "energyMeasured": false]
                if let bytes = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]),
                   let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                    try? bytes.write(to: cache.appendingPathComponent("ClearKeyboard-CoreML25M.json"), options: .atomic)
                }
                guard enabled else { return }
                lock.lock(); let limited = constrained; lock.unlock()
                guard !limited else { return }
                model = accelerated
                for (index, text) in vocab.enumerated() where index > 2 && text.count == 1 { vocabulary[text.first!] = index }
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
        lock.lock(); guard ready, !busy else { lock.unlock(); return nil }; busy = true; lock.unlock()
        let request = Request()
        queue.async { [self] in
            defer { lock.lock(); busy = false; lock.unlock(); request.signal.signal() }
            request.lock.lock(); let abandoned = request.abandoned; request.lock.unlock()
            guard !abandoned, let model else { return }
            let result: [Float]? = autoreleasepool {
                do {
                    let tokens = try MLMultiArray(shape: [8, 16], dataType: .float32)
                    let positions = try MLMultiArray(shape: [8, 2], dataType: .float32)
                    for index in 0..<tokens.count { tokens[index] = 0 }
                    for row in 0..<8 {
                        let prefix = prefixes[min(row, prefixes.count - 1)]
                        let characters = Array(prefix), ids = characters.compactMap { vocabulary[$0] }
                        guard ids.count == characters.count else { return nil }
                        tokens[row * 16] = 2
                        for index in ids.indices { tokens[row * 16 + index + 1] = NSNumber(value: ids[index]) }
                        positions[row * 2] = NSNumber(value: row)
                        positions[row * 2 + 1] = NSNumber(value: ids.count)
                    }
                    let input = try MLDictionaryFeatureProvider(dictionary: ["tokens": MLFeatureValue(multiArray: tokens),
                        "positions": MLFeatureValue(multiArray: positions)])
                    let prediction = try model.prediction(from: input)
                    guard let output = prediction.featureValue(for: "log_probs")?.multiArrayValue,
                          output.dataType == .float32, output.shape.map(\.intValue) == [8, 12_288],
                          output.strides.map(\.intValue) == [12_288, 1] else { return nil }
                    let count = prefixes.count * 12_288
                    let values = Array(UnsafeBufferPointer(start: output.dataPointer.assumingMemoryBound(to: Float.self), count: count))
                    return values.allSatisfy(\.isFinite) ? values : nil
                } catch { return nil }
            }
            request.lock.lock(); if !request.abandoned { request.result = result }; request.lock.unlock()
        }
        let allowance = min(milliseconds, 4) / 1_000
        while ProcessInfo.processInfo.systemUptime - started < allowance, !cancelled() {
            let remaining = allowance - (ProcessInfo.processInfo.systemUptime - started)
            if request.signal.wait(timeout: .now() + min(0.00015, max(0, remaining))) == .success {
                request.lock.lock(); let result = request.result; request.lock.unlock()
                if result == nil { failed() }; return result
            }
        }
        request.lock.lock(); request.abandoned = true; request.lock.unlock()
        if !cancelled() { failed() }
        #endif
        return nil
    }
    private func failed() { lock.lock(); failures += 1; if failures >= 3 { ready = false }; lock.unlock() }
    #if canImport(CoreML)
    private func flatten(_ value: Any) -> [Float] {
        if let number = value as? NSNumber { return [number.floatValue] }
        if let values = value as? [Any] { return values.flatMap(flatten) }
        return []
    }
    #endif
}
