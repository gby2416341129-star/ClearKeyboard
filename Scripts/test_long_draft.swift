import Foundation

@main struct LongDraftChecks {
    static func main() throws {
        var failures: [String] = [], checks = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value && failures.count < 16 { failures.append(message) }
        }
        let raw = String(repeating: "jintianxiabanyihouwoqucaishichangmaidiandongxi", count: 160)
        var draft = Composition(), state = HostTextState(HostTextSnapshot(before: "前文🙂", after: "｜后文", document: "long"))
        var prefix = ""
        for (index, letter) in raw.enumerated() {
            prefix.append(letter)
            check(draft.append(String(letter)), "Draft rejected key \(index)")
            check(draft.raw == prefix && draft.normalized == prefix, "Draft dropped key \(index)")
            state.setMarked(prefix, now: Double(index) / 1000)
            check(state.snapshot.before == "前文🙂" + prefix, "Ledger truncated live draft \(index)")
        }
        for count in [1, 3, 32, 255, 256, 257, 513, 1025, 4097, raw.count - 1] {
            let old = HostTextSnapshot(before: "前文🙂" + String(raw.prefix(count)), after: "｜后文", document: "long")
            check(state.reconcile(old, now: 40) == .ownEdit, "Long draft forgot its own earlier prefix \(count)")
            check(state.snapshot.before == "前文🙂" + raw, "Old prefix replaced live text \(count)")
        }
        state.insert("今天下班以后", now: 41)
        check(state.snapshot.before == "前文🙂今天下班以后", "Long marked replacement retained or lost letters")
        check(state.snapshot.after == "｜后文", "Long marked replacement changed following text")
        let report: [String: Any] = ["status": failures.isEmpty ? "passed" : "failed", "checks": checks,
            "failed": failures.count, "failures": failures, "typedLetters": raw.count,
            "scope": "Swift composition and host ledger; no phone rendering or host IPC measurement"]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
        if !failures.isEmpty { exit(1) }
    }
}
