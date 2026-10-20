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
    /// Bounded variants; edit one syllable boundary at a time instead of exponential rewrites.
    public static func variants(_ input: String, enabled: Set<String>, limit: Int = 12) -> [String] {
        var result = [input], seen: Set<String> = [input]
        for pair in availablePairs where enabled.contains(pair) {
            let parts = pair.split(separator: "/").map(String.init)
            for (from, to) in [(parts[0], parts[1]), (parts[1], parts[0])] {
                var search = input.startIndex..<input.endIndex
                while let range = input.range(of: from, range: search) {
                    // Do not turn zhong into zh + hong, or an into ang + g.
                    let next = range.upperBound < input.endIndex ? input[range.upperBound] : nil
                    let valid = !(to.count > from.count && next == (from.count == 1 ? "h" : "g"))
                    if valid {
                        var changed = input; changed.replaceSubrange(range, with: to)
                        if seen.insert(changed).inserted { result.append(changed) }
                        if result.count >= limit { return result }
                    }
                    guard range.upperBound < input.endIndex else { break }
                    search = range.upperBound..<input.endIndex
                }
            }
        }
        return result
    }
}

/// Syllables from the bundled lexicon; bounded spelling checks require no expanded dictionary trie.
enum PinyinSpelling {
    private static let syllables: Set<String> = Set("a ai an ang ao ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo e ei en eng er fa fan fang fei fen feng fiao fo fou fu ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo ha hai han hang hao he hei hen heng hm hong hou hu hua huai huan huang hui hun huo ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lue lun luo lv m ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu n na nai nan nang nao ne nei nen neng ng ni nian niang niao nie nin ning niu nong nou nu nuan nue nuo nv o ou pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun ran rang rao re ren reng ri rong rou ru ruan rui run ruo sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo ta tai tan tang tao te tei teng ti tian tiao tie ting tong tou tu tuan tui tun tuo wa wai wan wang wei wen weng wo wu xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo".split(separator: " ").map(String.init))
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

/// CLRC0001: header(48), sorted fingerprint/lexicon-ID records(12 each).
/// The precompiled index remains mapped; no word trie or expanded signature dictionary is built at startup.
final class PinyinCorrectionIndex {
    private let data: Data
    private let count: Int
    init(url: URL, lexiconCount: Int) throws {
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count >= 48, bytes.prefix(8) == Data("CLRC0001".utf8) else { throw LexiconError.invalidFormat }
        let words = bytes.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self))) }
        let records = bytes.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self))) }
        guard words == lexiconCount, records <= (bytes.count - 48) / 12, 48 + records * 12 == bytes.count else { throw LexiconError.truncated }
        data = bytes; count = records
    }
    static func bundled(lexiconCount: Int) throws -> PinyinCorrectionIndex {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "pinyin-corrections", withExtension: "clx") else { throw LexiconError.invalidFormat }
        return try PinyinCorrectionIndex(url: url, lexiconCount: lexiconCount)
    }
    private static func signature(_ bytes: [UInt8], skipping: Int? = nil) -> UInt64 {
        var result: UInt64 = 0xCBF29CE484222325
        for index in bytes.indices where index != skipping { result = (result ^ UInt64(bytes[index])) &* 0x100000001B3 }
        return result
    }
    private func ids(for fingerprint: UInt64) -> [Int] {
        data.withUnsafeBytes { raw in
            func hash(_ index: Int) -> UInt64 { UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 48 + index * 12, as: UInt64.self)) }
            var low = 0, high = count
            while low < high { let mid = (low + high) / 2; if hash(mid) < fingerprint { low = mid + 1 } else { high = mid } }
            var result: [Int] = []
            while low < count, result.count < 24, hash(low) == fingerprint {
                result.append(Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 56 + low * 12, as: UInt32.self)))); low += 1
            }
            return result
        }
    }
    func matches(_ input: String, lexicon: Lexicon, cancelled: () -> Bool = { false }) -> [(LexiconEntry, Double)] {
        let bytes = Array(input.utf8)
        guard (2...13).contains(bytes.count) else { return [] }
        var identifiers = Set(ids(for: Self.signature(bytes))), additional: [LexiconEntry] = []
        for index in bytes.indices {
            if cancelled() { return [] }
            identifiers.formUnion(ids(for: Self.signature(bytes, skipping: index)))
            let shorter = String(decoding: Array(bytes[..<index]) + Array(bytes[(index + 1)...]), as: UTF8.self)
            additional += lexicon.lookup("e:" + shorter, limit: 3)
        }
        var seen = Set<String>(), result: [(LexiconEntry, Double)] = []
        for entry in identifiers.sorted().compactMap({ lexicon.entry($0) }) + additional {
            if cancelled() { return [] }
            guard seen.insert(entry.key + ":" + entry.text).inserted,
                  let penalty = PinyinSpelling.editPenalty(input, entry.key) else { continue }
            result.append((entry, penalty))
        }
        return result
    }
}
