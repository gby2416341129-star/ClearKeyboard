import Foundation

@main struct CompositionOwnershipChecks {
    enum Failure: Error { case checks(Int) }
    static func main() throws {
        var failures: [String] = [], checks = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1
            if !value { failures.append(name) }
        }
        func frame(_ text: String, after: String = "后文", selected: String = "", document: String = "field") -> HostTextSnapshot {
            HostTextSnapshot(before: text, after: after, selected: selected, document: document)
        }
        // A newer acknowledgement must not revoke ownership of an older one
        // while the same, still unconfirmed spelling is being edited.
        for raw in ["zaigansha", "nichilema", "busuanchadla", String(repeating: "hd", count: 100)] {
            var state = HostTextState(frame("前文")), partial = ""
            var frames: [HostTextSnapshot] = []
            for character in raw {
                partial.append(character); state.setMarked(partial, now: Double(partial.count) * 0.05)
                frames.append(frame("前文" + partial))
            }
            check(state.reconcile(state.snapshot, now: 20) == .ownEdit, "latest ack: \(raw.count)")
            for actual in frames.reversed() {
                check(state.reconcile(actual, now: 30) == .ownEdit, "delayed ack: \(raw.count)/\(actual.before.count)")
                check(state.snapshot.before == "前文" + raw && state.hasMarkedText, "draft preserved: \(raw.count)")
            }
            check(state.accepts(state.snapshot, actual: frames[0], now: 40), "choice accepts owned delayed context: \(raw.count)")
            check(state.reconcile(frame("前文", after: "后文"), now: 50) == .ownEdit, "omitted marked range: \(raw.count)")
            check(state.snapshot.before == "前文" + raw, "omitted context cannot commit pinyin: \(raw.count)")
        }
        var edited = HostTextState(frame("前文"))
        for (time, raw) in [(1.0, "z"), (1.1, "za"), (1.2, "zai"), (1.3, "za")] { edited.setMarked(raw, now: time) }
        check(edited.reconcile(edited.snapshot, now: 2) == .ownEdit, "edited draft latest ack")
        check(edited.reconcile(frame("前文zai"), now: 20) == .ownEdit, "a backspaced spelling may still be acknowledged")
        check(edited.snapshot.before == "前文za", "backspace is not undone by an older ack")
        // Commit ends this ownership. Old pinyin must not be treated as another
        // live draft after a complete or partial Chinese candidate is chosen.
        for partialCommit in [false, true] {
            var state = HostTextState(frame("前文"))
            state.setMarked("zaigansha", now: 1)
            state.setMarked(partialCommit ? "在" : "在干啥", now: 20); state.unmark()
            if partialCommit { state.setMarked("gansha", now: 20.1) }
            check(state.reconcile(frame("前文zaigansha"), now: 40) == .externalEdit, "committed session ends: \(partialCommit)")
        }
        // Moving the caret, selecting text, changing fields and unrelated text
        // remain external edits even when a marked session has a long history.
        for external in [frame("前文z", after: "aigansha后文"),
                         frame("前文", selected: "zaigansha"),
                         frame("前文zaigansha", document: "other-field"),
                         frame("另一段内容"), frame("前文z", after: "别的后文")] {
            var state = HostTextState(frame("前文"))
            state.setMarked("z", now: 1); state.setMarked("zaigansha", now: 1.1)
            check(!state.accepts(state.snapshot, actual: external, now: 20), "foreign choice rejected")
            check(state.reconcile(external, now: 20) == .externalEdit, "external edit detected")
            check(!state.hasMarkedText && state.snapshot == external, "external edit adopted")
        }
        var unavailable = HostTextState(frame("前文")); unavailable.setMarked("z", now: 1)
        var missing = unavailable.snapshot; missing.available = false
        check(unavailable.reconcile(missing, now: 30) == .unavailable && unavailable.hasMarkedText, "temporary disconnect preserves ownership")
        let result: [String: Any] = ["checks": checks, "failed": failures.count,
            "failures": Array(failures.prefix(12)), "status": failures.isEmpty ? "passed" : "failed",
            "scope": "deterministic Swift host-composition state; excludes physical iPhone IPC"]
        var output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]); output.append(10)
        FileHandle.standardOutput.write(output)
        if !failures.isEmpty { throw Failure.checks(failures.count) }
    }
}
