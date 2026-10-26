import Foundation

// The exact production drag reducer and text session are compiled alongside
// this small host fixture. No UIKit simulator or alternate implementation.
@MainActor protocol KeyboardDocument: AnyObject {
    var contextBefore: String { get }; var contextAfter: String { get }
    var documentIdentity: String { get }; var selectedText: String { get }
    func validateClipboardSelection(before: String, after: String, identity: String) -> Bool
    func moveCursor(_ offset: Int); func deleteBackward(); func insert(_ text: String)
}
@MainActor final class ProbeDocument: KeyboardDocument {
    var text: [Character], caret: Int, window = 80
    var documentIdentity = "field-a", selectedText = ""
    init(before: String, after: String) { text = Array(before + after); caret = before.count }
    var contextBefore: String { String(text[..<caret].suffix(window)) }
    var contextAfter: String { String(text[caret...].prefix(window)) }
    var result: String { String(text) }
    func validateClipboardSelection(before: String, after: String, identity: String) -> Bool {
        before == contextBefore && after == contextAfter && identity == documentIdentity && selectedText.isEmpty
    }
    func moveCursor(_ offset: Int) { caret = max(0, min(text.count, caret + offset)) }
    func deleteBackward() { if caret > 0 { text.remove(at: caret - 1); caret -= 1 } }
    func insert(_ value: String) { text.insert(contentsOf: Array(value), at: caret); caret += value.count }
}
@main struct ClipboardSelectionRepairProbe {
    @MainActor static func main() {
        precondition(!ClipboardSelection.startsSelection(horizontal: 1, vertical: 100, startIsSelected: false))
        precondition(ClipboardSelection.startsSelection(horizontal: 1, vertical: 100, startIsSelected: true))
        precondition(ClipboardSelection.startsSelection(horizontal: 100, vertical: 1, startIsSelected: false))
        var adding = ClipboardSelection.Drag(anchor: 0, selected: [])
        precondition(adding.update(through: 80) == Set(0...80))
        precondition(adding.update(through: 15) == Set(0...15))
        var removing = ClipboardSelection.Drag(anchor: 0, selected: Set(0..<60))
        for rowEnd in [9, 19, 29, 39, 49] { precondition(removing.update(through: rowEnd) == Set((rowEnd + 1)..<60)) }
        precondition(removing.update(through: 59).isEmpty)
        var overlapping = ClipboardSelection.Drag(anchor: 2, selected: [0, 5])
        _ = overlapping.update(through: 8)
        precondition(overlapping.update(through: 3) == [0, 2, 3])
        let base = "原有内容💡", tail = "后面的文字"
        let host = ProbeDocument(before: base, after: tail)
        let live = ClipboardTextSession(document: host)
        let long = String(repeating: "甲乙🙂abc", count: 45)
        precondition(live.apply(long)); precondition(host.result == base + long + tail)
        host.window = 24
        precondition(live.apply(String(long.suffix(80)))); precondition(host.result == base + String(long.suffix(80)) + tail)
        precondition(live.apply("")); precondition(host.result == base + tail)
        precondition(live.apply("第二次重新选词🙂")); precondition(live.apply("")); precondition(host.result == base + tail)
        precondition(live.apply("不应被错误删除的选词"))
        host.moveCursor(-1); let untouched = host.result
        precondition(!live.apply("")); precondition(host.result == untouched)
        host.documentIdentity = "different-field"
        precondition(!live.apply("")); precondition(host.result == untouched)
        print("Clipboard repair probe passed: vertical cancellation, reverse overlap, bounded Unicode context, clear/reselect and ownership guards.")
    }
}
