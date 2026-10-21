import Foundation

/// A small offline prior derived from the pinned 25M model, for repeated words.
/// Scores cover generic dictionary words, never complete feedback sentences.
final class RepetitionModel {
    private struct Word { let text: String; let reading: String; let score: Double }
    private var groups: [String: [Word]] = [:]
    init(data: Data) throws {
        guard let source = String(data: data, encoding: .utf8), source.hasPrefix("# clear-repeat-v1;") else { throw LexiconError.invalidFormat }
        var seen = Set<String>(), count = 0
        for line in source.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, fields[0].count == 2,
                  let score = Double(fields[2]), score.isFinite, (-100...0).contains(score) else { throw LexiconError.invalidFormat }
            let reading = String(fields[1]), syllables = reading.split(separator: " ")
            guard syllables.count == 2, syllables.allSatisfy({ $0.utf8.allSatisfy { (97...122).contains($0) } }) else { throw LexiconError.invalidFormat }
            let key = String(syllables.compactMap(\.first))
            guard key.utf8.count == 2, key.allSatisfy({ "bpmfdtnlgkhjqxrzcsyw".contains($0) }),
                  seen.insert(String(fields[0]) + ":" + reading).inserted else { throw LexiconError.invalidFormat }
            groups[key, default: []].append(Word(text: String(fields[0]), reading: reading, score: score)); count += 1
            guard count <= 4_000 else { throw LexiconError.invalidFormat }
        }
        guard count > 100 else { throw LexiconError.invalidFormat }
        for key in groups.keys {
            var words = groups[key]!
            words.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.text == $1.text ? $0.reading < $1.reading : $0.text < $1.text
            }
            var unique = Set<String>()
            groups[key] = words.filter { unique.insert($0.text).inserted }
        }
    }
    private func pattern(_ input: String) -> (String, Int)? {
        let bytes = Array(input.utf8)
        // Two repetitions are still a common non-repeating four-syllable word.
        // Require three complete units before giving repeated readings priority.
        guard bytes.count >= 6, bytes.count <= Composition.maximumQueryLength else { return nil }
        for index in 2..<bytes.count where bytes[index] != bytes[index % 2] { return nil }
        let key = String(decoding: bytes.prefix(2), as: UTF8.self)
        guard groups[key] != nil else { return nil }
        return (key, bytes.count / 2)
    }
    func recognizes(_ input: String) -> Bool { pattern(input) != nil }
    func candidates(_ input: String) -> [Candidate] {
        guard let (key, count) = pattern(input), let words = groups[key] else { return [] }
        return words.map { word in
            Candidate(text: String(repeating: word.text, count: count),
                reading: Array(repeating: word.reading, count: count).joined(separator: " "),
                // An unfinished next unit stays in composition after a partial
                // choice; it must never be consumed by the repeated words.
                consumed: count * 2, score: word.score)
        }
    }
}
