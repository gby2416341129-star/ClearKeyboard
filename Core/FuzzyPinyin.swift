import Foundation
import CoreGraphics

public enum FuzzyPinyin {
    public static let availablePairs = ["z/zh", "c/ch", "s/sh", "n/l", "f/h", "an/ang", "en/eng", "in/ing"]
    public static func normalize(_ input: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(input.utf8.count)
        // Keyboard input is ASCII. Avoid a lowercase copy, a replacement scan,
        // and one temporary String allocation per letter on every key/frame.
        if input.utf8.allSatisfy({ $0 < 128 }) {
            for byte in input.utf8 {
                if (97...122).contains(byte) { bytes.append(byte) }
                else if (65...90).contains(byte) { bytes.append(byte + 32) }
            }
        } else {
            // Preserve Unicode lowercasing (including dotted I/Kelvin sign),
            // and the existing ü -> v convention for imported/user spellings.
            for scalar in input.lowercased().replacingOccurrences(of: "ü", with: "v").unicodeScalars {
                if (97...122).contains(scalar.value) { bytes.append(UInt8(scalar.value)) }
                else if scalar.value == 252 { bytes.append(118) }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
    /// Bounded syllable alternatives. Initials only change at a syllable start;
    /// finals only change at its end. Never rewrite the h inside shi/zhong or
    /// the n in the middle of a following syllable.
    public static func variants(_ input: String, enabled: Set<String>, limit: Int = 12) -> [String] {
        alternatives(input, enabled: enabled, limit: limit).map(\.code)
    }
    struct Alternative { let code: String; let edits: Int }
    static func alternatives(_ raw: String, enabled: Set<String>, limit: Int = 12) -> [Alternative] {
        let input = normalize(raw)
        guard !input.isEmpty, !enabled.isEmpty, limit > 1 else { return [Alternative(code: input, edits: 0)] }
        let pieces = raw.lowercased().split(separator: "'").map { normalize(String($0)) }
        var paths: [[String]] = [[]]
        for piece in pieces {
            let letters = Array(piece), count = letters.count
            guard count > 0 else { continue }
            var at = [[[String]]](repeating: [], count: count + 1); at[0] = [[]]
            for end in 1...count {
                var options: [[String]] = []
                for start in max(0, end - 6)..<end where !at[start].isEmpty {
                    let token = String(letters[start..<end])
                    guard PinyinSpelling.syllables.contains(token) || initials.contains(token) else { continue }
                    options += at[start].map { $0 + [token] }
                }
                at[end] = Array(options.sorted { $0.count == $1.count ? $0.joined(separator: " ") < $1.joined(separator: " ") : $0.count < $1.count }.prefix(2))
            }
            guard !at[count].isEmpty else { return [Alternative(code: input, edits: 0)] }
            let fewest = at[count].map(\.count).min() ?? 0
            let complete = at[count].filter { $0.count == fewest }
            paths = Array(paths.flatMap { prefix in complete.map { prefix + $0 } }.prefix(2))
        }
        var results = [Alternative(code: input, edits: 0)], seen: Set<String> = [input]
        let bound = max(12, min(96, limit * 2))
        for path in paths {
            var beam = [Alternative(code: "", edits: 0)]
            for token in path {
                let choices = syllableAlternatives(token, enabled: enabled)
                var next: [Alternative] = [], known = Set<String>()
                for prefix in beam {
                    for choice in choices where prefix.edits + choice.edits <= 3 {
                        let code = prefix.code + choice.code
                        if known.insert(code).inserted { next.append(Alternative(code: code, edits: prefix.edits + choice.edits)) }
                    }
                }
                beam = Array(next.sorted { $0.edits == $1.edits ? $0.code < $1.code : $0.edits < $1.edits }.prefix(bound))
            }
            for value in beam where seen.insert(value.code).inserted { results.append(value) }
        }
        return Array(results.sorted { $0.edits == $1.edits ? $0.code < $1.code : $0.edits < $1.edits }.prefix(max(1, limit)))
    }
    private static let initials: Set<String> = Set("b p m f d t n l g k h j q x zh ch sh r z c s y w".split(separator: " ").map(String.init))
    private static func syllableAlternatives(_ token: String, enabled: Set<String>) -> [Alternative] {
        var result = [Alternative(code: token, edits: 0)], seen: Set<String> = [token]
        for pair in availablePairs where enabled.contains(pair) {
            let parts = pair.split(separator: "/").map(String.init)
            for value in result {
                for (from, to) in [(parts[0], parts[1]), (parts[1], parts[0])] {
                    let changed: String
                    if parts[0].count <= 1 {
                        guard value.code.hasPrefix(from) else { continue }
                        // z -> zh must not match the already complete zh initial.
                        if from.count == 1, to.count == 2, value.code.dropFirst().first == "h" { continue }
                        changed = to + value.code.dropFirst(from.count)
                    } else {
                        guard value.code.hasSuffix(from) else { continue }
                        changed = value.code.dropLast(from.count) + to
                    }
                    guard PinyinSpelling.syllables.contains(changed) || initials.contains(changed), seen.insert(changed).inserted else { continue }
                    result.append(Alternative(code: changed, edits: value.edits + 1))
                }
            }
        }
        return result
    }
}

/// Syllables from the bundled lexicon; bounded spelling checks require no expanded dictionary trie.
enum PinyinSpelling {
    static let syllables: Set<String> = Set("a ai an ang ao ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo e ei en eng er fa fan fang fei fen feng fiao fo fou fu ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo ha hai han hang hao he hei hen heng hm hong hou hu hua huai huan huang hui hun huo ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lue lun luo lv m ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu n na nai nan nang nao ne nei nen neng ng ni nian niang niao nie nin ning niu nong nou nu nuan nue nuo nv o ou pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun ran rang rao re ren reng ri rong rou ru ruan rui run ruo sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo ta tai tan tang tao te tei teng ti tian tiao tie ting tong tou tu tuan tui tun tuo wa wai wan wang wei wen weng wo wu xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo".split(separator: " ").map(String.init))
    static func reachablePrefix(_ input: String) -> Int {
        let chars = Array(input), count = chars.count
        var reachable = [Bool](repeating: false, count: count + 1); reachable[0] = true
        var furthest = 0
        for start in 0..<count where reachable[start] {
            for end in (start + 1)...min(count, start + 6) where syllables.contains(String(chars[start..<end])) {
                reachable[end] = true; furthest = max(furthest, end)
            }
        }
        return furthest
    }
    /// Recover a bounded full-syllable prefix using lookahead. Prefer fewer
    /// syllables so an/ng and a/n/g are not arbitrarily split at the window edge.
    static func prefixBoundary(_ input: String, noLaterThan limit: Int) -> Int {
        let letters = Array(input), count = letters.count
        var cost = [Int](repeating: Int.max, count: count + 1)
        var parent = [Int](repeating: -1, count: count + 1)
        cost[0] = 0
        if count > 0 {
            for start in 0..<count where cost[start] != Int.max {
                for end in (start + 1)...min(count, start + 6)
                    where syllables.contains(String(letters[start..<end])) && cost[start] + 1 < cost[end] {
                    cost[end] = cost[start] + 1; parent[end] = start
                }
            }
        }
        var end = (0...count).last { cost[$0] != Int.max } ?? 0
        while end > limit, parent[end] >= 0 { end = parent[end] }
        // Blind-typing errors can block the lattice much earlier. Keep the
        // bounded correction channel available instead of returning an empty row.
        return end >= limit - 6 ? end : min(limit, count)
    }
    /// Initialisms can represent many more syllables than equally long full
    /// pinyin. Bound that ambiguity before running the model decoder.
    /// Full spelling and short mixed input retain their entire sentence.
    static func abbreviatedWindowBoundary(_ input: String, syllableLimit: Int = 16) -> Int? {
        let letters = Array(input), count = letters.count
        guard count > syllableLimit else { return nil }
        let initials = Set("bpmfdtnlgkhjqxrzcsyw"), vowels = Set("aeiouv")
        var units = [Int](repeating: Int.max, count: count + 1)
        var abbreviated = [Int](repeating: Int.max, count: count + 1)
        var parent = [Int](repeating: -1, count: count + 1)
        units[0] = 0; abbreviated[0] = 0
        for start in 0..<count where units[start] != Int.max {
            func advance(_ end: Int, initial: Bool) {
                let nextUnits = units[start] + 1, nextInitials = abbreviated[start] + (initial ? 1 : 0)
                if nextUnits < units[end] || (nextUnits == units[end] && nextInitials < abbreviated[end]) {
                    units[end] = nextUnits; abbreviated[end] = nextInitials; parent[end] = start
                }
            }
            for end in (start + 1)...min(count, start + 6) {
                let token = String(letters[start..<end])
                if syllables.contains(token) { advance(end, initial: !token.contains(where: vowels.contains)) }
                if ["zh", "ch", "sh"].contains(token) { advance(end, initial: true) }
            }
            if initials.contains(letters[start]) { advance(start + 1, initial: true) }
        }
        guard units[count] != Int.max, units[count] > syllableLimit, abbreviated[count] >= 8 else { return nil }
        var end = count
        while units[end] > syllableLimit, parent[end] >= 0 { end = parent[end] }
        return end > 0 && end < count ? end : nil
    }
    private static let keyPositions: [UInt8: CGPoint] = {
        var positions: [UInt8: CGPoint] = [:]
        for (row, value) in ["qwertyuiop", "asdfghjkl", "zxcvbnm"].enumerated() {
            for (column, byte) in value.utf8.enumerated() {
                positions[byte] = CGPoint(x: Double(column) + [0.0, 0.25, 0.75][row], y: Double(row))
            }
        }
        return positions
    }()
    /// One typo per lexical word; the sentence decoder controls the total edit budget.
    static func editPenalty(_ raw: String, _ expected: String) -> Double? {
        let a = Array(raw.utf8), b = Array(expected.utf8)
        guard a != b, abs(a.count - b.count) <= 1 else { return nil }
        if a.count == b.count {
            let differences = a.indices.filter { a[$0] != b[$0] }
            if differences.count == 2 {
                let i = differences[0], j = differences[1]
                return j == i + 1 && a[i] == b[j] && a[j] == b[i] ? 1.5 : nil
            }
            guard differences.count == 1, let p = keyPositions[a[differences[0]]], let q = keyPositions[b[differences[0]]] else { return nil }
            let distance = (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)
            return distance <= 2.3 ? 2.4 : 4.5
        }
        let short = a.count < b.count ? a : b, long = a.count < b.count ? b : a
        for index in long.indices where Array(long[..<index]) + Array(long[(index + 1)...]) == short {
            if a.count < b.count { return 3.5 }
            return index > 0 && long[index] == long[index - 1] ? 1.8 : 4
        }
        return nil
    }
}
