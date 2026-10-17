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
    private struct Path {
        var text: String; var reading: String; var score: Double; var tokens: Int
        var abbreviated: Int = 0; var completed: Bool = false
        var usesInitials = false; var edits = 0
        var initialRun = 0; var repairedTrailingInitial = false
    }
    private struct Token {
        let text: String; let reading: String; let score: Double; let abbreviated: Bool; let completed: Bool
        var edits = 0
        var repairedTrailingInitial = false; var leadingInitialPenalty = 0.0
    }
    private struct Match { let tokens: [Token]; let canExtend: Bool }
    private var matches: [String: Match] = [:]
    private var matchOrder: [String] = []
    private var nextEviction = 0
    private static let cacheLimit = 2_048
    private static let conversational = ["hd": "好的", "nh": "你好", "wm": "我们", "xx": "谢谢", "zj": "再见"]
    private var previousSentence = ""
    private var previousPaths: [[Path]] = []
    private let correctionIndex: PinyinCorrectionIndex?
    private var correctedMatches: [String: [Token]] = [:]
    private var correctedOrder: [String] = []
    private var nextCorrectedEviction = 0
    private var initialScores: [String: Double] = [:]
    private static let initials = Set("bpmfdtnlgkhjqxrzcsyw")
    public let chinese: Lexicon
    public let english: Lexicon
    public init(chinese: Lexicon, english: Lexicon) {
        self.chinese = chinese; self.english = english
        correctionIndex = try? PinyinCorrectionIndex.bundled(lexiconCount: chinese.count)
    }
    public static func bundled() throws -> InputEngine {
        let engine = try InputEngine(chinese: .bundled("pinyin"), english: .bundled("english"))
        guard engine.correctionIndex != nil else { throw LexiconError.invalidFormat }
        return engine
    }

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
            choices += sentences(input, cancelled: cancelled)
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

    private func sentences(_ input: String, cancelled: () -> Bool) -> [Candidate] {
        let primary = decode(input, incremental: true, cancelled: cancelled)
        if cancelled() { return [] }
        let hasVowel = input.contains { "aeiouv".contains($0) }
        let spelling = hasVowel ? PinyinSpelling.reachablePrefix(input) : input.count
        var consonants = 0, longestRun = 0
        for letter in input {
            consonants = Self.initials.contains(letter) ? consonants + 1 : 0
            longestRun = max(longestRun, consonants)
        }
        let mixed = spelling < input.count && longestRun <= 4
        var ranked = primary.filter { $0.abbreviated == 0 || !hasVowel || spelling == input.count }
        // A wrong adjacent key may still form legal pinyin (ke instead of le).
        // Compare spelling and word-sequence likelihood jointly, while retaining the literal reading.
        let intentionalInitials = primary.first.map { $0.usesInitials && $0.abbreviated == 0 } ?? false
        if hasVowel, (4...96).contains(input.count), !intentionalInitials {
            var alternatives = decodeCorrections(input, mixed: mixed, cancelled: cancelled)
            // Valid spelling requires a clear score gain before correction can outrank it.
            if spelling == input.count { for index in alternatives.indices { alternatives[index].score -= 1 } }
            ranked += alternatives
        }
        if cancelled() { return [] }
        var seen = Set<String>()
        var best = Array(ranked.sorted { $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score }
            .filter { seen.insert($0.text).inserted }.prefix(8))
        // Preserve literal initialisms (including place names) alongside a likely repair.
        let literals = mixed ? Array(primary.prefix(2)) : (spelling == input.count ? Array(primary.prefix(1)) : [])
        let additional = literals.filter { literal in !best.contains(where: { $0.text == literal.text }) }
        if !additional.isEmpty { best = Array(best.prefix(8 - additional.count)) + additional }
        return best.map {
                Candidate(text: $0.text, reading: $0.reading, consumed: input.count,
                          score: 44 + $0.score / Double(max(1, input.count)))
            }
    }
    private func decode(_ input: String, incremental: Bool, allowInitials: Bool = true, cancelled: () -> Bool) -> [Path] {
        let chars = Array(input), count = chars.count
        var paths = [[Path]](repeating: [], count: count + 1)
        paths[0] = [Path(text: "", reading: "", score: 0, tokens: 0)]
        // A cancelled query can still leave a fully settled prefix for the next query.
        let common = incremental ? min(zip(input, previousSentence).prefix { $0.0 == $0.1 }.count, max(0, previousPaths.count - 1)) : 0
        let restart = max(0, common - 24)
        if common > 0 { for index in 0...common { paths[index] = previousPaths[index] } }
        func checkpoint(_ settled: Int) {
            if incremental { previousSentence = input; previousPaths = paths.prefix(settled + 1).map { $0.filter { !$0.completed } } }
        }
        func insert(_ path: Path, at end: Int) {
            if let index = paths[end].firstIndex(where: { $0.text == path.text }) {
                guard path.score > paths[end][index].score else { return }
                paths[end].remove(at: index)
            }
            let index = paths[end].firstIndex { $0.score < path.score || ($0.score == path.score && $0.text > path.text) } ?? paths[end].count
            if index < 4 { paths[end].insert(path, at: index); if paths[end].count > 4 { paths[end].removeLast() } }
        }
        for start in restart..<count {
            if cancelled() { checkpoint(start); return [] }
            let bases = paths[start].filter { !$0.completed }
            guard !bases.isEmpty else { continue }
            for end in (start + 1)...min(count, start + 24) {
                if cancelled() { checkpoint(start); return [] }
                let key = String(chars[start..<end]), found = match(key)
                var tokens = found.tokens.filter { allowInitials || !$0.abbreviated }
                if end == count, allowInitials {
                    for entry in chinese.lookup("p:" + key, limit: 8) where entry.key != key && entry.key.count - key.count <= 4 {
                        let final = entry.reading.split(separator: " ").last?.count ?? 0
                        // All preceding syllables must be fully typed; complete only the last syllable.
                        if key.count > entry.key.count - final {
                            tokens.append(token(entry, for: key, completion: true))
                        }
                    }
                }
                for token in tokens {
                    for base in bases {
                        insert(Path(text: base.text + token.text,
                                    reading: base.reading + (base.reading.isEmpty ? "" : " ") + token.reading,
                                    score: base.score + token.score, tokens: base.tokens + 1,
                                    abbreviated: base.abbreviated + (token.abbreviated && Self.conversational[key] != token.text ? token.text.count : 0),
                                    completed: token.completed, usesInitials: base.usesInitials || token.abbreviated), at: end)
                    }
                }
                // No full-pinyin or initial prefix exists beyond this point.
                if !found.canExtend { break }
            }
        }
        checkpoint(count)
        return paths[count]
    }
    private func correctionTokens(_ key: String, cancelled: () -> Bool) -> [Token] {
        if let cached = correctedMatches[key] { return cached }
        guard let correctionIndex else { return [] }
        let entries = correctionIndex.matches(key, lexicon: chinese, cancelled: cancelled)
        if cancelled() { return [] }
        var seen = Set<String>()
        var ranked: [Token] = []
        for (entry, penalty) in entries {
            let exact = token(entry, for: entry.key)
            let letters = Array(key)
            let trailing = letters.last.map { Self.initials.contains($0) && $0 != entry.key.last && $0 != letters.dropLast().last } ?? false
            let leading = String(key.dropFirst()) == entry.key && letters.first != letters.dropFirst().first && letters.first.map(Self.initials.contains) == true
            ranked.append(Token(text: exact.text, reading: exact.reading, score: exact.score - penalty,
                                abbreviated: false, completed: false, edits: 1,
                                repairedTrailingInitial: trailing, leadingInitialPenalty: leading ? 1 : 0))
        }
        ranked.sort { left, right in left.score == right.score ? left.text < right.text : left.score > right.score }
        var result: [Token] = []
        for candidate in ranked where seen.insert(candidate.text).inserted {
            result.append(candidate); if result.count == 8 { break }
        }
        cacheCorrections(result, for: key); return result
    }
    private func cacheCorrections(_ result: [Token], for key: String) {
        if correctedOrder.count < 1_024 { correctedOrder.append(key) }
        else {
            correctedMatches.removeValue(forKey: correctedOrder[nextCorrectedEviction]); correctedOrder[nextCorrectedEviction] = key
            nextCorrectedEviction = (nextCorrectedEviction + 1) % 1_024
        }
        correctedMatches[key] = result
    }
    /// Interpolate word and character likelihoods when vowels are absent. This avoids
    /// treating every initial as an unrelated word or allowing rare names to dominate.
    private func initialScore(_ entry: LexiconEntry) -> Double {
        let cacheKey = entry.key + ":" + entry.text
        if let score = initialScores[cacheKey] { return score }
        let letters = Array(entry.text), syllables = entry.reading.split(separator: " ")
        guard letters.count == syllables.count else { return -100 }
        var characters = 0.0
        for (letter, syllable) in zip(letters, syllables) {
            var frequency: UInt32 = 1
            for word in chinese.lookup("e:" + String(syllable), limit: 24) where word.text == String(letter) {
                frequency = max(frequency, word.frequency)
            }
            characters += log((Double(frequency) + 1) / 10_000_000) - 1
        }
        let score = token(entry, for: entry.key).score * 0.35 + characters * 0.65 - 1
        if initialScores.count >= 2_048 { initialScores.removeAll(keepingCapacity: true) }
        initialScores[cacheKey] = score; return score
    }
    private func initialTokens(_ key: String, cancelled: () -> Bool) -> [Token] {
        guard (1...6).contains(key.count), key.allSatisfy(Self.initials.contains) else { return [] }
        let cacheKey = "a:" + key
        if let cached = correctedMatches[cacheKey] { return cached }
        var ranked: [Token] = []
        func append(_ spelling: String, penalty: Double, edits: Int) {
            let entries = chinese.lookup((spelling.count == 1 ? "p:" : "a:") + spelling, limit: spelling.count == 1 ? 24 : 12)
            for entry in entries where entry.text.count == spelling.count && abbreviation(entry.reading) == spelling {
                ranked.append(Token(text: entry.text, reading: entry.reading, score: initialScore(entry) - penalty,
                                    abbreviated: true, completed: false, edits: edits))
            }
        }
        append(key, penalty: 0, edits: 0)
        if key.count > 1 {
            var letters = Array(key)
            for index in letters.indices {
                if cancelled() { return [] }
                let original = letters[index]
                for letter in Self.initials.sorted() where letter != original {
                    letters[index] = letter
                    let changed = String(letters)
                    if let penalty = PinyinSpelling.editPenalty(key, changed), penalty <= 2.4 {
                        append(changed, penalty: penalty, edits: 1)
                    }
                }
                letters[index] = original
            }
        }
        ranked.sort { $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score }
        var seen = Set<String>(), counts = [0, 0], result: [Token] = []
        for value in ranked where counts[value.edits] < 6 && seen.insert(value.text).inserted {
            result.append(value); counts[value.edits] += 1
        }
        cacheCorrections(result, for: cacheKey); return result
    }
    /// Search word boundaries and typo alternatives together; never materialize whole-sentence variants.
    private func decodeCorrections(_ input: String, mixed: Bool, cancelled: () -> Bool) -> [Path] {
        let chars = Array(input), count = chars.count, budget = count >= 12 ? 2 : 1
        var paths = [[Path]](repeating: [], count: count + 1)
        paths[0] = [Path(text: "", reading: "", score: 0, tokens: 0)]
        func insert(_ path: Path, at end: Int) {
            guard path.initialRun <= 4 else { return }
            var bucket = paths[end].filter { $0.edits == path.edits && $0.initialRun == path.initialRun }
            if let index = bucket.firstIndex(where: { $0.text == path.text }) {
                guard path.score > bucket[index].score else { return }; bucket.remove(at: index)
            }
            let index = bucket.firstIndex { $0.score < path.score || ($0.score == path.score && $0.text > path.text) } ?? bucket.count
            guard index < 4 else { return }
            bucket.insert(path, at: index); if bucket.count > 4 { bucket.removeLast() }
            paths[end] = paths[end].filter { $0.edits != path.edits || $0.initialRun != path.initialRun } + bucket
        }
        for start in 0..<count {
            if cancelled() { return [] }
            let bases = paths[start].filter { !$0.completed }
            guard !bases.isEmpty else { continue }
            let canEdit = bases.contains { $0.edits < budget }
            var canExtend = true
            for end in (start + 1)...min(count, start + 24) {
                if cancelled() { return [] }
                let key = String(chars[start..<end])
                var tokens: [Token] = []
                if canExtend {
                    let found = match(key); canExtend = found.canExtend
                    tokens = found.tokens.filter { !$0.abbreviated }
                    if end == count {
                        for entry in chinese.lookup("p:" + key, limit: 8) where entry.key != key && entry.key.count - key.count <= 4 {
                            let final = entry.reading.split(separator: " ").last?.count ?? 0
                            if key.count > entry.key.count - final { tokens.append(token(entry, for: key, completion: true)) }
                        }
                    }
                }
                if canEdit, end - start <= 13 {
                    let initialsOnly = mixed && key.count > 1 && key.allSatisfy(Self.initials.contains)
                    for value in correctionTokens(key, cancelled: cancelled) where !initialsOnly || value.text.count > 1 { tokens.append(value) }
                }
                if mixed { tokens += initialTokens(key, cancelled: cancelled) }
                for token in tokens {
                    for base in bases where base.edits + token.edits <= budget {
                        // A repair must not quietly swallow the next syllable's initial.
                        let boundaryPenalty = token.abbreviated && base.repairedTrailingInitial ? 3.0 : 0
                        let leadingPenalty = mixed ? token.leadingInitialPenalty : 0
                        insert(Path(text: base.text + token.text,
                                    reading: base.reading + (base.reading.isEmpty ? "" : " ") + token.reading,
                                    score: base.score + token.score - boundaryPenalty - leadingPenalty, tokens: base.tokens + 1,
                                    abbreviated: base.abbreviated + (token.abbreviated ? token.text.count : 0),
                                    completed: token.completed, usesInitials: base.usesInitials || token.abbreviated,
                                    edits: base.edits + token.edits,
                                    initialRun: token.abbreviated ? base.initialRun + token.text.count : 0,
                                    repairedTrailingInitial: mixed && token.repairedTrailingInitial), at: end)
                    }
                }
                if !canExtend && (!canEdit || end - start >= 13) { break }
            }
        }
        return paths[count].filter { $0.edits > 0 || (mixed && $0.abbreviated > 0) }
    }
    private func abbreviation(_ reading: String) -> String { reading.split(separator: " ").compactMap(\.first).map(String.init).joined() }
    private func token(_ entry: LexiconEntry, for key: String, completion: Bool = false) -> Token {
        let abbreviated = !completion && entry.key != key
        var score: Double = log((Double(entry.frequency) + 1) / 10_000_000) - 2.5
        score += abbreviated ? 0 : 1.5
        score += Self.conversational[key] == entry.text ? 5 : 0
        score += Double(max(0, entry.text.count - 1)) * 1.5
        score -= abbreviated ? Double(entry.text.count) * 3.5 : 0
        score -= completion ? 3 : 0
        return Token(text: entry.text, reading: entry.reading, score: score, abbreviated: abbreviated, completed: completion)
    }
    private func match(_ key: String) -> Match {
        if let cached = matches[key] { return cached }
        let initials = key.count <= 12 ? chinese.lookup("a:" + key, limit: 12) : []
        let entries = chinese.lookup("e:" + key, limit: 3) + initials.filter { abbreviation($0.reading) == key }
        var seen = Set<String>()
        var tokens: [Token] = []
        for entry in entries where seen.insert(entry.text).inserted { tokens.append(token(entry, for: key)) }
        tokens.sort { (left: Token, right: Token) -> Bool in
            if left.score == right.score { return left.text < right.text }
            return left.score > right.score
        }
        let result = Match(tokens: Array(tokens.prefix(4)), canExtend: !initials.isEmpty || chinese.contains("p:" + key))
        if matchOrder.count < Self.cacheLimit { matchOrder.append(key) }
        else {
            matches.removeValue(forKey: matchOrder[nextEviction]); matchOrder[nextEviction] = key
            nextEviction = (nextEviction + 1) % Self.cacheLimit
        }
        matches[key] = result; return result
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
