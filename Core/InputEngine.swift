import Foundation

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
    private static let conversationalReadings = ["hd": ("好的", "hao de"), "nh": ("你好", "ni hao"),
        "wm": ("我们", "wo men"), "xx": ("谢谢", "xie xie"), "zj": ("再见", "zai jian")]
    private static let conversational = conversationalReadings.mapValues { $0.0 }
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
    private var matureDecoder: RimeDecoder?
    private var associations: Lexicon?
    private var repetition: RepetitionModel?
    public var chineseBackend: String { matureDecoder == nil ? "fallback" : "rime-wanxiang" }
    public init(chinese: Lexicon, english: Lexicon) {
        self.chinese = chinese; self.english = english
        correctionIndex = try? PinyinCorrectionIndex.bundled(lexiconCount: chinese.count)
    }
    public static func bundled() throws -> InputEngine {
        let engine = try InputEngine(chinese: .bundled("pinyin"), english: .bundled("english"))
        guard engine.correctionIndex != nil else { throw LexiconError.invalidFormat }
        engine.matureDecoder = try RimeDecoder.bundled()
        engine.associations = try .bundled("associations")
        if let directory = RimeDecoder.resourceDirectory(),
           let data = try? Data(contentsOf: directory.appendingPathComponent("repetition-priors.tsv")) {
            engine.repetition = try RepetitionModel(data: data)
        }
        return engine
    }
    public func hasImmediateComposition(_ raw: String) -> Bool {
        !raw.contains("'") && repetition?.recognizes(FuzzyPinyin.normalize(raw)) == true
    }
    private func repeatedCandidates(_ input: String) -> [Candidate] {
        var values = repetition?.candidates(input) ?? []
        guard !values.isEmpty else { return [] }
        let unit = String(input.prefix(2)), count = input.utf8.count / 2
        // Repeating a short preferred acknowledgement preserves its existing
        // preference (including the user's familiar short-code defaults).
        if let (word, reading) = Self.conversationalReadings[unit] {
            let text = String(repeating: word, count: count)
            values.removeAll { $0.text == text }
            values.insert(Candidate(text: text, reading: Array(repeating: reading, count: count).joined(separator: " "),
                consumed: count * 2), at: 0)
        }
        return Array(values.prefix(8))
    }
    private func repeatedHead(_ repeated: [Candidate], raw: String, length: Int, preferred: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        var values = (preferred.filter { $0.consumed > 0 && $0.consumed <= length } + repeated)
            .filter { seen.insert($0.text).inserted }
        if !seen.contains(raw) {
            values.insert(Candidate(text: raw, reading: raw, consumed: length, score: 80), at: min(8, values.count))
        }
        return values
    }

    /// Bounded, read-only word lookup for the current spelling. This never enters
    /// Rime or its lock; sentence decoding continues on the candidate worker.
    /// A visible word can therefore be selected while that worker is busy.
    public func immediateCandidates(_ raw: String, preferred: [Candidate] = []) -> [Candidate] {
        let input = FuzzyPinyin.normalize(raw)
        guard !input.isEmpty, input.count <= Composition.maximumLength else { return [] }
        var output = preferred.filter { $0.consumed > 0 && $0.consumed <= input.count }
        let repeated = raw.contains("'") ? [] : repeatedCandidates(input)
        if !repeated.isEmpty {
            var seen = Set(output.map(\.text))
            output += repeated.filter { seen.insert($0.text).inserted }
            return Array(output.prefix(8))
        }
        let exact = chinese.lookup("e:" + input, limit: 8)
        let english = input.count >= 3 && associations?.contains("e:" + input) == true
        if english && exact.isEmpty {
            output.append(Candidate(text: raw, reading: raw, consumed: input.count))
        } else {
            output += conversationalCandidates(input, raw: raw)
            // Production short-initial rows are already ranked and bounded.
            // Prefer them to the small compatibility dictionary, which otherwise
            // changes the first word when the native decoder catches up.
            if !raw.contains("'"), input.count <= 4,
               input.allSatisfy({ Self.initials.contains($0) }) {
                output += shortInitialWords(input)
            }
            output += initialCompletions(input)
            let entries = exact + chinese.lookup("a:" + input, limit: 8)
                .filter { abbreviation($0.reading) == input }
            output += entries.sorted {
                let left = Self.conversational[input] == $0.text, right = Self.conversational[input] == $1.text
                if left != right { return left }
                return $0.frequency == $1.frequency ? $0.text < $1.text : $0.frequency > $1.frequency
            }.map { Candidate(text: $0.text, reading: $0.reading, consumed: input.count) }
            // The small compatibility lexicon omits many short initialisms
            // (including djdj). Use the same production dictionary as Rime for
            // those misses, without waiting on the sentence decoder's lock.
            if output.isEmpty, !raw.contains("'") {
                output += (associations?.lookup("i:" + input, limit: 8) ?? [])
                    .map { Candidate(text: $0.text, reading: $0.reading, consumed: input.count) }
            }
        }
        if preferred.isEmpty, let alias = Self.conversational[input], let index = output.firstIndex(where: { $0.text == alias }) {
            output.insert(output.remove(at: index), at: 0)
        }
        var seen = Set<String>()
        return Array(output.filter { seen.insert($0.text).inserted }.prefix(8))
    }

    /// Recognize mixed full syllables and initials before considering an English
    /// suffix. For example wo + gei + ma + m is a Chinese spelling, even though
    /// the last four letters also happen to be an English dictionary entry.
    static func matchesReadingWithInitials(_ input: String, reading: String) -> Bool {
        let letters = Array(input)
        var positions: Set<Int> = [0]
        let syllables = reading.split(separator: " ").map(String.init)
        guard !syllables.isEmpty else { return false }
        for syllable in syllables {
            var forms = [syllable]
            if let first = syllable.first, initials.contains(first) {
                forms.append(String(first))
                if ["zh", "ch", "sh"].contains(String(syllable.prefix(2))) {
                    forms.append(String(syllable.prefix(2)))
                }
            }
            var next = Set<Int>()
            for position in positions {
                for form in forms {
                    let end = position + form.count
                    if end <= letters.count && letters[position..<end].elementsEqual(form) { next.insert(end) }
                }
            }
            positions = next
            if positions.isEmpty { return false }
        }
        return positions.contains(letters.count)
    }

    public func candidates(_ raw: String, fuzzy: Set<String> = [], learned: [String: Int] = [:], preferred: [Candidate] = [], recentCorrections: [Candidate] = [], limit: Int = 24, compose: Bool = true, correction: Bool = true, context: String = "", cancelled: () -> Bool = { false }) -> [Candidate] {
        let input = FuzzyPinyin.normalize(raw)
        guard !input.isEmpty, input.count <= Composition.maximumLength else { return [] }
        let repeated = raw.contains("'") ? [] : repeatedCandidates(input)
        guard !cancelled() else { return [] }
        if compose, !repeated.isEmpty, limit <= 9 {
            return Array(repeatedHead(repeated, raw: raw, length: input.count, preferred: preferred).prefix(max(1, limit)))
        }
        if !compose, matureDecoder != nil, input.count >= 3,
           associations?.lookup("e:" + input, limit: 1).isEmpty == false,
           chinese.lookup("e:" + input, limit: 1).isEmpty {
            return cancelled() ? [] : [Candidate(text: raw, reading: raw, consumed: input.count)]
        }
        if compose, let matureDecoder {
            if cancelled() { return [] }
            let result = matureDecoder.candidates(raw.lowercased(), limit: limit, correction: correction, context: context, cancelled: cancelled)
            if cancelled() { return [] }
            var output = result.sorted {
                $0.score + min(2, log(Double(learned[$0.text] ?? 0) + 1)) >
                $1.score + min(2, log(Double(learned[$1.text] ?? 0) + 1))
            }
            let literal = Candidate(text: raw, reading: raw, consumed: input.count, score: 80)
            let isEnglishWord = input.count >= 3 && associations?.lookup("e:" + input, limit: 1).isEmpty == false
            if isEnglishWord {
                // Ambiguous complete pinyin words (e.g. women/我们) keep the Chinese
                // default. Recognized English such as iphone/hello stays literal.
                if chinese.lookup("e:" + input, limit: 1).isEmpty { output.insert(literal, at: 0) }
                else { output.insert(literal, at: min(1, output.count)) }
            } else if correction, input.count >= 6, !raw.contains("'"), !result.contains(where: {
                $0.consumed == input.count && Self.matchesReadingWithInitials(input, reading: $0.reading)
            }) {
                // Decode a genuine pinyin prefix and preserve a recognized English
                // suffix as one token, instead of turning every Latin letter into Hanzi.
                for length in stride(from: min(20, input.count - 2), through: 4, by: -1) {
                    if cancelled() { return [] }
                    let suffix = String(input.suffix(length)), prefix = String(input.dropLast(length))
                    guard associations?.lookup("e:" + suffix, limit: 1).isEmpty == false,
                          PinyinSpelling.reachablePrefix(suffix) < suffix.count,
                          PinyinSpelling.reachablePrefix(prefix) == prefix.count,
                          chinese.lookup("e:" + input, limit: 1).isEmpty,
                          let first = matureDecoder.candidates(prefix, limit: 4, correction: false, context: context, cancelled: cancelled).first,
                          first.consumed == prefix.count else { continue }
                    output.insert(Candidate(text: first.text + suffix, consumed: input.count, score: 110), at: 0); break
                }
            }
            if correction, !fuzzy.isEmpty {
                for variant in FuzzyPinyin.variants(input, enabled: fuzzy, limit: limit <= 6 ? 3 : 12).dropFirst() {
                    if cancelled() { return [] }
                    output += matureDecoder.candidates(variant, limit: limit, context: context, cancelled: cancelled).filter { $0.consumed == variant.count }.map { Candidate(text: $0.text, reading: $0.reading, consumed: raw.count, score: $0.score - 10) }
                }
            }
            if !isEnglishWord { output.insert(contentsOf: initialCompletions(input), at: 0) }
            if !isEnglishWord, !raw.contains("'"), input.count <= 4,
               input.allSatisfy({ Self.initials.contains($0) }) {
                let words = shortInitialWords(input)
                // A prefix expansion must not displace a complete conversion.
                // Keep the decoder's first screen intact. Insert the same
                // bounded dictionary row after it on every page, so a larger
                // request cannot move a new expansion ahead of the visible head.
                let head = min(8, output.count)
                output = Array(output.prefix(head)) + words + Array(output.dropFirst(head))
                if let alias = Self.conversational[input], let index = output.firstIndex(where: { $0.text == alias }) {
                    output.insert(output.remove(at: index), at: 0)
                }
            }
            if !isEnglishWord { output.insert(contentsOf: conversationalCandidates(input, raw: raw), at: 0) }
            if correction, !isEnglishWord, !result.contains(where: {
                $0.consumed == input.count && Self.matchesReadingWithInitials(input, reading: $0.reading)
            }) {
                output.insert(contentsOf: recentCorrections.filter { $0.consumed == input.count }, at: 0)
            }
            // An alias is a preferred choice, never an exclusive result.
            if input.count >= 2, input.count % 2 == 0,
               input == String(repeating: "hd", count: input.count / 2) {
                output.insert(Candidate(text: String(repeating: "好的", count: input.count / 2),
                    reading: String(repeating: "hao de ", count: input.count / 2).trimmingCharacters(in: .whitespaces),
                    consumed: input.count, score: 120), at: 0)
            }
            if !repeated.isEmpty {
                output.insert(contentsOf: repeatedHead(repeated, raw: raw, length: input.count, preferred: preferred), at: 0)
            }
            output.insert(contentsOf: preferred.filter { $0.consumed > 0 && $0.consumed <= input.count }, at: 0)
            if !output.contains(where: { $0.text == raw }) { output.insert(literal, at: min(8, output.count)) }
            var seen = Set<String>(); return Array(output.filter { seen.insert($0.text).inserted }.prefix(max(1, min(4096, limit))))
        }
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
            .filter { seen.insert($0.text).inserted }.prefix(max(1, min(4096, limit))).map { $0 }
    }

    private func conversationalCandidates(_ input: String, raw: String) -> [Candidate] {
        guard !raw.contains("'") else { return [] }
        return (associations?.lookup("c:" + input, limit: 32) ?? [])
            .map { Candidate(text: $0.text, reading: $0.reading, consumed: input.count) }
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
        let tailLength = input.reversed().prefix { Self.initials.contains($0) }.count
        let literalPrefix = String(input.dropLast(tailLength))
        var literals: [Path] = []
        if mixed && (2...4).contains(tailLength) {
            literals = Array(primary.filter { FuzzyPinyin.normalize($0.reading).hasPrefix(literalPrefix) }.prefix(2))
        } else if spelling == input.count { literals = Array(primary.prefix(1)) }
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
    // A fully typed word prefix plus the final syllable's initial is intentional
    // partial spelling, not a reason to split that prefix into unrelated initials.
    // Use the existing common-word frequencies; complete only the final syllable.
    private func initialCompletions(_ input: String) -> [Candidate] {
        guard (3...32).contains(input.count), !chinese.contains("e:" + input) else { return [] }
        return Array(chinese.lookup("p:" + input, limit: 24).filter { entry in
            let syllables = entry.reading.split(separator: " ")
            guard syllables.count >= 2, let final = syllables.last, entry.frequency >= 200 else { return false }
            let prefix = syllables.dropLast().joined()
            guard input.hasPrefix(prefix), input.count > prefix.count else { return false }
            let tail = String(input.dropFirst(prefix.count))
            return tail.count < final.count && final.hasPrefix(tail) &&
                (tail.count == 1 || ["zh", "ch", "sh"].contains(tail)) && tail.allSatisfy(Self.initials.contains)
        }.prefix(3).map { Candidate(text: $0.text, reading: $0.reading, consumed: input.count, score: 110) })
    }
    private func abbreviation(_ reading: String) -> String { reading.split(separator: " ").compactMap(\.first).map(String.init).joined() }
    private func shortInitialWords(_ input: String) -> [Candidate] {
        // Read the bounded bucket before selecting a screen. Frequent prefix
        // expansions can otherwise occupy its first eight slots and hide every
        // exact word even though the index contains the complete abbreviation.
        let words = (associations?.lookup("i:" + input, limit: 32) ?? [])
            .map { Candidate(text: $0.text, reading: $0.reading, consumed: input.count) }
        return words.filter { abbreviation($0.reading) == input } +
            words.filter { abbreviation($0.reading).count > input.count }
    }
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
        guard !context.isEmpty, context.last?.isWhitespace != true else { return [] }
        for length in stride(from: min(6, context.count), through: 1, by: -1) {
            let prefix = String(context.suffix(length))
            let recent = associations?.lookup("t:" + prefix, limit: 8) ?? []
            let established = chinese.lookup("t:" + prefix, limit: associations == nil ? 12 : 4)
            for word in recent + established where word.text.count > length {
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
