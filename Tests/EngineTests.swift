import XCTest
@testable import ClearCore

final class FallbackEngineTests: XCTestCase {
    private var engine: InputEngine!
    override func setUpWithError() throws { engine = try InputEngine(chinese: .bundled("pinyin"), english: .bundled("english")) }
    func testBundledVocabulary() {
        XCTAssertEqual(engine.chinese.count, 65_137)
        XCTAssertEqual(engine.english.count, 50_000)
    }
    func testFullPinyin() {
        let candidates = engine.candidates("nihao")
        XCTAssertEqual(candidates.first?.text, "你好")
        XCTAssertEqual(candidates.first?.consumed, 5)
    }
    func testInitialAbbreviation() { XCTAssertTrue(engine.candidates("nh").contains { $0.text == "你好" }) }
    func testSupplementalVocabulary() { XCTAssertEqual(engine.candidates("yetaiboli").first?.text, "液态玻璃") }
    func testFuzzySpelling() { XCTAssertTrue(engine.candidates("zong", fuzzy: ["z/zh"]).contains { $0.text == "中" }) }
    func testExplicitSyllableBoundary() {
        let results = engine.candidates("xi'an")
        XCTAssertTrue(results.contains { $0.text == "西安" })
        XCTAssertFalse(results.contains { $0.text == "先" })
    }
    func testSentenceComposition() {
        let spelling = "womenshiyongshurufa"
        XCTAssertTrue(engine.candidates(spelling).contains { $0.consumed == spelling.count && $0.text.contains("输入法") })
    }
    func testWholeSentenceKeepsWordsInsteadOfStitchingUnrelatedInitials() {
        let cases = ["nichifanlemeilaopo": "你吃饭了没老婆",
                     "womenshiyongshurufa": "我们使用输入法",
                     "womenjintianquchifan": "我们今天去吃饭"]
        for (spelling, expected) in cases { XCTAssertEqual(engine.candidates(spelling).first?.text, expected, spelling) }
    }
    func testFastTypingTranspositionMissingLetterAndNearbyKey() {
        for spelling in ["nichifnalemeilaopo", "nichifnlemeilaopo", "nichifqnlemeilaopo"] {
            let values = engine.candidates(spelling)
            XCTAssertEqual(values.first?.text, "你吃饭了没老婆", spelling)
            XCTAssertEqual(values.first?.reading, "ni chi fan le mei lao po")
            XCTAssertEqual(values.first?.consumed, spelling.count)
            XCTAssertFalse(values.contains { $0.text.contains("妇女啊") })
        }
    }
    func testLegalPinyinTypoUsesSentenceRanking() {
        for spelling in ["nichifankema", "nichifamlema", "nichfanlema", "nichifnlema", "nichifnalema"] {
            let values = engine.candidates(spelling)
            XCTAssertEqual(values.first?.text, "你吃饭了吗", spelling)
            XCTAssertEqual(values.first?.reading, "ni chi fan le ma", spelling)
            XCTAssertEqual(values.first?.consumed, spelling.count, spelling)
        }
    }
    func testTwoIndependentTyposAreCorrectedWithoutASentenceSpecificEntry() {
        XCTAssertEqual(engine.candidates("nichjfankema").first?.text, "你吃饭了吗")
        XCTAssertEqual(engine.candidates("shangahi").first?.text, "上海")
        XCTAssertEqual(engine.candidates("shanghaai").first?.text, "上海")
        XCTAssertTrue(engine.chinese.lookup("e:nichifanlema").isEmpty, "The sentence must be decoded from words, not patched into the lexicon")
    }
    func testMixedFullPinyinAndInitialsWithAdjacentKeyErrors() {
        let cases = ["nichifankm": "你吃饭了吗", "nichifanlm": "你吃饭了吗",
                     "nchifanlm": "你吃饭了吗", "nichifanlma": "你吃饭了吗",
                     "nidaojiakm": "你到家了吗", "nixiabankm": "你下班了吗",
                     "nishuijiaokm": "你睡觉了吗", "wochifanlm": "我吃饭了吗"]
        for (input, expected) in cases {
            let values = engine.candidates(input)
            XCTAssertEqual(values.first?.text, expected, input)
            XCTAssertEqual(values.first?.consumed, input.count, input)
        }
        let values = engine.candidates("nichifankm")
        XCTAssertEqual(values.first?.reading, "ni chi fan le ma")
        XCTAssertTrue(values.contains { $0.text == "你吃饭昆明" })
        XCTAssertTrue(values.contains { $0.text == "你吃饭开门" })
        XCTAssertEqual(engine.candidates("kunming").first?.text, "昆明")
        XCTAssertEqual(engine.candidates("kaimen").first?.text, "开门")
    }
    func testMixedInitialTypingBackspaceAndCancellationRemainConsistent() {
        let spelling = "nichifankm"
        let prefixes = (1...spelling.count).map { String(spelling.prefix($0)) }
        for input in prefixes + Array(prefixes.reversed()) + ["nichifanlm", "nichifankm"] {
            let fresh = InputEngine(chinese: engine.chinese, english: engine.english)
            XCTAssertEqual(engine.candidates(input), fresh.candidates(input), input)
        }
        var checks = 0
        XCTAssertTrue(engine.candidates("nixiabankm", cancelled: { checks += 1; return checks > 70 }).isEmpty)
        XCTAssertEqual(engine.candidates("nixiabankm").first?.text, "你下班了吗")
    }
    func testTypoCandidatesKeepTheLiteralReadingAvailable() {
        let spelling = "nichifankema", values = engine.candidates(spelling)
        XCTAssertTrue(values.contains { $0.reading.replacingOccurrences(of: " ", with: "") == spelling })
        XCTAssertTrue(values.allSatisfy { $0.consumed == spelling.count })
    }
    func testCorrectSentencesAndNamesRemainStableWithCorrectionEnabled() {
        for (input, expected) in ["woyaoshangke": "我要上课", "nizainalishangke": "你在哪里上课",
                                  "woshilaoshi": "我是老师", "nishilaoshima": "你是老师吗",
                                  "woxiangqubeijing": "我想去北京", "woxihuanhecha": "我喜欢喝茶",
                                  "nikeyibangwoma": "你可以帮我吗", "womenmingtianjian": "我们明天见",
                                  "beijingdaxue": "北京大学", "nihaohd": "你好好的"] {
            XCTAssertEqual(engine.candidates(input).first?.text, expected, input)
        }
    }
    func testCancelledTypoSearchDoesNotCacheAnIncompleteResult() {
        var checks = 0
        XCTAssertTrue(engine.candidates("nichjfankema", cancelled: { checks += 1; return checks > 180 }).isEmpty)
        XCTAssertEqual(engine.candidates("nichjfankema").first?.text, "你吃饭了吗")
    }
    func testTypoTypingAndBackspaceMatchFreshQueries() {
        let spelling = "nichifankema"
        let prefixes = (1...spelling.count).map { String(spelling.prefix($0)) }
        for input in prefixes + Array(prefixes.reversed()) + ["nichifanlema", "nichifankema"] {
            let fresh = InputEngine(chinese: engine.chinese, english: engine.english)
            XCTAssertEqual(engine.candidates(input), fresh.candidates(input), input)
        }
    }
    func testIncompleteFinalSyllableKeepsSentenceCandidates() {
        for (spelling, expected) in ["chif": "吃饭", "laop": "老婆", "nichifanlemeilaop": "你吃饭了没老婆"] {
            XCTAssertEqual(engine.candidates(spelling).first?.text, expected, spelling)
            XCTAssertEqual(engine.candidates(spelling).first?.consumed, spelling.count)
        }
    }
    func testUnrepairableSpellingOffersARealPrefixInsteadOfInventedSentence() {
        let spelling = "nichifzzzzzalemeilaopo", values = engine.candidates(spelling)
        XCTAssertFalse(values.isEmpty)
        XCTAssertTrue(values.allSatisfy { $0.consumed < spelling.count })
        XCTAssertTrue(values.contains { $0.text == "你" && $0.consumed == 2 })
    }
    func testCompletedTailNeverPoisonsTheNextIncrementalQuery() throws {
        let spelling = "nichifanlemeilaopo"
        for length in 1...spelling.count {
            let prefix = String(spelling.prefix(length))
            let fresh = InputEngine(chinese: engine.chinese, english: engine.english)
            XCTAssertEqual(engine.candidates(prefix), fresh.candidates(prefix), prefix)
        }
    }
    func testValidPinyinIsNotSilentlyRewrittenAsASpellingRepair() {
        XCTAssertEqual(engine.candidates("nihao").first?.text, "你好")
        XCTAssertEqual(engine.candidates("xian").first?.reading.replacingOccurrences(of: " ", with: ""), "xian")
        XCTAssertTrue(engine.candidates("xi'an").allSatisfy { $0.reading.hasPrefix("xi an") })
        XCTAssertEqual(engine.candidates("nihaohd").first?.text, "你好好的")
    }
    func testChineseContinuation() { XCTAssertTrue(engine.predictions(after: "中华").contains { $0.text == "人民共和国" }) }
    func testEnglishCompletion() { XCTAssertTrue(engine.englishCandidates(prefix: "hell").contains { $0.text == "hello" }) }
    func testEnglishContinuation() { XCTAssertEqual(engine.englishPredictions(after: "thank ").first?.text, "you") }
    func testEmptyAndLongInput() {
        XCTAssertTrue(engine.candidates("").isEmpty)
        let raw = String(repeating: "haode", count: 100)
        let values = engine.candidates(raw)
        XCTAssertFalse(values.isEmpty)
        XCTAssertTrue(values.allSatisfy { $0.consumed > 0 && $0.consumed < raw.count })
    }
    func testContinuousAbbreviationsDoNotLoseCandidates() {
        for count in [2, 6, 12, 40] {
            let input = String(repeating: "hd", count: count)
            let results = engine.candidates(input)
            XCTAssertEqual(results.first?.text, String(repeating: "好的", count: count))
            XCTAssertEqual(results.first?.consumed, input.count)
        }
    }
    func testLongFullPinyinAndMixedAbbreviations() {
        let full = String(repeating: "haode", count: 15)
        XCTAssertTrue(engine.candidates(full).contains { $0.consumed == full.count && $0.text == String(repeating: "好的", count: 15) })
        XCTAssertTrue(engine.candidates("nihaohd").contains { $0.text == "你好好的" && $0.consumed == 7 })
    }
    func testIncrementalSentenceCacheMatchesFreshQueries() throws {
        for spelling in ["hdhdhdhdhdhdhd", "hdhdhdhdhdhd", "hdhdhdhdhdhdhdhd", "nihaonihaonihaonihaonihao"] {
            let fresh = InputEngine(chinese: engine.chinese, english: engine.english)
            XCTAssertEqual(engine.candidates(spelling), fresh.candidates(spelling))
        }
    }
    func testCancellation() { XCTAssertTrue(engine.candidates("zhongguo", cancelled: { true }).isEmpty) }
    func testCandidatesHaveUniqueText() {
        for input in ["a", "shi", "zhong", "nh", "nihao", "shurufa"] {
            let results = engine.candidates(input)
            XCTAssertEqual(results.count, Set(results.map(\.text)).count)
            XCTAssertLessThanOrEqual(results.count, 24)
        }
    }
    func testCorruptLexiconIsRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a lexicon".utf8).write(to: url)
        XCTAssertThrowsError(try Lexicon(url: url))
    }
}
