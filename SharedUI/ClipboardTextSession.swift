import UIKit

/// Own only this selection's insertion. A host edit or cursor move revokes that
/// ownership before any deletion; unrelated text is never guessed or erased.
@MainActor final class ClipboardTextSession {
    private weak var document: KeyboardDocument?
    private let identity: String
    private var before: String
    private var after: String
    private(set) var value = ""
    private var valid = true
    init(document: KeyboardDocument) {
        self.document = document; identity = document.documentIdentity
        before = document.contextBefore; after = document.contextAfter
    }
    @discardableResult func apply(_ text: String) -> Bool {
        guard valid, let document, document.validateClipboardSelection(before: before, after: after, identity: identity) else { valid = false; return false }
        guard text != value else { return true }
        guard document.replaceClipboardSelection(text, previous: value) else { valid = false; return false }
        value = text; before = document.contextBefore; after = document.contextAfter
        return true
    }
    func finish() { document?.finishClipboardSelection(); valid = false }
}
