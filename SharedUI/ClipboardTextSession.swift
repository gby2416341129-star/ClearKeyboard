import UIKit

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
        guard let document, document.validateCandidate(before: before, after: after, identity: identity) else { return false }
        guard text != value else { return true }
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

