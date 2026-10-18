import XCTest
@testable import ClearCore

final class MatureEngineTests: XCTestCase {
    private var engine: InputEngine!
    override func setUpWithError() throws { engine = try .bundled() }
    func testProductionUsesRimeAndWanxiang() { XCTAssertEqual(engine.chineseBackend, "rime-wanxiang") }
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
