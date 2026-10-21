import Foundation

@main struct EditTransactionChecks {
    struct Random {
        var state: UInt64
        mutating func value(_ count: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(count))
        }
    }
    enum Failure: Error { case checks(Int) }
    static func main() throws {
        var checks = 0, failures: [String] = [], commits = 0, acknowledgements = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1
            if !value && failures.count < 16 { failures.append(name) }
        }
        let letters = Array("abcdefghijklmnopqrstuvwxyz"), words = ["甲", "乙丙", "🙂", "𰻞"]
        for seed in 1...32 {
            var random = Random(state: UInt64(seed)), time = 1.0
            var committed = "前文🙂", draft = "", history: [HostTextSnapshot] = []
            let after = "｜后文𰻞", identity = "field-\(seed)"
            var state = HostTextState(HostTextSnapshot(before: committed, after: after, document: identity))
            for step in 0..<200 {
                time += 0.005
                switch random.value(8) {
                case 0, 1, 2:
                    draft.append(letters[random.value(letters.count)])
                    state.setMarked(draft, now: time); history.append(state.snapshot)
                case 3:
                    if !draft.isEmpty {
                        draft.removeLast(); state.setMarked(draft, now: time)
                        if draft.isEmpty { history = [] } else { history.append(state.snapshot) }
                    } else if !committed.isEmpty { state.deleteBackward(now: time); committed.removeLast() }
                case 4:
                    guard !draft.isEmpty else { continue }
                    let consumed = 1 + random.value(draft.count), word = words[random.value(words.count)]
                    let remaining = String(draft.dropFirst(consumed))
                    // The chosen word replaces the entire active draft once;
                    // only the unconsumed letters become the next draft.
                    state.insert(word, now: time); committed += word; draft = remaining
                    history = []; commits += 1
                    if !draft.isEmpty { state.setMarked(draft, now: time); history.append(state.snapshot) }
                case 5:
                    // Enter confirms raw spelling, while cancellation removes
                    // that spelling and preserves all previously chosen words.
                    if random.value(2) == 0 { state.unmark(); committed += draft }
                    else { state.setMarked("", now: time); state.unmark() }
                    draft = ""; history = []
                case 6:
                    guard !draft.isEmpty, !history.isEmpty else { continue }
                    let before = state.snapshot
                    check(state.reconcile(before, now: time) == .ownEdit, "latest acknowledgement seed=\(seed) step=\(step)")
                    time += 2
                    let older = history[random.value(history.count)]
                    check(state.reconcile(older, now: time) == .ownEdit, "delayed acknowledgement seed=\(seed) step=\(step)")
                    check(state.snapshot == before, "acknowledgement rewound text seed=\(seed) step=\(step)")
                    acknowledgements += 1
                default:
                    // Real field/caret changes have different context, and
                    // must still discard ownership of the former draft.
                    committed = "新位置\(step)🙂"; draft = ""; history = []
                    let actual = HostTextSnapshot(before: committed, after: after, document: identity)
                    check(state.reconcile(actual, now: time) == .externalEdit, "external context seed=\(seed) step=\(step)")
                }
                check(state.snapshot.before == committed + draft, "lost or duplicated text seed=\(seed) step=\(step)")
                check(state.snapshot.after == after && state.snapshot.selected.isEmpty, "untouched context changed seed=\(seed) step=\(step)")
                check(state.hasMarkedText == !draft.isEmpty, "marked ownership seed=\(seed) step=\(step)")
            }
        }
        let result: [String: Any] = ["status": failures.isEmpty ? "passed" : "failed", "failed": failures.count,
            "checks": checks, "seeds": 32, "operations": 6400, "partialCommits": commits,
            "delayedAcknowledgements": acknowledgements, "failures": failures,
            "scope": "deterministic editing invariants and Unicode context; physical host IPC is tested separately"]
        var output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]); output.append(10)
        FileHandle.standardOutput.write(output)
        if !failures.isEmpty { throw Failure.checks(failures.count) }
    }
}
