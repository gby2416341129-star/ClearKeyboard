import Foundation

/// Local memory of complete numbers deliberately entered with the keyboard.
/// Strings preserve leading zeroes and avoid numeric overflow. A suffix is only
/// offered after two completed occurrences, never automatically inserted.
public struct NumericLexicon: Codable {
    private struct Entry: Codable { let value: String; var uses: Int; var selectedAt: Date }
    private var entries: [Entry] = []
    public init() {}
    static func isDigits(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    public mutating func record(_ value: String, now: Date = Date()) {
        guard (6...32).contains(value.utf8.count), Self.isDigits(value) else { return }
        let uses = entries.first { $0.value == value }?.uses ?? 0
        entries.removeAll { $0.value == value }
        entries.insert(Entry(value: value, uses: min(10_000, uses + 1), selectedAt: now), at: 0)
        entries = Array(entries.prefix(128))
    }
    public func candidates(for prefix: String) -> [Candidate] {
        guard (3...31).contains(prefix.utf8.count), Self.isDigits(prefix) else { return [] }
        return entries.filter { $0.uses >= 2 && $0.value.count > prefix.count && $0.value.hasPrefix(prefix) }
            .sorted { $0.uses == $1.uses ? $0.selectedAt > $1.selectedAt : $0.uses > $1.uses }
            .prefix(4).map { Candidate(text: String($0.value.dropFirst(prefix.count)), reading: $0.value, consumed: 0) }
    }
}

/// Track one contiguous explicit numeric run, not every prefix seen while typing.
/// Editing, a different field or an unverified cursor move invalidates the run.
public struct NumericInputRun {
    private var value = "", anchor = "", after = "", document = ""
    public var isEmpty: Bool { value.isEmpty }
    public init() {}
    public mutating func reset() { value = ""; anchor = ""; after = ""; document = "" }
    public func prefix(before: String, after: String, document: String) -> String? {
        !value.isEmpty && self.document == document && self.after == after && anchor + value == before ? value : nil
    }
    public mutating func append(_ digits: String, before: String, after: String, document: String) {
        guard NumericLexicon.isDigits(digits) else { reset(); return }
        if prefix(before: before, after: after, document: document) == nil {
            reset()
            // Starting in the middle of an existing number would learn only
            // its tail as if it were a complete value.
            guard before.last.map({ !$0.isASCII || !$0.isNumber }) ?? true else { return }
            anchor = before; self.after = after; self.document = document
        }
        guard value.count + digits.count <= 32 else { reset(); return }
        value += digits
    }
    public mutating func delete(before: String, after: String, document: String) {
        guard prefix(before: before, after: after, document: document) != nil else { reset(); return }
        value.removeLast()
        if value.isEmpty { reset() }
    }
    public mutating func complete(before: String, after: String, document: String) -> String? {
        let result = prefix(before: before, after: after, document: document)
        reset(); return result
    }
}
