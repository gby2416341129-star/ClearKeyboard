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
        if V10InputEncoder.isProtected(raw:raw,mode:.pinyin) {return [Self.literal(raw)]}
        let query = Composition.queryPrefix(raw, normalized: FuzzyPinyin.normalize(raw))
        let words=decoder.preview(query,context:context,fuzzy:fuzzy,correction:correction,cancelled:cancelled).map{$0.inDraft(raw)}
        let mapped=preferred.map{decoder.resolve($0,raw:query,fuzzy:fuzzy,correction:correction,cancelled:cancelled).inDraft(raw)}.filter{$0.canConsume(raw)}
        let combined=PersonalLexicon.merging(mapped,into:Self.completeFirst(words,raw:query),limit:96)
        return Array(Self.displayRow(combined,raw:query).prefix(8))
    }
    public func candidates(_ raw: String, fuzzy: Set<String> = [], learned: [String: Int] = [:],
                           preferred: [Candidate] = [], recentCorrections: [Candidate] = [],
                           limit: Int = 24, compose: Bool = true, correction: Bool = true,
                           context: String = "", cancelled: () -> Bool = { false },
                           updated: (([Candidate], Bool, Bool) -> Void)? = nil,
                           learningVersion: Int = 0, resolved: ((CandidateResolution)->Void)? = nil) -> [Candidate] {
        guard !raw.isEmpty, !cancelled() else { return [] }
        if V10InputEncoder.isProtected(raw:raw,mode:.pinyin) {return [Self.literal(raw)]}
        let normalized = FuzzyPinyin.normalize(raw)
        let valid = (preferred + (correction ? recentCorrections : [])).filter {
            !$0.text.isEmpty && $0.consumed > 0 && $0.consumed <= normalized.count
        }
        let query = Composition.queryPrefix(raw, normalized: normalized)
        let generated = decoder.candidates(query, context: context, fuzzy: fuzzy, correction: correction,
                                           limit: max(96, limit + 32), cancelled: cancelled).map{$0.inDraft(raw)}
        guard !cancelled() else { return [] }
        let nativeSnapshot=generated
        let mapped=valid.map{decoder.resolve($0,raw:query,fuzzy:fuzzy,correction:correction,cancelled:cancelled).inDraft(raw)}
        let validMapped=mapped.filter{$0.canConsume(raw)}
        let lexicalOrder=generated.sorted { a,b in
            let x=a.score + 0.25*log1p(Double(learned[normalized+"|"+a.text] ?? 0))
            let y=b.score + 0.25*log1p(Double(learned[normalized+"|"+b.text] ?? 0))
            return x==y ? (a.path?.baseRank ?? Int.max)<(b.path?.baseRank ?? Int.max):x>y
        }
        // Partition by real input coverage before truncation. A high-scoring
        // prefix cannot consume the pool needed by complete model hypotheses.
        let ruleOrder=PersonalLexicon.merging(validMapped,into:Self.completeFirst(lexicalOrder,raw:query),limit:max(96,limit+32))
        // A prefix is a valid manual selection, not an explanation of the entire
        // draft. Keep it in the display list without letting it replace a
        // complete hypothesis in the automatic decision/model request.
        let complete=ruleOrder.filter{$0.completes(query)}
        let decisionOrder=complete.isEmpty ? ruleOrder:complete
        let rankByID=Dictionary(decisionOrder.enumerated().map{($0.element.stableID,$0.offset)},uniquingKeysWith:min)
        var decisions=decisionOrder.map{c in guard let path=c.path else{return c};return c.withPath(path.ranked(rankByID[c.stableID] ?? path.baseRank))}
        var output=Self.displayRow(ruleOrder,raw:query)
        updated?(Array(output.prefix(max(1,limit))), output.count > limit, false)
        if let ruleID=decisions.first?.stableID, !cancelled() {
            let mixed=decisions.first?.text.unicodeScalars.contains(where:{$0.isASCII && CharacterSet.letters.contains($0)}) == true
            decisions=ClearV10Scorer.shared.rank(decisions,raw:raw,context:context,mode:mixed ? .mixed:.pinyin,
                ruleCandidateID:ruleID,settingsKey:fuzzy.sorted().joined(separator:",")+(correction ? ":correct":":exact")+":learning-"+String(learningVersion),cancelled:cancelled,
                nativeCandidates:nativeSnapshot,observed:resolved)
            let decisionIDs=Set(decisions.map(\.stableID))
            output=Self.displayRow(decisions+ruleOrder.filter{!decisionIDs.contains($0.stableID)},raw:query)
        }
        guard !cancelled() else { return [] }
        updated?(Array(output.prefix(max(1,limit))), output.count > limit, true)
        // An explicit raw-spelling choice remains available for mixed-language
        // input. It is not a substitute engine when the model cannot load.
        if output.count < limit, !normalized.isEmpty, !output.contains(where: { $0.text == raw }) {
            output.append(Candidate(text:raw,consumed:normalized.count,path:CandidatePath(kind:.literal,frequency:0,editCost:0,consumedEnd:raw.unicodeScalars.count,segments:[raw.unicodeScalars.count])))
        }
        return Array(output.prefix(max(1, limit)))
    }
    /// Complete hypotheses and prefix selections serve different actions.
    /// Display several complete alternatives, then a few selectable prefixes;
    /// retain every remaining object and its original consumption metadata.
    private static func completeFirst(_ words:[Candidate],raw:String)->[Candidate] {
        words.filter{$0.completes(raw)} + words.filter{!$0.completes(raw)}
    }
    private static func displayRow(_ words:[Candidate],raw:String)->[Candidate] {
        let complete=words.filter{$0.completes(raw)}
        guard !complete.isEmpty else{return words}
        let partial=words.filter{!$0.completes(raw)}
        var seen=Set<String>(),result:[Candidate]=[]
        for c in Array(complete.prefix(4))+Array(partial.prefix(4))+words where seen.insert(c.stableID).inserted {result.append(c)}
        return result
    }
    private static func literal(_ raw:String)->Candidate {
        Candidate(text:raw,consumed:FuzzyPinyin.normalize(raw).count,path:CandidatePath(kind:.literal,frequency:0,editCost:0,
            consumedEnd:raw.unicodeScalars.count,segments:[raw.unicodeScalars.count]))
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
