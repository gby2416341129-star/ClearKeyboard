import Foundation

@_silgen_name("cr_test_native_score_limit") private func nativeScoreLimit() -> Int32

@main struct FastEngineChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func main() throws {
        let engine = try InputEngine.bundled()
        print("NATIVE_SCORING_POSITION_BUDGET \(nativeScoreLimit())")
        var rows: [[String: Any]] = []
        for (raw, expected) in [("en", "嗯"), ("enen", "嗯嗯"), ("enenen", "嗯嗯嗯"),
                                ("enhaode", "嗯好的"), ("enenhao", "嗯嗯好"),
                                ("shenmo", "什么"), ("zenmo", "怎么")] {
            let quick = engine.immediateCandidates(raw)
            let head = engine.candidates(raw, limit: 9), page = engine.candidates(raw, limit: 64)
            require(quick.first?.text == expected && head.first?.text == expected,
                    "A character typing reading is missing or changes after decoding: \(raw): \(quick) / \(head)")
            require(head.first?.consumed == raw.count, "An alias consumed the wrong spelling range")
            require(Array(page.prefix(head.count)) == head, "Paging changed an alias candidate")
            rows.append(["input": raw, "first": expected, "kind": "character-typing-reading"])
        }
        for (unit, expected) in [("jd", "记得"), ("hd", "好的"), ("nh", "你好"), ("xx", "谢谢"), ("zj", "再见")] {
            for count in [3, 8, 64, 128] {
                let raw = String(repeating: unit, count: count), text = String(repeating: expected, count: count)
                let started = ProcessInfo.processInfo.systemUptime
                let words = engine.immediateCandidates(raw), head = engine.candidates(raw, limit: 9)
                let ms = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                require(words.first?.text == text && head.first?.text == text,
                        "Repeat \(unit) x \(count): quick=\(words.first?.text ?? "nil") final=\(head.first?.text ?? "nil") expected=\(text)")
                require(words.first?.consumed == raw.count && head.first?.consumed == raw.count, "A long repeat has an invalid commit span")
                require(engine.hasImmediateComposition(raw), "A repeat unnecessarily waits for a sentence query")
                require(engine.candidates(raw, limit: 9, cancelled: { true }).isEmpty, "A cancelled repeat was returned")
                if count == 3 {
                    let page = engine.candidates(raw, limit: 40)
                    require(Array(page.prefix(min(head.count, page.count))) == head, "Paging moved a previously shown repeat row")
                }
                rows.append(["unit": unit, "repeats": count, "first": head.first!.text, "ms": ms])
            }
        }
        for raw in ["blblbl", "jdjdjdj"] {
            let head = engine.candidates(raw, limit: 9), page = engine.candidates(raw, limit: 40)
            require(Array(page.prefix(head.count)) == head, "A short or unfinished repeat page moved its literal candidate")
            if raw == "jdjdjdj" { require(head.first?.consumed == 6, "A partial repeat consumed its next initial") }
        }
        let personal = Candidate(text: "激动激动激动", reading: "ji dong ji dong ji dong", consumed: 6)
        let personalized = engine.candidates("jdjdjd", preferred: [personal], limit: 9)
        let personalizedPage = engine.candidates("jdjdjd", preferred: [personal], limit: 40)
        require(personalized.first == personal && Array(personalizedPage.prefix(personalized.count)) == personalized,
                "A preferred word outside the model's short row changed on paging")
        let index = try Lexicon.bundled("associations")
        for (raw, text, consumed) in [("gouboyuan", "苟", 3), ("boyuan", "博", 2), ("yuan", "渊", 4),
                                      ("chenyuhan", "陈", 4), ("yuhan", "宇", 2), ("han", "涵", 3),
                                      ("liuxinyue", "刘", 3), ("xinyue", "欣", 3), ("yue", "悦", 3)] {
            let head = engine.candidates(raw, limit: 9), page = engine.candidates(raw, limit: 256)
            require(page.contains { $0.text == text && $0.consumed == consumed }, "A name cannot be selected a character at a time: \(raw) / \(text)")
            require(Array(page.prefix(head.count)) == head, "Name alternatives changed the visible first screen")
            rows.append(["input": raw, "character": text, "consumed": consumed, "kind": "selectable-name-prefix"])
        }
        let initials = Array("bpmfdtnlgkhjqxrzcsyw")
        var exactRows = 0
        for n in 0..<1200 {
            var value = n * 7919 + 137
            let raw = String((0..<(n % 2 == 0 ? 3 : 4)).map { _ -> Character in
                defer { value /= initials.count }; return initials[value % initials.count]
            })
            guard !index.contains("e:" + raw), index.lookup("i:" + raw, limit: 32).contains(where: {
                String($0.reading.split(separator: " ").compactMap(\.first)) == raw
            }) else { continue }
            let words = engine.immediateCandidates(raw)
            require(words.first?.reading.split(separator: " ").count == raw.count,
                    "A prefix completion hid the exact fast row for \(raw): \(words)")
            exactRows += 1
        }
        require(exactRows > 20, "The generic short-initial check did not exercise enough dictionary rows")
        for raw in ["djdj", "wmdj", "nmdz", "hd", "nnnd", "cqm", "nnn", "jtzg"] {
            let head = engine.candidates(raw, limit: 9), page = engine.candidates(raw, limit: 96)
            require(Array(page.prefix(head.count)) == head, "Short-initial paging reordered the first screen: \(raw)")
        }
        for raw in ["jtzgsm", "lzqnmd", "busuanchadla", "wogeimam", "mamncfm", "nnnd"] {
            let values=engine.candidates(raw,limit:9)
            if raw=="busuanchadla" { require(values.first?.text=="不算差的啦", "Literal repair failed in the real engine: \(values)") }
            if raw=="nnnd" {
                require(engine.immediateCandidates(raw).first?.text == "你奶奶的" && values.first?.text == "你奶奶的",
                        "Prefix expansion still displaced the complete conversion: \(values)")
                let page=engine.candidates(raw,limit:64)
                require(Array(page.prefix(values.count)) == values, "Browsing changed the initial candidate row")
                require(page.contains { $0.text == "奶奶你到家没" }, "A longer completion was lost instead of ranked later")
            }
            rows.append(["input":raw,"head":values.map(\.text),"readings":values.map(\.reading)])
        }
        for (raw, expected) in [("wcfl", "我吃饭了"), ("nijtchifanlema", "你今天吃饭了吗"), ("nijtchifanlemei", "你今天吃饭了没")] {
            let head = engine.candidates(raw, limit: 9), page = engine.candidates(raw, limit: 64)
            require(head.first?.text == expected && head.first?.consumed == raw.count,
                    "Shared-prefix initialism comparison missed its spoken alternative: \(raw): \(head)")
            require(Array(page.prefix(head.count)) == head, "An initialism changed when browsing")
            rows.append(["input": raw, "head": head.map(\.text), "kind": "shared-prefix-initialism"])
        }
        // The final m abbreviates both ma and mei. A slow backend may retain
        // either legitimate dictionary question; both must remain immediately
        // selectable. Fully specified final syllables above remain strict.
        let ambiguous = engine.candidates("nijtchiflm", limit: 9)
        require(["你今天吃饭了吗", "你今天吃饭了没", "你今天吃饭了么"].contains(ambiguous.first?.text ?? ""), "An abbreviated question lost its literal reading")
        require(ambiguous.prefix(3).contains { $0.text == "你今天吃饭了吗" } && ambiguous.prefix(3).contains { $0.text == "你今天吃饭了没" }, "Shared-prefix question alternatives must remain on the first screen")
        require(Array(engine.candidates("nijtchiflm", limit: 64).prefix(ambiguous.count)) == ambiguous, "Ambiguous questions moved on paging")
        rows.append(["input": "nijtchiflm", "head": ambiguous.map(\.text), "kind": "ambiguous-question-initials"])
        var contextualRows: [[String: Any]] = []
        var initialWindows: [[String: Any]] = []
        for raw in [String(repeating: "wmjtqcf", count: 20), String(repeating: "nijtchiflm", count: 20)] {
            let started = ProcessInfo.processInfo.systemUptime
            let head = engine.candidates(raw, limit: 9), page = engine.candidates(raw, limit: 64)
            let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            require(!head.isEmpty && head.allSatisfy { $0.consumed > 0 && $0.consumed <= 64 && $0.consumed < raw.count },
                    "A long initialism bypassed its bounded selectable prefix")
            require(Array(page.prefix(head.count)) == head, "An ambiguity window moved its visible candidate row")
            initialWindows.append(["letters": raw.count, "maximumConsumed": head.map(\.consumed).max()!, "headAndPageMS": milliseconds])
        }
        for (raw, preceding, expected) in [
            ("buguixianzaishi", "", "不过现在是"), ("buguoxianzaishi", "", "不过现在是"),
            ("nichifankm", "", "你吃饭了吗"), ("nichifanlm", "", "你吃饭了吗"),
            ("nixiabankm", "", "你下班了吗"),
            ("birunijintianzaiganshenmo", "", "比如你今天在干什么"),
            ("mafangeiwokaiyizhangdianzifapiao", "", "麻烦给我开一张电子发票"),
            ("niqhilema", "", "你吃了吗"), ("woxiangqhifan", "", "我想吃饭"),
            ("shi", "我正在考", "试"), ("shi", "", "是"), ("shi", "我正在考", "试"),
            ("ji", "办公", "机"), ("che", "公交", "车"), ("qi", "电脑重", "启"),
            ("shishi", "历史上的", "事实"), ("shishi", "让我们来", "试试"),
            ("qhimian", "我想去餐馆", "吃面"), ("qhimian", "最近我老是", "失眠"),
            ("qhimian", "我们应该勇敢", "直面"), ("qhimian", "我想去餐馆", "吃面")
        ] {
            let started = ProcessInfo.processInfo.systemUptime
            let head = engine.candidates(raw, limit: 9, context: preceding)
            let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            require(head.first?.text == expected && head.first?.consumed == raw.count,
                    "Context/typo failed after \(milliseconds) ms: \(preceding) + \(raw): \(head)")
            let page = engine.candidates(raw, limit: 96, context: preceding)
            require(Array(page.prefix(head.count)) == head,
                    "A restored context cache changed its page head: \(preceding) + \(raw); head=\(head); page=\(Array(page.prefix(head.count)))")
            contextualRows.append(["input": raw, "preceding": preceding, "first": head.first!.text, "queryMS": milliseconds])
        }
        for (raw, consumed) in [("chongzhika", 8), ("congzhika", 7), ("chongzika", 7)] {
            let head = engine.candidates(raw, limit: 9), page = engine.candidates(raw, limit: 96)
            require(head.contains { $0.text == "重置卡" && $0.consumed == raw.count }, "A homophonous word + character is missing: \(raw): \(head)")
            require(page.contains { $0.text == "重置" && $0.consumed == consumed }, "A selectable word prefix disappeared: \(raw): \(page)")
            require(Array(page.prefix(head.count)) == head, "Word alternatives moved on paging: \(raw)")
            rows.append(["input": raw, "head": head.map(\.text), "prefixSelectable": "重置", "prefixConsumed": consumed])
        }
        print(String(data: try JSONSerialization.data(withJSONObject: ["status": "passed", "rows": rows, "exactInitialRowsChecked": exactRows, "contextualRows": contextualRows, "initialWindows": initialWindows,
            "scope": "macOS release, real Swift InputEngine and Rime; excludes UIKit, physical phone and display frame rate"], options: [.sortedKeys]), encoding: .utf8)!)
    }
}
