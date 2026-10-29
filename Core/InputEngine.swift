import Foundation

/// Chinese decoding uses our phonetic graph, lexical index and personal data.
/// The delivered V10 model supplies calibrated ranking/adoption decisions only.
/// English completion retains its separate dictionary and case-handling API.
public final class InputEngine {
    public let english: Lexicon
    private let decoder: NativeDecoder
    public var chineseBackend: String { "clear-native+V10" }
    public var backendRevision: Int { NativeDecoder.revision }
    private init(english: Lexicon, decoder: NativeDecoder) { self.english = english; self.decoder = decoder }
    public static func bundled() throws -> InputEngine {
        try InputEngine(english: .bundled("english"), decoder: .bundled())
    }
    public func immediateCandidates(_ raw: String, preferred: [Candidate] = [], context: String = "",
                                    fuzzy: Set<String> = [], correction: Bool = true,
                                    cancelled: () -> Bool = { false }) -> [Candidate] {
        let query = Composition.queryPrefix(raw, normalized: FuzzyPinyin.normalize(raw))
        return PersonalLexicon.merging(preferred, into: decoder.preview(query, context: context, fuzzy: fuzzy,
                                                                       correction: correction, cancelled: cancelled), limit: 8)
    }
    public func candidates(_ raw: String, fuzzy: Set<String> = [], learned: [String: Int] = [:],
                           preferred: [Candidate] = [], recentCorrections: [Candidate] = [],
                           limit: Int = 24, compose: Bool = true, correction: Bool = true,
                           context: String = "", cancelled: () -> Bool = { false },
                           updated: (([Candidate], Bool, Bool) -> Void)? = nil) -> [Candidate] {
        guard !raw.isEmpty, !cancelled() else { return [] }
        let normalized = FuzzyPinyin.normalize(raw)
        let valid = (preferred + (correction ? recentCorrections : [])).filter {
            !$0.text.isEmpty && $0.consumed > 0 && $0.consumed <= normalized.count
        }
        let query = Composition.queryPrefix(raw, normalized: normalized)
        var generated = decoder.candidates(query, context: context, fuzzy: fuzzy, correction: correction,
                                           limit: max(32, limit + 1), cancelled: cancelled)
        guard !cancelled() else { return [] }
        if !learned.isEmpty {
            generated = generated.enumerated().sorted { a, b in
                let x = learned[normalized + "|" + a.element.text] ?? learned[a.element.text] ?? 0
                let y = learned[normalized + "|" + b.element.text] ?? learned[b.element.text] ?? 0
                return x == y ? a.offset < b.offset : x > y
            }.map(\.element)
        }
        var output = PersonalLexicon.merging(valid, into: generated, limit: max(32, limit + 1))
        output = output.enumerated().map { index, candidate in candidate.withPath(candidate.path?.ranked(index)) }
        let ruleID = output.first?.stableID
        updated?(Array(output.prefix(max(1,limit))), output.count > limit, false)
        if let ruleID, !cancelled() {
            let mixed=output.first?.text.unicodeScalars.contains(where:{$0.isASCII && CharacterSet.letters.contains($0)}) == true
            output=ClearV10Scorer.shared.rank(output,raw:raw,context:context,mode:mixed ? .mixed:.pinyin,
                ruleCandidateID:ruleID,settingsKey:fuzzy.sorted().joined(separator:",")+(correction ? ":correct":":exact"),cancelled:cancelled)
        }
        guard !cancelled() else { return [] }
        updated?(Array(output.prefix(max(1,limit))), output.count > limit, true)
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
        let native=decoder.candidates("", context: context, correction: false, limit: 32, cancelled: cancelled)
        guard let rule=native.first?.stableID, !cancelled() else{return native}
        return Array(ClearV10Scorer.shared.rank(native,raw:"",context:context,mode:.pinyin,
            ruleCandidateID:rule,settingsKey:"association",cancelled:cancelled).prefix(12))
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
