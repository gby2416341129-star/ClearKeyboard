import XCTest
@testable import ClearCore

final class MatureEngineTests: XCTestCase {
    private var engine: InputEngine!
    override func setUpWithError() throws { engine = try .bundled() }
    func testProductionUsesRimeAndWanxiang() { XCTAssertEqual(engine.chineseBackend, "rime-wanxiang") }
    func testAddressQuestionsHaveFastMixedSpellingCandidates() {
        let cases = [
            "mamncfm": "妈妈你吃饭吗", "mamancfm": "妈妈你吃饭吗", "mmncfm": "妈妈你吃饭吗",
            "babancfm": "爸爸你吃饭吗", "laopncfm": "老婆你吃饭吗", "laogncfm": "老公你吃饭吗",
            "laosncfm": "老师你吃饭吗", "gegncfm": "哥哥你吃饭吗",
            "mamnzgm": "妈妈你在干嘛", "babanxbm": "爸爸你下班没"
        ]
        for (raw, expected) in cases {
            let immediate = engine.immediateCandidates(raw)
            XCTAssertEqual(immediate.first?.text, expected, raw)
            for limit in [9, 96] {
                let values = engine.candidates(raw, limit: limit)
                XCTAssertEqual(values.first?.text, expected, raw)
                XCTAssertEqual(values.first?.consumed, raw.count, raw)
                XCTAssertEqual(Array(values.prefix(immediate.count)), immediate, raw)
            }
        }
        XCTAssertEqual(engine.immediateCandidates("mamcfm").first?.text, "妈妈吃饭没",
                       "Do not silently add a missing pronoun to an exact abbreviation")
    }
    func testCorrectSpellingCannotBeOverriddenByBroadCorrection() {
        let cases = [
            "babanichifanlema": "爸爸你吃饭了吗",
            "babanichifablema": "爸爸你吃饭了吗",
            "bababuchifanlema": "爸爸不吃饭了吗",
            "wobuxiangchifan": "我不想吃饭",
            "nibuyaobawenjianshanchu": "你不要把文件删除",
            "mamanichifanlemawochiledewochiledenichilema": "妈妈你吃饭了吗我吃了的我吃了的你吃了吗",
            "dengyixiawozaigeinidagedianhua": "等一下我再给你打个电话"
        ]
        for (raw, expected) in cases {
            for limit in [9, 24, 96] {
                XCTAssertEqual(engine.candidates(raw, limit: limit).first?.text, expected, raw)
            }
        }
    }
    func testCommonInitialCompletionsHaveOneOrderAcrossPages() {
        for raw in ["djdj", "wmdj", "nmdz", "hd"] {
            let quick = engine.immediateCandidates(raw).map(\.text)
            let first = engine.candidates(raw, limit: 9).map(\.text)
            let expanded = engine.candidates(raw, limit: 96).map(\.text)
            XCTAssertEqual(Array(first.prefix(quick.count)), quick, raw)
            XCTAssertEqual(Array(expanded.prefix(8)), Array(first.prefix(8)), raw)
            XCTAssertGreaterThan(expanded.count, first.count, raw)
        }
        XCTAssertEqual(engine.immediateCandidates("djdj").first?.text, "大家都觉得")
        XCTAssertEqual(engine.candidates("djdj", limit: 96).first?.consumed, 4)
    }
    func testChineseMixedInitialsDoNotBecomeAnEnglishSuffix() {
        for limit in [9, 24, 64] {
            let values = engine.candidates("wogeimam", limit: limit)
            XCTAssertEqual(values.first?.text, "我给妈妈")
            XCTAssertFalse(values.contains { $0.text == "我哥imam" || $0.text == "我哥 imam" })
        }
        XCTAssertTrue(InputEngine.matchesReadingWithInitials("wogeimam", reading: "wo gei ma ma"))
        XCTAssertFalse(InputEngine.matchesReadingWithInitials("wodeiphone", reading: "wo dei ping heng ou nai er"))
        XCTAssertEqual(engine.candidates("wodeiphone", limit: 9).first?.text, "我的iphone")
    }
    func testReportedSentenceUsesCorrectedLeadingRowAndRecentRepeatedPhrase() throws {
        for (raw, text) in ["mamanichifanlema": "妈妈你吃饭了吗", "wochielde": "我吃了的", "nichilema": "你吃了吗"] {
            XCTAssertEqual(engine.candidates(raw, limit: 9).first?.text, text, raw)
        }
        let chosen = try XCTUnwrap(engine.candidates("wochielde", limit: 9).first)
        var memory = PersonalLexicon(); memory.record(chosen, for: "wochielde")
        XCTAssertEqual(engine.candidates("wochiekdr", recentCorrections: memory.recentCorrections(for: "wochiekdr"), limit: 9).first?.text, "我吃了的")
    }
    func testShorthandAliasRetainsCommonAlternativesAndSupportsMoreThan24Choices() {
        let small = engine.candidates("hd", limit: 24, correction: false)
        let larger = engine.candidates("hd", limit: 96, correction: false)
        XCTAssertEqual(small.first?.text, "好的")
        XCTAssertGreaterThan(larger.count, 24)
        XCTAssertLessThanOrEqual(larger.count, 96)
        for text in ["好的", "很多", "回答", "hd"] {
            XCTAssertTrue(larger.contains { $0.text == text }, text)
        }
        XCTAssertTrue(larger.allSatisfy { $0.consumed > 0 && $0.consumed <= 2 })
        XCTAssertEqual(Set(larger.map(\.text)).count, larger.count)
        XCTAssertEqual(engine.candidates("hd", limit: 24, correction: false), small,
                       "Reusing the bounded cache after browsing must preserve the leading choices")
    }
    func testShortExactPhraseListDoesNotHideOtherDecoderChoices() {
        let values = engine.candidates("djdj", limit: 64, correction: false)
        XCTAssertGreaterThan(values.count, 8)
        XCTAssertTrue(values.contains { $0.text == "道教典籍" })
        XCTAssertTrue(values.allSatisfy { $0.consumed > 0 && $0.consumed <= 4 })
        let chosen = values.first { $0.consumed < 4 }
        if let chosen {
            var composition = Composition()
            _ = composition.append("djdj")
            composition.consume(chosen.consumed)
            XCTAssertEqual(composition.raw, String("djdj".dropFirst(chosen.consumed)))
        }
    }
    func testImmediateWordsUseCurrentSpellingWithoutSentenceDecoding() {
        for (input, expected) in ["nihao": "你好", "shaod": "稍等", "chif": "吃饭", "laop": "老婆", "shangh": "上海", "iphone": "iphone"] {
            let values = engine.immediateCandidates(input)
            XCTAssertEqual(values.first?.text, expected, input)
            XCTAssertEqual(values.first?.consumed, input.count, input)
            XCTAssertLessThanOrEqual(values.count, 8)
        }
        let film = Candidate(text: "钢化膜", reading: "gang hua mo", consumed: 8)
        XCTAssertEqual(engine.immediateCandidates("ganghuam", preferred: [film]).first?.text, "钢化膜")
        // Unknown sentences stay with the mature decoder instead of inventing a
        // quick word by concatenating unrelated initials on the UI thread.
        XCTAssertTrue(engine.immediateCandidates("nichifankm").isEmpty)
        XCTAssertEqual(engine.candidates("nichifankm").first?.text, "你吃饭了吗")
    }
    func testShortInitialismsMissingFromTheSmallLexiconHaveImmediateWords() {
        for raw in ["d", "djdj"] {
            let values = engine.immediateCandidates(raw)
            XCTAssertFalse(values.isEmpty, raw)
            XCTAssertLessThanOrEqual(values.count, 8)
            XCTAssertTrue(values.allSatisfy { $0.consumed == raw.count })
            XCTAssertTrue(values.allSatisfy {
                let initials = $0.reading.split(separator: " ").compactMap(\.first).map(String.init).joined()
                return initials.hasPrefix(raw) && initials.count - raw.count <= 2
            })
        }
        XCTAssertEqual(engine.immediateCandidates("d").first?.text, "的")
        XCTAssertTrue(engine.candidates("djdj", limit: 64).contains { $0.text == "道教典籍" })
        XCTAssertTrue(engine.immediateCandidates("nichifankm").isEmpty,
                      "An unmatched sentence still belongs to the sentence decoder")
    }
    func testSentencesUseTheLanguageModel() {
        for (input, expected) in ["nichifanlema": "你吃饭了吗", "womenshiyongshurufa": "我们使用输入法",
                                  "womenjintianquchifan": "我们今天去吃饭", "woyaoshangke": "我要上课",
                                  "womenmingtianjian": "我们明天见", "jintianwanshangchishenme": "今天晚上吃什么",
                                  "wozaigongsi": "我在公司", "yetaiboli": "液态玻璃"] {
            let result = engine.candidates(input)
            XCTAssertEqual(result.first?.text, expected, input)
            XCTAssertEqual(result.first?.consumed, input.count, input)
        }
    }
    func testStrictMixedInitialWordsPrecedeCorrectionSentences() {
        for (input, expected) in ["laopcfm": "老婆吃饭没", "lpcfm": "老婆吃饭没",
                                  "laogcfm": "老公吃饭没", "baobeidjm": "宝贝到家没",
                                  "babaxbm": "爸爸下班没", "laopchifanma": "老婆吃饭吗"] {
            let values = engine.candidates(input)
            XCTAssertEqual(values.first?.text, expected, input)
            XCTAssertEqual(values.first?.consumed, input.count, input)
            XCTAssertFalse(values.prefix(3).contains { $0.text.contains("出轨") }, input)
            XCTAssertTrue(values.contains { $0.text == input })
        }
    }
    func testStrictPartialWordsDoNotHideFullSentenceCorrections() {
        XCTAssertTrue(engine.candidates("znl").contains { $0.text == "正能量" }, "Conversational priority must retain other literal choices")
        XCTAssertTrue(engine.candidates("zgm").contains { $0.text == "总规模" })
        for _ in 0..<2 {
            for (input, expected) in ["laopcfm": "老婆吃饭没", "nichifankm": "你吃饭了吗",
                                      "ganghuam": "钢化膜", "nichifankema": "你吃饭了吗",
                                      "nichifnalemeilaopo": "你吃饭了没老婆"] {
                XCTAssertEqual(engine.candidates(input).first?.text, expected, input)
            }
        }
    }
    func testCorrectionsAndMixedInitials() {
        for input in ["nichifankema", "nichifankm", "nichjfankema"] {
            XCTAssertEqual(engine.candidates(input).first?.text, "你吃饭了吗", input)
        }
        XCTAssertEqual(engine.candidates("nixiabankm").first?.text, "你下班了吗")
        for input in ["nichifnalemeilaopo", "nichifnlemeilaopo", "nichifqnlemeilaopo"] {
            XCTAssertEqual(engine.candidates(input).first?.text, "你吃饭了没老婆", input)
        }
    }
    func testPartialCandidatesCarryActualDecoderSpans() throws {
        let candidate = try XCTUnwrap(engine.candidates("nichifanlema").first { $0.text == "你吃饭了" })
        XCTAssertEqual(candidate.consumed, "nichifanle".count)
        let explicit = engine.candidates("xi'an")
        XCTAssertEqual(explicit.first?.text, "西安")
        XCTAssertEqual(explicit.first?.consumed, 4)
    }
    func testLiteralWordPrefixAndFinalInitialBeatUnrelatedInitials() {
        for (input, expected) in ["shaod": "稍等", "chif": "吃饭", "laop": "老婆", "shangh": "上海", "gongz": "工作"] {
            let values = engine.candidates(input)
            XCTAssertEqual(values.first?.text, expected, input)
            XCTAssertEqual(values.first?.consumed, input.count, input)
            XCTAssertTrue(values.contains { $0.text == input }, "Literal input remains selectable")
        }
        XCTAssertEqual(engine.candidates("shaodeng").first?.text, "稍等")
        XCTAssertEqual(engine.candidates("iphone").first?.text, "iphone")
        XCTAssertEqual(engine.candidates("nichifankm").first?.text, "你吃饭了吗")
    }
    func testChineseModePreservesRecognizedEnglishAndMixedTokens() {
        for word in ["iphone", "iPhone", "hello", "keyboard", "app"] { XCTAssertEqual(engine.candidates(word).first?.text, word, word) }
        XCTAssertEqual(engine.candidates("hello", compose: false).first?.text, "hello")
        XCTAssertEqual(engine.candidates("wodeiphone").first?.text, "我的iphone")
        XCTAssertEqual(engine.candidates("women").first?.text, "我们")
        XCTAssertEqual(engine.candidates("shanghai").first?.text, "上海")
        XCTAssertFalse(engine.candidates("nichifan").first!.text.contains("fan"))
    }
    func testOfflineContinuationAndLiteralChoice() {
        XCTAssertTrue(engine.predictions(after: "中华").contains { $0.text == "人民共和国" })
        XCTAssertFalse(engine.predictions(after: "今天").isEmpty)
        XCTAssertTrue(engine.candidates("nihao").contains { $0.text == "nihao" })
    }
    func testIncrementalDecodingIsCancellableAndInteractive() {
        var times: [Double] = []
        for input in ["nichifankm", "womenjintianquchifan", "nichjfankema"] {
            for length in 1...input.count {
                let start = ProcessInfo.processInfo.systemUptime
                _ = engine.candidates(String(input.prefix(length)))
                times.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            }
        }
        XCTAssertTrue(engine.candidates("nichifankm", cancelled: { true }).isEmpty)
        times.sort(); let p95 = times[Int(Double(times.count - 1) * 0.95)]
        print("RIME_CANDIDATE_LATENCY queries=\(times.count) p95Ms=\(p95) maxMs=\(times.last!)")
        XCTAssertLessThan(p95, 200)
    }
}
