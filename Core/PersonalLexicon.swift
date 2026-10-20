import Foundation

/// Explicit choices are keyed by the spelling the user actually typed, including
/// abbreviations and typos. They never change the ranking of unrelated spellings.
public struct PersonalLexicon: Codable {
    public struct Entry: Codable {
        let code: String
        let text: String
        let reading: String
        let consumed: Int
        var uses: Int
        var selectedAt: Date
    }
    private(set) var entries: [Entry] = []
    public init() {}
    private static func key(_ raw: String) -> String {
        raw.lowercased().filter { $0.isASCII && ($0.isLetter || $0 == "'") }
    }
    public mutating func record(_ candidate: Candidate, for raw: String, now: Date = Date()) {
        let code = Self.key(raw)
        guard !code.isEmpty, code.count <= Composition.maximumLength, candidate.consumed > 0,
              candidate.consumed <= FuzzyPinyin.normalize(code).count, !candidate.text.isEmpty else { return }
        let uses = entries.first { $0.code == code && $0.text == candidate.text }?.uses ?? 0
        entries.removeAll { $0.code == code && $0.text == candidate.text }
        entries.insert(Entry(code: code, text: candidate.text, reading: candidate.reading,
            consumed: candidate.consumed, uses: min(10_000, uses + 1), selectedAt: now), at: 0)
        entries = Array(entries.prefix(512))
    }
    public func candidates(for raw: String) -> [Candidate] {
        let code = Self.key(raw)
        return entries.filter { $0.code == code }.prefix(4).map {
            Candidate(text: $0.text, reading: $0.reading, consumed: $0.consumed, score: 200)
        }
    }
    /// A just-committed phrase is strong context for its next occurrence. Reuse
    /// it only for long spellings with at most two neighbouring-key mistakes;
    /// this is separate from exact learning and never rewrites the raw input.
    public func recentCorrections(for raw: String, now: Date = Date()) -> [Candidate] {
        let code = Self.key(raw), typed = Array(code)
        guard code.count >= 8, !code.contains("'") else { return [] }
        let rows: [[Character]] = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { Array($0) }
        func neighbours(_ a: Character, _ b: Character) -> Bool {
            rows.contains { row in
                guard let x = row.firstIndex(of: a), let y = row.firstIndex(of: b) else { return false }
                return abs(x - y) == 1
            }
        }
        return entries.prefix(12).compactMap { entry in
            let age = now.timeIntervalSince(entry.selectedAt)
            guard age >= 0, age <= 120, entry.code.count == code.count,
                  entry.consumed == code.count, !entry.reading.isEmpty,
                  entry.code.prefix(4) == code.prefix(4),
                  entry.text.allSatisfy({ !$0.isASCII }) else { return nil }
            var changes = 0
            for (old, new) in zip(entry.code, typed) where old != new {
                guard neighbours(old, new) else { return nil }
                changes += 1
                if changes > 2 { return nil }
            }
            guard changes > 0 else { return nil }
            return Candidate(text: entry.text, reading: entry.reading, consumed: code.count, score: 150)
        }
    }
}
