import Foundation

@main struct FrameDeliveryChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func main() throws {
        var value = LatestValue<String>()
        let raw = String(repeating: "nichifanlema", count: 16)
        var ledger = HostTextState(HostTextSnapshot(before: "前文", document: "same-field"))
        var marked = "", actual = "前文", writes: [String] = []
        func write(_ text: String) {
            if !marked.isEmpty { check(actual.hasSuffix(marked), "The host draft was already lost"); actual.removeLast(marked.count) }
            actual += text; marked = text; writes.append(text)
        }
        // A stalled main loop can receive many releases and worker results
        // before drawing. Only the latest spelling may cross the host boundary.
        var spelling = ""
        for character in raw { spelling.append(character); ledger.setMarked(spelling, now: 1); value.replace(with: spelling) }
        check(writes.isEmpty && value.isPending && ledger.snapshot.before == "前文" + raw, "Enqueue unexpectedly wrote or delayed local state")
        if let next = value.take() { write(next) }
        check(writes == [raw] && !value.isPending, "A burst replayed obsolete spellings")
        // Choosing a prefix is an immediate barrier, followed by a new draft.
        let committed = "你吃饭了吗"
        ledger.setMarked(committed, now: 3); value.replace(with: committed)
        if let next = value.take() { write(next) }; marked = ""; ledger.unmark()
        ledger.setMarked("wo", now: 3.1); value.replace(with: "wo")
        if let next = value.take() { write(next) }
        check(actual == "前文" + committed + "wo" && ledger.snapshot.before == actual, "A frame swallowed a partial commit")
        check(value.take() == nil, "A stale callback rewrote the committed text")
        // A field switch must invalidate the previous frame, even if it has
        // not been displayed yet. Subsequent composition belongs to that field.
        value.replace(with: "old-field-pinyin"); value.discard()
        check(value.take() == nil, "A foreign document received an old frame")
        var bursts: [String: Int] = [:]
        for hz in [30, 60, 120] {
            var slot = LatestValue<Int>(), delivered: [Int] = [], submitted = 0
            // Eight valid newer results before each of 100 display opportunities.
            for _ in 0..<100 {
                for _ in 0..<8 { submitted += 1; slot.replace(with: submitted) }
                if let next = slot.take() { delivered.append(next) }
            }
            check(delivered.count == 100 && delivered.last == submitted && zip(delivered, delivered.dropFirst()).allSatisfy({ $0.0 < $0.1 }), "The display consumer accumulated an old-value backlog")
            bursts[String(hz)] = delivered.count
            var cadence = FrameWriteCadence()
            check(cadence.canWriteImmediately(now: 1, maximumFramesPerSecond: hz), "An idle key gained a display-frame delay")
            cadence.didWrite(now: 1)
            check(!cadence.canWriteImmediately(now: 1 + 0.5 / Double(hz), maximumFramesPerSecond: hz), "A burst can flood the host within one frame")
            check(cadence.canWriteImmediately(now: 1.1, maximumFramesPerSecond: hz), "An ordinary next tap was unnecessarily throttled")
        }
        let result: [String: Any] = ["status": "passed", "burstInputs": raw.count, "burstHostWrites": 1,
            "commitAndFieldBarriers": "passed", "simulatedDisplaySchedules": bursts,
            "scope": "deterministic latest-value and host ledger checks; no measured device frame rate or host IPC latency"]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
