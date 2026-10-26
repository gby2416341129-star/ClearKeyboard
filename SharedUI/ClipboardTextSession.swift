import Foundation

/// Own only this selection's insertion. A host edit or cursor move revokes that
/// ownership before any deletion; unrelated text is never guessed or erased.
@MainActor final class ClipboardTextSession {
    private weak var document: KeyboardDocument?
    private let identity: String
    private var before: String
    private var after: String
    private(set) var value = ""
    init(document: KeyboardDocument) {
        self.document = document; identity = document.documentIdentity
        before = document.contextBefore; after = document.contextAfter
    }
    @discardableResult func apply(_ text: String) -> Bool {
        guard let document, document.documentIdentity == identity else { return false }
        let currentBefore = document.contextBefore, currentAfter = document.contextAfter
        // Remote editors expose bounded text windows. A shorter window still
        // proves the same caret when its suffix matches our last insertion.
        func sameWindow(_ lhs: String, _ rhs: String, preceding: Bool) -> Bool {
            if lhs == rhs { return true }
            guard !lhs.isEmpty, !rhs.isEmpty else { return false }
            return preceding ? lhs.hasSuffix(rhs) || rhs.hasSuffix(lhs) : lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
        }
        guard sameWindow(before, currentBefore, preceding: true), sameWindow(after, currentAfter, preceding: false),
              document.validateClipboardSelection(before: currentBefore, after: currentAfter, identity: identity) else { return false }
        guard text != value else { return true }
        if !value.isEmpty {
            guard document.selectedText.isEmpty, !currentBefore.isEmpty else { return false }
            let count = min(value.count, currentBefore.count)
            guard value.suffix(count) == currentBefore.suffix(count) else { return false }
        }
        let old = Array(value), next = Array(text)
        var prefix = 0, suffix = 0
        while prefix < min(old.count, next.count), old[prefix] == next[prefix] { prefix += 1 }
        while suffix < min(old.count, next.count) - prefix,
              old[old.count - 1 - suffix] == next[next.count - 1 - suffix] { suffix += 1 }
        if suffix > 0 { document.moveCursor(-suffix) }
        for _ in prefix..<(old.count - suffix) { document.deleteBackward() }
        let insertion = String(next[prefix..<(next.count - suffix)])
        if !insertion.isEmpty { document.insert(insertion) }
        if suffix > 0 { document.moveCursor(suffix) }
        value = text; before = document.contextBefore; after = document.contextAfter
        return true
    }
    func finish() {}

}

