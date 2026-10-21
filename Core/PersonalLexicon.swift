import Foundation

/// Explicit choices retain their actual source span. Complete, aligned Chinese
/// phrases also expose their initials; partial choices never create such aliases.
public struct PersonalLexicon: Codable {
    public struct Entry: Codable {
        let code: String
        let text: String
        let reading: String
        let consumed: Int
        var uses: Int
        var selectedAt: Date
        var initials: String?
    }
    private(set) var entries: [Entry] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case entries }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = Array(try container.decode([Entry].self, forKey: .entries).prefix(512))
        // Upgrade the old on-device history once at load time. Building aliases
        // during every key would repeatedly scan all stored phrase readings.
        for index in entries.indices where entries[index].initials == nil {
            let entry = entries[index]
            if entry.consumed == FuzzyPinyin.normalize(entry.code).count {
                entries[index].initials = Self.initials(text: entry.text, reading: entry.reading)
            }
        }
    }
    private static func key(_ raw: String) -> String {
        raw.lowercased().filter { $0.isASCII && ($0.isLetter || $0 == "'") }
    }
    public mutating func record(_ candidate: Candidate, for raw: String, now: Date = Date()) {
        let code = Self.key(raw)
        guard !code.isEmpty, code.count <= Composition.maximumQueryLength, candidate.consumed > 0,
              candidate.consumed <= FuzzyPinyin.normalize(code).count, !candidate.text.isEmpty else { return }
        let uses = entries.first { $0.code == code && $0.text == candidate.text }?.uses ?? 0
        entries.removeAll { $0.code == code && $0.text == candidate.text }
        entries.insert(Entry(code: code, text: candidate.text, reading: candidate.reading,
            consumed: candidate.consumed, uses: min(10_000, uses + 1), selectedAt: now,
            initials: candidate.consumed == FuzzyPinyin.normalize(code).count ? Self.initials(text: candidate.text, reading: candidate.reading) : nil), at: 0)
        entries = Array(entries.prefix(512))
    }
    public func candidates(for raw: String) -> [Candidate] {
        guard raw.utf8.count <= Composition.maximumQueryLength else { return [] }
        let code = Self.key(raw)
        guard !code.isEmpty else { return [] }
        var found: [(Entry, Int)] = []
        for entry in entries {
            if entry.code == code { found.append((entry, entry.consumed)) }
            else if entry.initials == code {
                found.append((entry, FuzzyPinyin.normalize(code).count))
            }
        }
        found.sort { $0.0.uses == $1.0.uses ? $0.0.selectedAt > $1.0.selectedAt : $0.0.uses > $1.0.uses }
        var seen = Set<String>()
        return Array(found.filter { seen.insert($0.0.text).inserted }.prefix(4).map { entry, consumed in
            Candidate(text: entry.text, reading: entry.reading, consumed: consumed, score: Double(min(3, entry.uses)))
        })
    }
    private static func initials(text: String, reading: String) -> String? {
        let syllables = reading.split(separator: " ")
        guard (2...32).contains(text.count), syllables.count == text.count,
              text.unicodeScalars.allSatisfy({ (0x3400...0x9fff).contains($0.value) || (0x20000...0x3347f).contains($0.value) }),
              syllables.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isLowercase && $0.isLetter } }) else { return nil }
        return String(syllables.compactMap(\.first))
    }
    /// One confirmation makes a word available, two raise it, and three may
    /// promote it to first. A one-off selection cannot pin an unfamiliar name.
    /// Explicit caller preferences (score 0 or legacy 200) retain their API.
    public static func merging(_ preferred: [Candidate], into words: [Candidate], limit: Int) -> [Candidate] {
        var seen = Set<String>()
        let choices = preferred.filter { seen.insert($0.text).inserted }
        let ranks = Dictionary(words.enumerated().map { ($0.element.text, $0.offset) }, uniquingKeysWith: min)
        var output = words.filter { !seen.contains($0.text) }
        seen.removeAll()
        output = output.filter { seen.insert($0.text).inserted }
        for (offset, candidate) in choices.enumerated() {
            let gradual = (1...3).contains(candidate.score) ? 3 - Int(candidate.score) : 0
            let position = min(ranks[candidate.text] ?? Int.max, gradual + offset, output.count)
            output.insert(candidate, at: position)
        }
        return Array(output.prefix(max(1, limit)))
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

/// A phrase can be confirmed a character at a time. Keep that transaction only
/// while the same document, unmarked anchor and remaining spelling still agree.
/// No host text is polled here; callers provide their existing editor snapshot.
public struct PhraseLearning {
    public struct Choice { public let raw: String; public let candidate: Candidate }
    private struct Chain {
        var raw: String; var text: String; var reading: String; var remaining: String
        let anchor: String; let after: String; let document: String
    }
    private var chain: Chain?
    public init() {}
    public mutating func reset() { chain = nil }
    public mutating func select(_ candidate: Candidate, from composition: Composition,
                                before: String, after: String, document: String) -> Choice? {
        guard !composition.isEmpty, candidate.consumed > 0, candidate.consumed <= composition.normalized.count,
              !candidate.text.isEmpty, candidate.text.allSatisfy({ !$0.isASCII }),
              candidate.reading.split(separator: " ").count == candidate.text.count else { reset(); return nil }
        let anchor = before.hasSuffix(composition.raw) ? String(before.dropLast(composition.raw.count)) : before
        if let old = chain, old.document != document || old.after != after || old.anchor + old.text != anchor ||
            old.remaining.isEmpty || !composition.raw.hasPrefix(old.remaining) { reset() }
        var remaining = composition; remaining.consume(candidate.consumed)
        let source = String(composition.raw.dropLast(remaining.raw.count))
        var next = chain ?? Chain(raw: "", text: "", reading: "", remaining: "", anchor: anchor, after: after, document: document)
        next.raw += source; next.text += candidate.text
        next.reading += (next.reading.isEmpty ? "" : " ") + candidate.reading
        next.remaining = remaining.raw
        guard next.raw.count <= Composition.maximumQueryLength, next.text.count <= 32 else { reset(); return nil }
        if remaining.isEmpty {
            reset()
            return Choice(raw: next.raw, candidate: Candidate(text: next.text, reading: next.reading,
                consumed: FuzzyPinyin.normalize(next.raw).count))
        }
        chain = next; return nil
    }
}
