import Foundation

public enum FuzzyPinyin {
    public static let availablePairs = ["z/zh", "c/ch", "s/sh", "n/l", "f/h", "an/ang", "en/eng", "in/ing"]
    public static func normalize(_ input: String) -> String {
        input.lowercased().replacingOccurrences(of: "ü", with: "v").unicodeScalars
            .filter { (97...122).contains($0.value) }.map(String.init).joined()
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
    static func repairs(_ input: String, near stalled: Int) -> [(String, Double)] {
        let chars = Array(input), count = chars.count
        guard count > 1 else { return [] }
        let lower = max(0, stalled - 2), upper = min(count - 1, stalled + 5)
        var seen: Set<String> = [input], output: [(String, Double)] = []
        func add(_ value: [Character], penalty: Double) {
            let word = String(value)
            guard seen.insert(word).inserted, reachablePrefix(word) == value.count else { return }
            output.append((word, penalty))
        }
        // Adjacent transpositions are common fast-typing errors, and preserve every typed letter.
        for index in lower...upper where index + 1 < count && chars[index] != chars[index + 1] {
            var value = chars; value.swapAt(index, index + 1); add(value, penalty: 1.5)
        }
        for index in lower...upper {
            var value = chars; value.remove(at: index)
            add(value, penalty: index > 0 && chars[index] == chars[index - 1] ? 2.5 : 5)
        }
        // Missing letters are searched only around the first invalid syllable, never over the whole sentence.
        for index in lower...min(count, upper + 1) {
            for letter in "aeiouvnghrbcdfjklmpqstwxyz" {
                var value = chars; value.insert(letter, at: index); add(value, penalty: 3.5)
            }
        }
        let rows = [Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm")]
        for index in lower...upper {
            for (row, letters) in rows.enumerated() {
                guard let column = letters.firstIndex(of: chars[index]) else { continue }
                for otherRow in max(0, row - 1)...min(2, row + 1) {
                    let first = max(0, column - 1), last = min(rows[otherRow].count - 1, column + 1)
                    guard first <= last else { continue }
                    for otherColumn in first...last {
                        let letter = rows[otherRow][otherColumn]
                        if letter != chars[index] {
                            var value = chars; value[index] = letter; add(value, penalty: 4)
                        }
                    }
                }
            }
        }
        return Array(output.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.prefix(24))
    }
}
