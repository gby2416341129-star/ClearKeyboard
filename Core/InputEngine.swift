import Foundation

public struct Candidate: Equatable {
    public let text: String
    public let reading: String
    public let consumed: Int
    public let score: Double
    public init(text: String, reading: String = "", consumed: Int, score: Double = 0) {
        self.text = text; self.reading = reading; self.consumed = consumed; self.score = score
    }
}

/// Call from a serial user-initiated queue. Immutable dictionaries allow a bounded fast lookup at commit time.
public final class InputEngine {
    private struct Path { var text: String; var reading: String; var score: Double; var tokens: Int }
    private var previousSentence = ""
    private var previousPaths: [Path?] = []
    public let chinese: Lexicon
    public let english: Lexicon
    public init(chinese: Lexicon, english: Lexicon) { self.chinese = chinese; self.english = english }
    public static func bundled() throws -> InputEngine { try InputEngine(chinese: .bundled("pinyin"), english: .bundled("english")) }

    public func candidates(_ raw: String, fuzzy: Set<String> = [], learned: [String: Int] = [:], compose: Bool = true, cancelled: () -> Bool = { false }) -> [Candidate] {
        let input = FuzzyPinyin.normalize(raw)
        guard !input.isEmpty, input.count <= Composition.maximumLength else { return [] }
        var choices: [Candidate] = []
        let explicit = raw.contains("'") ? raw.lowercased().split(separator: "'").map(String.init) : []
        func allowed(_ entry: LexiconEntry) -> Bool {
            guard explicit.count > 1 else { return true }
            let expected = explicit.joined(separator: " ")
            return entry.reading.hasPrefix(expected) || expected.hasPrefix(entry.reading + " ")
        }
        func append(_ entries: [LexiconEntry], consumed: Int, bonus: Double) {
            for entry in entries where allowed(entry) {
                choices.append(Candidate(text: entry.text, reading: entry.reading, consumed: consumed,
                    score: log(Double(entry.frequency) + 1) + bonus + min(5, log(Double(learned[entry.text] ?? 0) + 1) * 1.6)))
            }
        }
        for (i, variant) in FuzzyPinyin.variants(input, enabled: fuzzy).enumerated() {
            if cancelled() { return [] }
            let penalty = i == 0 ? 0.0 : 4.0
            append(chinese.lookup("e:" + variant), consumed: input.count, bonus: 24 - penalty)
            append(chinese.lookup("p:" + variant), consumed: input.count, bonus: 6 - penalty)
            append(chinese.lookup("a:" + variant), consumed: input.count, bonus: 1 - penalty)
        }
        if compose && explicit.count < 2 && !choices.contains(where: { FuzzyPinyin.normalize($0.reading) == input }) {
            if let sentence = sentence(input, cancelled: cancelled) { choices.append(sentence) }
        }
        // Partial candidates let the user commit one word, then continue the remaining spelling.
        if choices.isEmpty {
            for length in stride(from: min(20, input.count), through: 1, by: -1) {
                if cancelled() { return [] }
                let prefix = String(input.prefix(length))
                var found = chinese.lookup("e:" + prefix, limit: 6)
                if found.isEmpty { found = chinese.lookup("a:" + prefix, limit: 6).filter { abbreviation($0.reading) == prefix } }
                if !found.isEmpty { append(found, consumed: length, bonus: Double(length)); if choices.count >= 18 { break } }
            }
        }
        var seen = Set<String>()
        return choices.sorted { $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score }
            .filter { seen.insert($0.text).inserted }.prefix(24).map { $0 }
    }

    private func sentence(_ input: String, cancelled: () -> Bool) -> Candidate? {
        let chars = Array(input), count = chars.count
        var paths = [Path?](repeating: nil, count: count + 1)
        paths[0] = Path(text: "", reading: "", score: 0, tokens: 0)
        // Revisit only the trailing word window when typing extends or deletes the previous spelling.
        let common = zip(input, previousSentence).prefix { $0.0 == $0.1 }.count
        let restart = max(0, common - 24)
        if common > 0, previousPaths.count > common {
            for index in 0...common { paths[index] = previousPaths[index] }
        }
        for start in restart..<count {
            guard let base = paths[start] else { continue }
            if cancelled() { return nil }
            for end in (start + 1)...min(count, start + 24) {
                if cancelled() { return nil }
                let key = String(chars[start..<end])
                var entries = chinese.lookup("e:" + key, limit: 2)
                if key.count <= 12 {
                    entries += chinese.lookup("a:" + key, limit: 12).filter { abbreviation($0.reading) == key }
                }
                guard let entry = entries.max(by: { tokenScore($0, key: key) < tokenScore($1, key: key) }) else { continue }
                let score = base.score + tokenScore(entry, key: key)
                if paths[end] == nil || score > paths[end]!.score {
                    paths[end] = Path(text: base.text + entry.text, reading: base.reading + (base.reading.isEmpty ? "" : " ") + entry.reading, score: score, tokens: base.tokens + 1)
                }
            }
        }
        previousSentence = input; previousPaths = paths
        guard let path = paths[count], path.tokens > 1 else { return nil }
        return Candidate(text: path.text, reading: path.reading, consumed: count, score: 44 + path.score / Double(path.tokens) / 10)
    }
    private func abbreviation(_ reading: String) -> String { reading.split(separator: " ").compactMap(\.first).map(String.init).joined() }
    private func tokenScore(_ entry: LexiconEntry, key: String) -> Double {
        let exact = FuzzyPinyin.normalize(entry.reading) == key
        let common = ["hd": "好的", "nh": "你好", "wm": "我们", "xx": "谢谢", "zj": "再见"]
        return log((Double(entry.frequency) + 1) / 10_000_000) - 2.5 + (exact ? 1.5 : 0) + (common[key] == entry.text ? 5 : 0)
    }

    public func predictions(after context: String) -> [Candidate] {
        var output: [Candidate] = [], seen = Set<String>()
        for length in stride(from: min(3, context.count), through: 1, by: -1) {
            let prefix = String(context.suffix(length))
            for word in chinese.lookup("t:" + prefix, limit: 12) where word.text.count > length {
                let suffix = String(word.text.dropFirst(length))
                if seen.insert(suffix).inserted { output.append(Candidate(text: suffix, consumed: 0)) }
            }
        }
        return Array(output.prefix(12))
    }
    public func englishCandidates(prefix: String) -> [Candidate] {
        let normalized = FuzzyPinyin.normalize(prefix)
        guard normalized.count >= 1 else { return [] }
        return english.lookup("p:" + normalized, limit: 12).filter { $0.text.lowercased() != prefix.lowercased() }
            .map { Candidate(text: $0.text, consumed: prefix.count) }
    }
    public func englishPredictions(after context: String) -> [Candidate] {
        let word = context.lowercased().split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
        let pairs = ["thank": ["you", "you so much"], "how": ["are", "do", "is"], "good": ["morning", "night", "idea"], "see": ["you", "you soon"], "i": ["am", "will", "think"], "let": ["me", "us"], "would": ["you", "like"], "have": ["a", "you"], "you": ["are", "can", "have"], "looking": ["forward", "good"]]
        return (pairs[word] ?? []).map { Candidate(text: $0, consumed: 0) }
    }
}
