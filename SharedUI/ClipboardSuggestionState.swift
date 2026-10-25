import Foundation
import CryptoKit

/// Store only digests and event IDs, never copied text. A history refresh may
/// assign a new UUID to the same payload; that is not a new system copy event.
@MainActor final class ClipboardSuggestionState {
    private let defaults: UserDefaults
    private let key = "clear.clipboard.consumedSuggestions.v1"
    private struct Entry: Codable { let id: UUID; let digest: String; let revision: Int }
    private var entries: [Entry]
    init(defaults: UserDefaults) {
        self.defaults = defaults
        entries = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }
    private func digest(_ clip: Clip) -> String {
        let content = (clip.attachment?.filename ?? "text") + "\0" + clip.text
        return SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func isConsumed(_ clip: Clip, revision: Int) -> Bool {
        if defaults.object(forKey: key + ".typingRevision") != nil,
           defaults.integer(forKey: key + ".typingRevision") == revision,
           let date = defaults.object(forKey: key + ".typingDate") as? Date,
           Date().timeIntervalSince(date) < 86_400 { return true }
        if entries.contains(where: { $0.id == clip.id }) { return true }
        let hash = digest(clip)
        return entries.contains { $0.revision == revision && $0.digest == hash }
    }
    func consumeInputRevision(_ revision: Int) {
        // Also cover a delayed capture arriving just after the first key. This
        // uses pasteboard metadata and does not read its payload on key down.
        guard defaults.object(forKey: key + ".typingRevision") == nil || defaults.integer(forKey: key + ".typingRevision") != revision else { return }
        defaults.set(revision, forKey: key + ".typingRevision")
        defaults.set(Date(), forKey: key + ".typingDate")
    }
    func consume(_ clip: Clip, revision: Int) {
        guard !entries.contains(where: { $0.id == clip.id }) else { return }
        entries.append(Entry(id: clip.id, digest: digest(clip), revision: revision))
        entries = Array(entries.suffix(200))
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }
}
