import Foundation

@main struct CandidateContextChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func main() {
        require(CandidateLanguageContext.preceding(before: "我正在考shi", markedDraft: "shi") == "我正在考", "The marked draft entered language context")
        require(CandidateLanguageContext.preceding(before: "我正在考", markedDraft: "") == "我正在考", "A committed Chinese suffix was dropped")
        require(CandidateLanguageContext.preceding(before: "另一个输入框", markedDraft: "shi").isEmpty, "An unrelated editor snapshot became context")
        require(CandidateLanguageContext.preceding(before: "历史上的shish", markedDraft: "shish") == "历史上的", "Contact-down context stripped the upcoming draft instead of the current draft")
        require(CandidateLanguageContext.tail("English 我正在考") == "我正在考", "Latin text was sent through the Chinese history primer")
        require(CandidateLanguageContext.tail("我正在考\n").isEmpty && CandidateLanguageContext.tail("我正在考🙂").isEmpty, "A clause boundary leaked prior context")
        require(CandidateLanguageContext.tail("我真是气死了，") == "我真是气死了，", "Chinese punctuation lost its boundary meaning")
        let long = String(repeating: "中文", count: 100)
        require(CandidateLanguageContext.tail(long).unicodeScalars.count == 16, "Context exceeded its bounded window")
        let a = CandidateRequestKey(raw: "shi", preceding: "我正在考")
        let b = CandidateRequestKey(raw: "shi", preceding: "写一首")
        var cache: [CandidateRequestKey: String] = [a: "试", b: "诗"]
        require(cache.count == 2 && cache[a] == "试" && cache[b] == "诗", "Same spelling shared a result across contexts")
        cache[CandidateRequestKey(raw: "shi", preceding: "我正在考")] = "试"
        require(cache.count == 2, "Equivalent snapshot keys did not share a cache entry")
        print("PASS: cached-host draft exclusion, Chinese context boundary and separate result identities; no editor IPC or device latency claim")
    }
}
