import Foundation

@inline(never) func referenceNormalize(_ input: String) -> String {
    input.lowercased().replacingOccurrences(of: "ü", with: "v").unicodeScalars
        .filter { (97...122).contains($0.value) }.map(String.init).joined()
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main struct InputCoreChecks {
    static func main() throws {
        for value in ["NI'HAO", "LÜe", "u\u{0308}", "İK", "你好wo", "ABC012_!", "a👨‍👩‍👧‍👦b", "ÜI\u{0307}"] {
            expect(FuzzyPinyin.normalize(value) == referenceNormalize(value), "Unicode normalization changed")
        }
        for value in ["ni'hao'ma", "LÜe'niHao", "u\u{0308}'İK", String(repeating: "hd", count: 100)] {
            var composition = Composition()
            for character in value {
                expect(composition.append(String(character)), "Unexpected composition rejection")
                expect(composition.normalized == referenceNormalize(composition.raw), "Incremental append diverged")
            }
            for _ in 0..<3 {
                composition.consume(2)
                expect(composition.normalized == referenceNormalize(composition.raw), "Partial consumption diverged")
            }
            while !composition.raw.isEmpty {
                composition.deleteBackward()
                expect(composition.normalized == referenceNormalize(composition.raw), "Backspace diverged")
            }
            expect(composition == Composition(), "An emptied composition retained hidden state")
        }
        var acrossBoundary = Composition()
        acrossBoundary.append("u"); acrossBoundary.append("\u{0308}")
        expect(acrossBoundary.normalized == referenceNormalize(acrossBoundary.raw), "A combining mark crossed the cached boundary")
        var limit = Composition(); expect(limit.append(String(repeating: "n", count: 256)), "Decoder boundary rejected")
        expect(limit.append("i") && limit.raw.count == 257, "A decoder work limit must not reject user input")
        for value in [String(repeating: "nichifanlema", count: 50), String(repeating: "ni'hao'ma'", count: 60)] {
            let normalized = FuzzyPinyin.normalize(value)
            let prefix = Composition.queryPrefix(value, normalized: normalized)
            expect(value.hasPrefix(prefix) && !prefix.isEmpty, "Long decoding window is not a source prefix")
            expect(FuzzyPinyin.normalize(prefix).count <= Composition.maximumQueryLength, "Long decoding work is unbounded")
            var remainder = Composition(); remainder.append(value); remainder.consume(FuzzyPinyin.normalize(prefix).count)
            expect(prefix + remainder.raw == value, "Taking a bounded query window lost source letters")
        }
        var host = HostTextState(HostTextSnapshot(before: "前文", document: "field"))
        let raw = String(repeating: "nichifanlema", count: 16)
        host.setMarked(raw, now: 1)
        var unavailable = host.snapshot; unavailable.available = false
        expect(host.reconcile(unavailable, now: 10) == .unavailable, "Temporary unavailability cleared the draft")
        expect(host.hasMarkedText && host.snapshot.before == "前文" + raw, "Long spelling was lost")
        var truncated = host.snapshot; truncated.before = String(truncated.before.suffix(50))
        expect(host.reconcile(truncated, now: 11) == .ownEdit, "A bounded host window discarded the composition")
        let delayedDraft = host.snapshot
        host.setMarked("你吃饭了吗", now: 11.1); host.unmark()
        expect(host.reconcile(delayedDraft, now: 11.15) == .ownEdit, "An expired draft acknowledgement swallowed a partial choice")
        host.setMarked("wo", now: 11.2)
        expect(host.snapshot.before == "前文你吃饭了吗wo", "Partial commit swallowed the selected word")
        expect(host.reconcile(HostTextSnapshot(before: "新输入框", document: "other"), now: 12) == .externalEdit,
               "A foreign document was accepted")
        var whole = HostTextState(HostTextSnapshot(before: "前文", document: "whole"))
        whole.setMarked(raw, now: 1)
        let delayedWhole = whole.snapshot
        whole.setMarked("妈妈你吃饭了吗", now: 20); whole.unmark()
        expect(whole.reconcile(delayedWhole, now: 20.1) == .ownEdit, "An expired draft acknowledgement swallowed a whole sentence")
        expect(whole.snapshot.before == "前文妈妈你吃饭了吗", "The whole commit reverted to pinyin")
        expect(whole.reconcile(whole.snapshot, now: 20.2) == .ownEdit, "The confirmed sentence was not acknowledged")
        expect(whole.reconcile(HostTextSnapshot(before: "另一个位置", document: "whole"), now: 20.3) == .externalEdit,
               "Preserving a draft acknowledgement hid an unrelated cursor edit")
        let input = String(String(repeating: "nichifanlema", count: 24).prefix(256))
        var oldChecksum = 0, newChecksum = 0
        var started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<12 {
            var raw = ""
            for character in input { raw.append(character); for _ in 0..<8 { oldChecksum += referenceNormalize(raw).utf8.count } }
        }
        let previousMS = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<12 {
            var state = Composition()
            for character in input { state.append(String(character)); for _ in 0..<8 { newChecksum += state.normalized.utf8.count } }
        }
        let currentMS = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        expect(newChecksum == oldChecksum, "Benchmark produced a different input stream")
        let result: [String: Any] = ["status": "passed", "queries": 12 * 256 * 8,
            "previousNormalizationMS": previousMS, "incrementalCompositionMS": currentMS,
            "speedup": previousMS / max(currentMS, 0.001),
            "scope": "macOS Swift release; normalization/ledger only; excludes iPhone UI and host IPC"]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
