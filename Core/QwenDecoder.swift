import Foundation
#if SWIFT_PACKAGE
import CQwen
#endif

private final class QwenCancellation {
    let cancelled: () -> Bool
    init(_ cancelled: @escaping () -> Bool) { self.cancelled = cancelled }
}
private let qwenCancelled: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { opaque in
    guard let opaque else { return 0 }
    return Unmanaged<QwenCancellation>.fromOpaque(opaque).takeUnretainedValue().cancelled() ? 1 : 0
}

final class QwenDecoder {
    enum LoadError: LocalizedError {
        case missingResources, runtime(String)
        var errorDescription: String? {
            switch self {
            case .missingResources: return "缺少 Qwen 模型或拼音约束数据"
            case .runtime(let message): return message
            }
        }
    }
    private static let ownerLock = NSLock()
    private static var owner: QwenDecoder?
    private let lock = NSLock()
    private let handle: OpaquePointer
    private var immediate: [String: [Candidate]] = [:]
    private var immediateOrder: [String] = []
    private let cacheLock = NSLock()
    static let revision = 78

    static func bundled() throws -> QwenDecoder {
        ownerLock.lock(); defer { ownerLock.unlock() }
        if let owner { return owner }
        let decoder = try QwenDecoder(); owner = decoder; return decoder
    }
    private init() throws {
        guard let model = InputResources.url("Qwen3.5-0.8B-Q4_K_M", extension: "gguf", directory: "Models"),
              let phonetics = InputResources.url("unicode-pinyin", extension: "tsv", directory: "Phonetics") else { throw LoadError.missingResources }
        guard let value = ck_qwen_create(model.path, phonetics.path) else {
            throw LoadError.runtime(String(cString: ck_qwen_error()))
        }
        handle = value
    }
    deinit { ck_qwen_destroy(handle) }
    // Completed Qwen results only; key events never enter the generation lock.
    func cached(_ raw: String) -> [Candidate] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return immediate[raw] ?? []
    }
    func candidates(_ raw: String, context: String = "", fuzzy: Set<String> = [],
                    correction: Bool = true, characterOnly: Bool = false,
                    limit: Int = 24, cancelled: () -> Bool = { false }) -> [Candidate] {
        guard !cancelled() else { return [] }
        lock.lock(); defer { lock.unlock() }
        guard !cancelled() else { return [] }
        let mask = FuzzyPinyin.availablePairs.enumerated().reduce(UInt32(0)) { value, pair in
            fuzzy.contains(pair.element) ? value | (UInt32(1) << UInt32(pair.offset)) : value
        }
        return withoutActuallyEscaping(cancelled) { callback in
            let cancellation = QwenCancellation(callback)
            let opaque = Unmanaged.passUnretained(cancellation).toOpaque()
            let count = ck_qwen_query(handle, raw, context, mask, correction ? 1 : 0,
                                     characterOnly ? 1 : 0, Int32(clamping: max(1, min(4096, limit))), qwenCancelled, opaque)
            guard !callback(), count > 0 else { return [] }
            let maximum = FuzzyPinyin.normalize(raw).count
            var output: [Candidate] = []
            for index in 0..<count {
                let text = String(cString: ck_qwen_text(handle, index))
                let consumed = Int(ck_qwen_consumed(handle, index))
                guard !text.isEmpty, consumed >= 0, consumed <= maximum,
                      raw.isEmpty || consumed > 0 else { continue }
                output.append(Candidate(text: text, reading: String(cString: ck_qwen_reading(handle, index)),
                                        consumed: consumed, score: ck_qwen_score(handle, index)))
            }
            if !raw.isEmpty, !characterOnly, !callback() {
                cacheLock.lock()
                // A later request may have different fuzzy settings or context.
                // The context-free hot row reuses exact aligned readings only.
                let spelling = FuzzyPinyin.normalize(raw)
                immediate[raw] = Array(output.filter { candidate in
                    let reading = FuzzyPinyin.normalize(candidate.reading)
                    return !reading.isEmpty && reading.count == candidate.consumed && spelling.hasPrefix(reading)
                }.prefix(8))
                immediateOrder.removeAll { $0 == raw }; immediateOrder.append(raw)
                while immediateOrder.count > 128 { immediate.removeValue(forKey: immediateOrder.removeFirst()) }
                cacheLock.unlock()
            }
            return output
        }
    }
}
