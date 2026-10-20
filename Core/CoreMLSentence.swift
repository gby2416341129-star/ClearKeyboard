import Foundation
#if canImport(CoreML)
import CoreML
#endif

/// Optional Apple accelerator. Model loading and predictions never use the main
/// queue. The caller waits only within the existing query budget; a timed-out
/// prediction cannot publish a late candidate or retain C bridge pointers.
final class CoreMLSentence {
    static let shared = CoreMLSentence()
    private let queue = DispatchQueue(label: "clear.coreml", qos: .utility)
    private let lock = NSLock()
    private var started = false, ready = false, busy = false, memoryConstrained = false
    private var failures = 0
    private var memoryObserver: NSObjectProtocol?
    #if canImport(CoreML)
    private var model: MLModel?
    private var vocabulary: [Character: Int] = [:]
    #endif
    private final class Request {
        let lock = NSLock(), signal = DispatchSemaphore(value: 0)
        var result: [Float]?, abandoned = false
    }
    private init() {}

    func start(directory: URL) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true; lock.unlock()
        memoryObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"), object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.ready = false; self.memoryConstrained = true; self.lock.unlock()
            self.queue.async {
                #if canImport(CoreML)
                self.model = nil
                #endif
            }
        }
        #if canImport(CoreML)
        queue.async { [self] in
            do {
                let url = directory.appendingPathComponent("ClearSentence4M.mlmodelc", isDirectory: true)
                let data = try Data(contentsOf: directory.appendingPathComponent("CoreML4M-validation.json"))
                guard let validation = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let inputs = validation["inputs"] as? [String: Any],
                      let expected = validation["expected"] as? [Double], expected.count == 9 else { return }
                var features: [String: MLFeatureValue] = [:]
                for (name, shape) in [("tokens", [9, 16]), ("targets", [9, 16, 3]), ("mask", [9, 16])] {
                    guard let raw = inputs[name] else { return }
                    let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
                    let values = flatten(raw)
                    guard values.count == array.count else { return }
                    for i in values.indices { array[i] = NSNumber(value: values[i]) }
                    features[name] = MLFeatureValue(multiArray: array)
                }
                let provider = try MLDictionaryFeatureProvider(dictionary: features)
                // Compare the two public Core ML configurations on THIS device.
                // This is a latency gate, not a measurement of battery energy or
                // proof that every operation actually executes on the ANE.
                let cpuTimes = try autoreleasepool { () throws -> [Double] in
                    let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuOnly
                    let cpu = try MLModel(contentsOf: url, configuration: configuration)
                    return try profile(cpu, provider: provider, expected: expected)
                }
                let configuration = MLModelConfiguration()
                configuration.computeUnits = .cpuAndNeuralEngine
                let accelerated = try MLModel(contentsOf: url, configuration: configuration)
                let acceleratedTimes = try profile(accelerated, provider: provider, expected: expected)
                guard let metadata = accelerated.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
                      metadata["source_sha256"] == "86ac529510cb3b4968a5e6ade83ec8080f5b34a0a681e75c362accbbd387d1c1",
                      let bytes = metadata["vocab"]?.data(using: .utf8),
                      let vocab = try JSONSerialization.jsonObject(with: bytes) as? [String], vocab.count == 8192 else { return }
                var lookup: [Character: Int] = [:]
                for (i, text) in vocab.enumerated() where i > 2 && text.count == 1 { lookup[text.first!] = i }
                let cpuMedian = cpuTimes.sorted()[cpuTimes.count / 2]
                let acceleratedMedian = acceleratedTimes.sorted()[acceleratedTimes.count / 2]
                // Warm-up is separate. Retain this backend only with a clear
                // latency advantage and enough room in the 8 ms total budget.
                let enabled = acceleratedMedian < cpuMedian * 0.9 && acceleratedTimes.max()! < 4
                let diagnostics: [String: Any] = ["cpuOnlyMS": cpuTimes, "cpuAndNeuralEngineMS": acceleratedTimes,
                    "numericalValidation": "passed", "enabled": enabled, "actualANEPlacementVerified": false,
                    "energyMeasured": false, "comparison": "Core ML configurations; not custom native CPU or WeChat"]
                if let bytes = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]),
                   let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                    try? bytes.write(to: cache.appendingPathComponent("ClearKeyboard-CoreML4M.json"), options: .atomic)
                }
                guard enabled else { return }
                model = accelerated; vocabulary = lookup
                lock.lock(); let constrained = memoryConstrained; ready = !constrained; lock.unlock()
                if constrained { model = nil }
            } catch {
                // Missing/unsupported model or failed self-check: keep native
                // decoding. Never publish unverified model results.
            }
        }
        #endif
    }

    func score(_ texts: [String], milliseconds: Double, cancelled: () -> Bool) -> [Float]? {
        #if canImport(CoreML)
        guard texts.count > 1, texts.count <= 9, texts.allSatisfy({ !$0.isEmpty && $0.count <= 16 }),
              milliseconds > 0.2, !cancelled() else { return nil }
        let start = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard ready, !busy else { lock.unlock(); return nil }
        busy = true; lock.unlock()
        let request = Request()
        queue.async { [self] in
            defer { lock.lock(); busy = false; lock.unlock(); request.signal.signal() }
            request.lock.lock(); let abandoned = request.abandoned; request.lock.unlock()
            guard !abandoned, let model else { return }
            let result: [Float]? = autoreleasepool {
                do {
                    var rows = texts
                    while rows.count < 9 { rows.append(texts.last!) }
                    let tokens = try MLMultiArray(shape: [9, 16], dataType: .float32)
                    let targets = try MLMultiArray(shape: [9, 16, 3], dataType: .float32)
                    let mask = try MLMultiArray(shape: [9, 16], dataType: .float32)
                    for (row, text) in rows.enumerated() {
                        let characters = Array(text)
                        guard !characters.isEmpty, characters.count <= 16 else { return nil }
                        let ids = characters.compactMap { vocabulary[$0] }
                        guard ids.count == characters.count else { return nil }
                        for position in 0..<16 {
                            let offset = row * 16 + position
                            tokens[offset] = NSNumber(value: position == 0 ? 2 : (position < ids.count ? ids[position - 1] : 0))
                            targets[offset * 3] = NSNumber(value: row)
                            targets[offset * 3 + 1] = NSNumber(value: position)
                            targets[offset * 3 + 2] = NSNumber(value: position < ids.count ? ids[position] : 0)
                            mask[offset] = NSNumber(value: position < ids.count ? 1 : 0)
                        }
                    }
                    let provider = try MLDictionaryFeatureProvider(dictionary: ["tokens": MLFeatureValue(multiArray: tokens),
                        "targets": MLFeatureValue(multiArray: targets), "mask": MLFeatureValue(multiArray: mask)])
                    let prediction = try model.prediction(from: provider)
                    guard let scores = prediction.featureValue(for: "scores")?.multiArrayValue, scores.count == 9 else { return nil }
                    let result = (0..<texts.count).map { scores[$0].floatValue }
                    return result.allSatisfy(\.isFinite) ? result : nil
                } catch { return nil }
            }
            request.lock.lock()
            if !request.abandoned { request.result = result }
            request.lock.unlock()
            if result == nil {
                lock.lock(); failures += 1
                if failures >= 3 { ready = false }
                lock.unlock()
            }
        }
        let allowance = min(milliseconds, 4) / 1000
        while ProcessInfo.processInfo.systemUptime - start < allowance, !cancelled() {
            let remaining = allowance - (ProcessInfo.processInfo.systemUptime - start)
            if request.signal.wait(timeout: .now() + min(0.00015, max(0, remaining))) == .success {
                request.lock.lock(); let result = request.result; request.lock.unlock()
                return result
            }
        }
        request.lock.lock(); request.abandoned = true; request.lock.unlock()
        if !cancelled() {
            lock.lock(); failures += 1
            if failures >= 3 { ready = false }
            lock.unlock()
        }
        #endif
        return nil
    }

    #if canImport(CoreML)
    private func flatten(_ value: Any) -> [Float] {
        if let number = value as? NSNumber { return [number.floatValue] }
        if let values = value as? [Any] { return values.flatMap(flatten) }
        return []
    }
    private func profile(_ model: MLModel, provider: MLFeatureProvider, expected: [Double]) throws -> [Double] {
        var times: [Double] = []
        for iteration in 0..<4 {
            let start = ProcessInfo.processInfo.systemUptime
            let output = try model.prediction(from: provider)
            guard let scores = output.featureValue(for: "scores")?.multiArrayValue, scores.count == expected.count,
                  expected.indices.allSatisfy({ scores[$0].doubleValue.isFinite && abs(scores[$0].doubleValue - expected[$0]) < 0.015 }) else {
                throw LexiconError.invalidFormat
            }
            if iteration > 0 { times.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
        }
        return times
    }
    #endif
}
