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
}
