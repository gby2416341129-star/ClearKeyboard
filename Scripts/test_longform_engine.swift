import Foundation

private struct LifestyleCorpus: Decodable {
    struct Clause: Decodable { let text: String; let syllables: [String] }
    struct Paragraph: Decodable { let id: String; let text: String; let clauses: [Clause]; let sentences: [Clause] }
    struct Article: Decodable { let id: String; let title: String; let hanCharacters: Int; let paragraphs: [Paragraph] }
    let articles: [Article]
}

@main struct LongFormEngineChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func edits(_ a: String, _ b: String) -> Int {
        let left = Array(a), right = Array(b)
        var previous = Array(0...right.count)
        for (i, x) in left.enumerated() {
            var current = [i + 1]
            for (j, y) in right.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = current
        }
        return previous.last ?? 0
    }
    static func variants(_ syllables: [String]) -> [(String, String)] {
        let raw = syllables.joined()
        var result = [("full", raw), ("initials", syllables.compactMap(\.first).map(String.init).joined()),
            ("mixed", syllables.enumerated().map { index, token in
                index % 3 == 0 && index != syllables.count - 1 ? token : String(token.prefix(1))
            }.joined())]
        var starts: [Int] = [], offset = 0
        for token in syllables { starts.append(offset); offset += token.count }
        let positions = zip(starts, syllables).flatMap { start, token in
            token.count >= 3 ? Array((start + 1)..<(start + token.count - 1)) : []
        }
        if let position = positions.min(by: { abs($0 - raw.count / 2) < abs($1 - raw.count / 2) }) {
            let letters = Array(raw)
            var neighbor = letters, omit = letters
            for row in [Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm")] {
                if let index = row.firstIndex(of: letters[position]) {
                    neighbor[position] = row[index + 1 < row.count ? index + 1 : index - 1]
                }
            }
            omit.remove(at: position)
            result.append(("typo_neighbor", String(neighbor))); result.append(("typo_omit", String(omit)))
            if letters[position] != letters[position + 1] {
                var transpose = letters; transpose.swapAt(position, position + 1)
                result.append(("typo_transpose", String(transpose)))
            }
        }
        return result
    }
    static func main() throws {
        let path = CommandLine.arguments.dropFirst().first ?? "Tests/Evaluation/lifestyle-longform.json"
        let corpus = try JSONDecoder().decode(LifestyleCorpus.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        require(corpus.articles.count >= 4 && corpus.articles.allSatisfy { $0.hanCharacters >= 600 }, "Long articles were replaced with short examples")
        let engine = try InputEngine.bundled()
        var rows: [[String: Any]] = [], windows = 0
        for article in corpus.articles {
            var preceding = ""
            for paragraph in article.paragraphs {
                for (kind, cases) in [("clause", paragraph.clauses), ("sentence", paragraph.sentences)] {
                    var context = preceding
                    for sample in cases {
                        require(sample.text.count == sample.syllables.count, "Unaligned reference annotation")
                        let inputs = kind == "clause" ? [("full", sample.syllables.joined())] : variants(sample.syllables)
                        for (variant, raw) in inputs {
                            let started = ProcessInfo.processInfo.systemUptime
                            let head = engine.candidates(raw, limit: 9, context: context)
                            let ms = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                            let page = engine.candidates(raw, limit: 64, context: context)
                            require(Array(page.prefix(head.count)) == head, "Browsing moved a long-text candidate")
                            require(!head.isEmpty && head.allSatisfy { $0.consumed > 0 && $0.consumed <= raw.count }, "Long-text query has an invalid selectable span")
                            let rank = page.firstIndex { $0.text == sample.text && $0.consumed == raw.count }.map { $0 + 1 } ?? 0
                            rows.append(["article": article.id, "paragraph": paragraph.id, "kind": kind, "variant": variant,
                                "input": raw, "expected": sample.text, "first": head.first?.text ?? "", "rank64": rank,
                                "editDistance": edits(head.first?.text ?? "", sample.text), "milliseconds": ms])
                        }
                        context += sample.text
                    }
                }
                preceding += paragraph.clauses.map(\.text).joined()
            }
            let raw = article.paragraphs.flatMap(\.clauses).flatMap(\.syllables).joined()
            require(raw.count > 1_500, "Article no longer crosses the old automatic-commit boundary")
            let head = engine.candidates(raw, limit: 9), page = engine.candidates(raw, limit: 64)
            require(!head.isEmpty && Array(page.prefix(head.count)) == head, "A whole article has no stable prefix choices")
            require(head.allSatisfy { $0.consumed > 0 && $0.consumed < raw.count }, "A bounded article candidate consumed unexamined letters")
            windows += 1
        }
        var groups: [String: [String: Any]] = [:]
        for key in Set(rows.map { ($0["kind"] as! String) + "/" + ($0["variant"] as! String) }) {
            let group = rows.filter { ($0["kind"] as! String) + "/" + ($0["variant"] as! String) == key }
            let characters = group.reduce(0) { $0 + ($1["expected"] as! String).count }
            let times = group.map { $0["milliseconds"] as! Double }.sorted()
            groups[key] = ["cases": group.count, "characters": characters,
                "top1": group.filter { $0["rank64"] as! Int == 1 }.count,
                "top9": group.filter { let rank = $0["rank64"] as! Int; return rank > 0 && rank <= 9 }.count,
                "top64": group.filter { $0["rank64"] as! Int > 0 }.count,
                "characterEditRate": Double(group.reduce(0) { $0 + ($1["editDistance"] as! Int) }) / Double(characters),
                "queryP50MS": times[times.count / 2], "queryP95MS": times[max(0, Int(ceil(Double(times.count) * 0.95)) - 1)]]
        }
        var examples: [[String: Any]] = []
        for (raw, expected) in [("wcfl", "我吃饭了"), ("birunijintianzaiganshenmo", "比如你今天在干什么"), ("nijtchiflm", "你今天吃饭了吗")] {
            let head = engine.candidates(raw, limit: 9)
            examples.append(["input": raw, "expected": expected, "head": head.map(\.text)])
        }
        for (raw, context, syllable) in [
            ("wozhihaoyoutaoshangwaitaopaoxiaqu", "他说门卫已经下班了最好赶紧下来拿", "pao"),
            ("wohuixianchaiyigexiangzi", "这几天晚上下班回来", "chai"),
            ("woshuoguodouhaimeixine", "邻居正好牵着狗回来问我吃饭没有", "shuo")
        ] {
            let head = engine.candidates(raw, limit: 9, context: context)
            require(head.first?.reading.split(separator: " ").contains(Substring(syllable)) == true, "An ordinary collocation silently rewrote correctly typed pinyin")
        }
        let summary: [String: Any] = ["status": "measured", "structuralChecks": "passed", "articles": corpus.articles.count,
            "articleCharacters": corpus.articles.reduce(0) { $0 + $1.hanCharacters }, "wholeArticleWindows": windows,
            "groups": groups, "reportedExamples": examples,
            "scope": "macOS real Swift InputEngine/Rime with production neural configuration and reference preceding context. Exact-sentence accuracy is not character accuracy. Excludes UIKit, physical phone frame rate and WeChat comparisons."]
        let report: [String: Any] = ["summary": summary, "rows": rows]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: ".build/lifestyle-longform-results.json"))
        print("LONGFORM_ENGINE " + String(data: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
