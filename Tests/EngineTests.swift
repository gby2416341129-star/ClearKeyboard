import XCTest
@testable import ClearCore

final class EngineTests: XCTestCase {
    private var engine: InputEngine!
    override func setUpWithError() throws { engine = try InputEngine.bundled() }
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
    func testChineseContinuation() { XCTAssertTrue(engine.predictions(after: "中华").contains { $0.text == "人民共和国" }) }
    func testEnglishCompletion() { XCTAssertTrue(engine.englishCandidates(prefix: "hell").contains { $0.text == "hello" }) }
    func testEnglishContinuation() { XCTAssertEqual(engine.englishPredictions(after: "thank ").first?.text, "you") }
    func testEmptyAndOverlongInput() { XCTAssertTrue(engine.candidates("").isEmpty); XCTAssertTrue(engine.candidates(String(repeating: "a", count: Composition.maximumLength + 1)).isEmpty) }
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
