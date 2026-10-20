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
    private var started = false, ready = false, scoreReady = false, busy = false, constrained = false
    private var failures = 0, epoch = 0
    private var memoryObserver: NSObjectProtocol?
    var revision: Int { lock.lock(); defer { lock.unlock() }; return epoch }
    #if canImport(CoreML)
    private var prefixState: CoreMLPrefixState?
    private var candidateScorer: CoreMLCandidateScorer?
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
            self.lock.lock(); self.ready = false; self.scoreReady = false; self.constrained = true; self.epoch += 1; self.lock.broadcast(); self.lock.unlock()
            self.queue.async {
                #if canImport(CoreML)
                self.prefixState = nil
                self.candidateScorer = nil
                #endif
            }
            DispatchQueue.global(qos: .utility).async {
                #if canImport(CRime)
                cr_set_sentence_predictor(nil, nil); cr_set_sentence_scorer(nil, nil)
                #endif
                cr_trim_sentence_cache()
            }
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
                let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuAndNeuralEngine; configuration.functionName = "step"
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
                let scoreBytes = try Data(contentsOf: directory.appendingPathComponent("CoreML25M-score-validation.json"))
                guard let reference = try JSONSerialization.jsonObject(with: scoreBytes) as? [String: Any],
                      reference["sourceSHA256"] as? String == metadata["source_sha256"],
                      let rows = reference["rows"] as? [[String: Any]], rows.count == 8,
                      metadata["score_format"] == "clear-score-v1: 4x16 tokens,targets,valid_mask -> 4 means" else { return }
                let scoreConfiguration = MLModelConfiguration(); scoreConfiguration.computeUnits = .cpuAndNeuralEngine; scoreConfiguration.functionName = "score"
                let scoreModel = try MLModel(contentsOf: directory.appendingPathComponent("ClearSentence25M.mlmodelc"), configuration: scoreConfiguration)
                let scorer = try CoreMLCandidateScorer(model: scoreModel, vocabulary: vocab)
                var scoreTimings: [Double] = []
                for start in stride(from: 0, to: 8, by: 4) {
                    let slice = Array(rows[start..<start + 4])
                    let texts = slice.compactMap { $0["text"] as? String }
                    guard texts.count == 4, let scores = try scorer.score(texts, abandoned: { false }) else { return }
                    for row in 0..<4 {
                        guard let expected = slice[row]["score"] as? Double,
                              abs(Double(scores[row]) - expected) < 0.025 else { return }
                    }
                }
                let scoreTexts = rows.prefix(4).compactMap { $0["text"] as? String }
                for _ in 0..<3 {
                    scorer.clearScores()
                    guard try scorer.score(scoreTexts, abandoned: { false }) != nil else { return }
                    scoreTimings.append(scorer.lastPredictionMilliseconds)
                }
                let scoreEnabled = scoreTimings.max().map { $0 < 10 } ?? false
                let diagnostics: [String: Any] = ["model": "25M", "stateFormat": "clear-kv-v1", "predictionMS": timings,
                    "numericalValidation": "passed", "enabled": enabled, "scoreEnabled": scoreEnabled,
                    "scorePredictionMS": scoreTimings, "scoreCandidateLimit": 4,
                    "actualANEPlacementVerified": false, "energyMeasured": false]
                if let bytes = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]),
                   let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                    try? bytes.write(to: cache.appendingPathComponent("ClearKeyboard-CoreML25M.json"), options: .atomic)
                }
                guard enabled || scoreEnabled else { return }
                lock.lock()
                guard !constrained else { lock.unlock(); return }
                prefixState = enabled ? state : nil; candidateScorer = scoreEnabled ? scorer : nil
                ready = enabled; scoreReady = scoreEnabled
                lock.unlock()
                if enabled {
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
                }
                if scoreEnabled {
                    cr_set_sentence_scorer({ pointers, count, output, milliseconds, cancelled, cancelContext, _ in
                        guard let pointers, let output, count > 0, count <= 4 else { return 0 }
                        var sentences: [String] = []
                        for index in 0..<Int(count) {
                            guard let pointer = pointers[index] else { return 0 }; sentences.append(String(cString: pointer))
                        }
                        guard let values = CoreMLSentence.shared.score(sentences, milliseconds: milliseconds,
                            cancelled: { (cancelled?(cancelContext) ?? 0) != 0 }), values.count == Int(count) else { return 0 }
                        values.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: $0.count) }; return 1
                    }, nil)
                }
                lock.lock(); epoch += 1; lock.unlock()
            } catch { }
        }
        #endif
    }
    func next(_ prefixes: [String], milliseconds: Double, cancelled: () -> Bool) -> [Float]? {
        guard !prefixes.isEmpty, prefixes.count <= 8, prefixes.allSatisfy({ $0.count < 16 }) else { return nil }
        return perform(prefixes, wholeSentence: false, milliseconds: milliseconds, cancelled: cancelled)
    }
    func score(_ sentences: [String], milliseconds: Double, cancelled: () -> Bool) -> [Float]? {
        guard !sentences.isEmpty, sentences.count <= 4, sentences.allSatisfy({ !$0.isEmpty && $0.count <= 16 }) else { return nil }
        return perform(sentences, wholeSentence: true, milliseconds: milliseconds, cancelled: cancelled)
    }
    private func perform(_ values: [String], wholeSentence: Bool, milliseconds: Double, cancelled: () -> Bool) -> [Float]? {
        #if canImport(CoreML)
        guard milliseconds > 0.2, !cancelled() else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        // A cancelled key may leave one prediction finishing on the serial
        // queue. Give that bounded operation time to release its slot instead
        // of discarding the latest key merely because the old one is busy.
        // This worker wait never blocks the main thread or grows a request queue.
        let allowance = min(milliseconds, wholeSentence ? 12 : 8) / 1_000
        let idleDeadline = started + min(allowance / 2, 0.004)
        lock.lock()
        while (wholeSentence ? scoreReady : ready) && busy && !cancelled() && ProcessInfo.processInfo.systemUptime < idleDeadline {
            let remaining = idleDeadline - ProcessInfo.processInfo.systemUptime
            _ = lock.wait(until: Date(timeIntervalSinceNow: min(0.001, max(0, remaining))))
        }
        guard (wholeSentence ? scoreReady : ready), !busy, !cancelled(), ProcessInfo.processInfo.systemUptime - started < allowance else { lock.unlock(); return nil }
        busy = true; lock.unlock()
        let request = Request()
        queue.async { [self] in
            defer { lock.lock(); busy = false; lock.broadcast(); lock.unlock(); request.signal.signal() }
            request.lock.lock(); let abandoned = request.abandoned; request.lock.unlock()
            guard !abandoned else { return }
            var faulted = false
            let result: [Float]? = autoreleasepool {
                do {
                    let isAbandoned = {
                        request.lock.lock(); defer { request.lock.unlock() }; return request.abandoned
                    }
                    if wholeSentence { return try candidateScorer?.score(values, abandoned: isAbandoned) }
                    return try prefixState?.next(values, abandoned: isAbandoned)
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
    private func failed() { lock.lock(); failures += 1; if failures >= 3 { ready = false; scoreReady = false }; lock.broadcast(); lock.unlock() }
}
