import Foundation
#if SWIFT_PACKAGE
import CQwen
#endif

private final class QwenCancellation {
    let cancelled: () -> Bool
    let maximum: Int
    let updated: (([Candidate], Bool, Bool) -> Void)?
    init(_ cancelled: @escaping () -> Bool, raw: String, updated: (([Candidate], Bool, Bool) -> Void)?) {
        self.cancelled = cancelled; self.maximum = FuzzyPinyin.normalize(raw).count; self.updated = updated
    }
    func snapshot(_ handle: OpaquePointer, count: Int32) -> [Candidate] {
        guard count > 0 else { return [] }
        return (0..<count).compactMap { index in
            let text = String(cString: ck_qwen_text(handle, index))
            let consumed = Int(ck_qwen_consumed(handle, index))
            guard !text.isEmpty, consumed >= 0, consumed <= maximum,
                  maximum == 0 || consumed > 0 else { return nil }
            return Candidate(text: text, reading: String(cString: ck_qwen_reading(handle, index)),
                             consumed: consumed, score: ck_qwen_score(handle, index))
        }
    }
}
private let qwenUpdated: @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?, Int32, Int32) -> Void = { opaque, handle, count, more in
    guard let opaque, let handle else { return }
    let request = Unmanaged<QwenCancellation>.fromOpaque(opaque).takeUnretainedValue()
    guard !request.cancelled(), let updated = request.updated else { return }
    let snapshot = request.snapshot(handle, count: count)
    if !snapshot.isEmpty, !request.cancelled() { updated(snapshot, (more & 1) != 0, (more & 2) == 0) }
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
            case .missingResources: return "缺少 Qwen 模型或自研拼音索引"
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
    static let revision = 82

    static func bundled() throws -> QwenDecoder {
        ownerLock.lock(); defer { ownerLock.unlock() }
        if let owner { return owner }
        let decoder = try QwenDecoder(); owner = decoder; return decoder
    }
    private init() throws {
        guard let model = InputResources.url("Qwen3.5-0.8B-Q4_K_M", extension: "gguf", directory: "Models"),
              let index = InputResources.url("native", extension: "cklx", directory: "Pinyin") else { throw LoadError.missingResources }
        guard let value = ck_qwen_create(model.path, index.path) else {
            throw LoadError.runtime(String(cString: ck_qwen_error()))
        }
        handle = value
    }
    deinit { ck_qwen_destroy(handle) }
    private func mask(_ fuzzy: Set<String>) -> UInt32 {
        FuzzyPinyin.availablePairs.enumerated().reduce(UInt32(0)) { value, pair in
            fuzzy.contains(pair.element) ? value | (UInt32(1) << UInt32(pair.offset)) : value
        }
    }
    private func key(_ raw: String, _ context: String, _ fuzzy: UInt32, _ correction: Bool) -> String {
        "native82:qwen35-q4_k_m:" + raw + "\u{1f}" + context + "\u{1f}" + String(fuzzy) + (correction ? "t" : "f")
    }
    // This path uses the native lexical index. It never takes the generation
    // lock, loads the model/tokenizer, or waits for contextual ranking.
    func preview(_ raw: String, context: String, fuzzy: Set<String>, correction: Bool,
                 cancelled: () -> Bool) -> [Candidate] {
        guard !cancelled() else { return [] }
        let fuzzyMask = mask(fuzzy)
        let cacheKey = key(raw, context, fuzzyMask, correction)
        cacheLock.lock(); let cached = immediate[cacheKey]; cacheLock.unlock()
        if let cached { return cached }
        return withoutActuallyEscaping(cancelled) { callback -> [Candidate] in
            let request = QwenCancellation(callback, raw: raw, updated: nil)
            let opaque = Unmanaged.passUnretained(request).toOpaque()
            guard let page = ck_qwen_preview(handle, raw, context, fuzzyMask, correction ? 1 : 0, 8, qwenCancelled, opaque) else { return [] }
            defer { ck_qwen_preview_destroy(page) }
            guard !callback() else { return [] }
            return (0..<ck_qwen_preview_count(page)).compactMap { index in
                let text = String(cString: ck_qwen_preview_text(page, index))
                let consumed = Int(ck_qwen_preview_consumed(page, index))
                guard !text.isEmpty, consumed > 0, consumed <= request.maximum else { return nil }
                return Candidate(text: text, reading: String(cString: ck_qwen_preview_reading(page, index)),
                                 consumed: consumed, score: ck_qwen_preview_score(page, index))
            }
        }
    }
    func candidates(_ raw: String, context: String = "", fuzzy: Set<String> = [],
                    correction: Bool = true, characterOnly: Bool = false,
                    limit: Int = 24, cancelled: () -> Bool = { false },
                    updated: (([Candidate], Bool, Bool) -> Void)? = nil) -> [Candidate] {
        guard !cancelled() else { return [] }
        lock.lock(); defer { lock.unlock() }
        guard !cancelled() else { return [] }
        let fuzzyMask = mask(fuzzy)
        let cacheKey = key(raw, context, fuzzyMask, correction)
        return withoutActuallyEscaping(cancelled) { callback in
            let cancellation = QwenCancellation(callback, raw: raw, updated: updated)
            let opaque = Unmanaged.passUnretained(cancellation).toOpaque()
            let count = ck_qwen_query(handle, raw, context, fuzzyMask, correction ? 1 : 0,
                                     characterOnly ? 1 : 0, Int32(clamping: max(1, min(4096, limit))), qwenCancelled, qwenUpdated, opaque)
            guard !callback(), count > 0 else { return [] }
            let output = cancellation.snapshot(handle, count: count)
            if !raw.isEmpty, !characterOnly, !callback() {
                cacheLock.lock()
                // Context and fuzzy settings are part of the key; an old row
                // must not override a different phonetic request.
                immediate[cacheKey] = Array(output.prefix(8))
                immediateOrder.removeAll { $0 == cacheKey }; immediateOrder.append(cacheKey)
                while immediateOrder.count > 128 { immediate.removeValue(forKey: immediateOrder.removeFirst()) }
                cacheLock.unlock()
            }
            return output
        }
    }
}
