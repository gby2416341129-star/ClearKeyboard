import Foundation

/// Chinese paths use the local Qwen model and phonetic consumption constraints.
/// English completion retains its separate dictionary and case-handling API.
public final class InputEngine {
    public let english: Lexicon
    private let decoder: QwenDecoder
    public var chineseBackend: String { "qwen3.5-0.8b-q4_k_m" }
    public var backendRevision: Int { QwenDecoder.revision }
    private init(english: Lexicon, decoder: QwenDecoder) { self.english = english; self.decoder = decoder }
    public static func bundled() throws -> InputEngine {
        try InputEngine(english: .bundled("english"), decoder: .bundled())
    }
    public func immediateCandidates(_ raw: String, preferred: [Candidate] = []) -> [Candidate] {
        PersonalLexicon.merging(preferred, into: decoder.cached(raw), limit: 8)
    }
    public func candidates(_ raw: String, fuzzy: Set<String> = [], learned: [String: Int] = [:],
                           preferred: [Candidate] = [], recentCorrections: [Candidate] = [],
                           limit: Int = 24, compose: Bool = true, correction: Bool = true,
                           context: String = "", cancelled: () -> Bool = { false },
                           updated: (([Candidate], Bool) -> Void)? = nil) -> [Candidate] {
        guard !raw.isEmpty, !cancelled() else { return [] }
        let normalized = FuzzyPinyin.normalize(raw)
        let valid = (preferred + (correction ? recentCorrections : [])).filter {
            !$0.text.isEmpty && $0.consumed > 0 && $0.consumed <= normalized.count
        }
        let query = Composition.queryPrefix(raw, normalized: normalized)
        var generated = decoder.candidates(query, context: context, fuzzy: fuzzy, correction: correction,
                                           limit: limit, cancelled: cancelled, updated: { items, more in
            updated?(PersonalLexicon.merging(valid, into: items, limit: max(1, limit)), more)
        })
        guard !cancelled() else { return [] }
        if !learned.isEmpty {
            generated = generated.enumerated().sorted { a, b in
                let x = learned[normalized + "|" + a.element.text] ?? learned[a.element.text] ?? 0
                let y = learned[normalized + "|" + b.element.text] ?? learned[b.element.text] ?? 0
                return x == y ? a.offset < b.offset : x > y
            }.map(\.element)
        }
        var output = PersonalLexicon.merging(valid, into: generated, limit: max(1, limit))
        // An explicit raw-spelling choice remains available for mixed-language
        // input. It is not a substitute engine when the model cannot load.
        if output.count < limit, !normalized.isEmpty, !output.contains(where: { $0.text == raw }) {
            output.append(Candidate(text: raw, consumed: normalized.count))
        }
        return Array(output.prefix(max(1, limit)))
    }
    public func characterCandidates(_ raw: String, fuzzy: Set<String> = [], cancelled: () -> Bool = { false }) -> [Candidate] {
        let query = Composition.queryPrefix(raw, normalized: FuzzyPinyin.normalize(raw))
        return decoder.candidates(query, fuzzy: fuzzy, characterOnly: true, limit: 4096, cancelled: cancelled)
    }
    public func predictions(after context: String, cancelled: () -> Bool = { false }) -> [Candidate] {
        decoder.candidates("", context: context, correction: false, limit: 12, cancelled: cancelled)
    }
    public func englishCandidates(prefix: String) -> [Candidate] {
        let normalized = FuzzyPinyin.normalize(prefix)
        return english.lookup("p:" + normalized, limit: 12)
            .filter { $0.text.lowercased() != prefix.lowercased() }
            .map { Candidate(text: $0.text, consumed: prefix.count) }
    }
    public func englishPredictions(after context: String) -> [Candidate] {
        let word = EnglishContext.word(in: context).lowercased()
        let words = ["thank": ["you", "you so much"], "how": ["are", "do", "is"],
            "good": ["morning", "night", "idea"], "see": ["you", "you soon"], "i": ["am", "will", "think"],
            "let": ["me", "us"], "would": ["you", "like"], "have": ["a", "you"],
            "you": ["are", "can", "have"], "looking": ["forward", "good"]]
        return (words[word] ?? []).map { Candidate(text: $0, consumed: 0) }
    }
}
