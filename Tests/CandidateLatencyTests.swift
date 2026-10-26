import XCTest
import CoreGraphics
import CoreText
@testable import ClearCore

final class FallbackCandidateLatencyTests: XCTestCase {
    func testCandidateRankingPreservesCommonWordsAndLongAbbreviations() throws {
        let engine = try InputEngine(chinese: .bundled("pinyin"), english: .bundled("english"))
        for (input, expected) in ["nihao": "你好", "nh": "你好", "hdhdhdhdhdhd": "好的好的好的好的好的好的",
                                  "womenshiyongshurufa": "我们使用输入法", "nihaohd": "你好好的",
                                  "xi'an": "西安", "haodehaodehaodehaode": "好的好的好的好的"] {
            XCTAssertEqual(engine.candidates(input).first?.text, expected, input)
        }
    }
    func testSpellingRepairIsBoundedAndCancellable() throws {
        let engine = try InputEngine(chinese: .bundled("pinyin"), english: .bundled("english"))
        XCTAssertEqual(PinyinSpelling.editPenalty("chifna", "chifan"), 1.5)
        XCTAssertEqual(PinyinSpelling.editPenalty("chifn", "chifan"), 3.5)
        XCTAssertLessThan(try XCTUnwrap(PinyinSpelling.editPenalty("ke", "le")), try XCTUnwrap(PinyinSpelling.editPenalty("ke", "de")))
        XCTAssertNil(PinyinSpelling.editPenalty("zzzz", "chifan"))
        let index = try PinyinCorrectionIndex.bundled(lexiconCount: engine.chinese.count)
        XCTAssertTrue(index.matches("kema", lexicon: engine.chinese).contains { $0.0.text == "了吗" })
        XCTAssertTrue(index.matches(String(repeating: "z", count: 14), lexicon: engine.chinese).isEmpty)
        var checks = 0
        XCTAssertTrue(engine.candidates("nichifnalemeilaopo", cancelled: { checks += 1; return checks > 35 }).isEmpty)
        XCTAssertEqual(engine.candidates("nichifnalemeilaopo").first?.text, "你吃饭了没老婆")
    }
    func testTypoCorrectionLatencyDuringIncrementalTyping() throws {
        let engine = try InputEngine(chinese: .bundled("pinyin"), english: .bundled("english"))
        let strings = ["nichifankema", "nichjfankema", "womenjintianquchifan", "nichifnalemeilaopo", "nichifankm", "nixiabankm"]
        var timings: [Double] = []
        for input in strings {
            for length in 1...input.count {
                let start = ProcessInfo.processInfo.systemUptime
                _ = engine.candidates(String(input.prefix(length)))
                timings.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            }
        }
        timings.sort()
        let p95 = timings[Int(Double(timings.count - 1) * 0.95)]
        print("TYPO_CANDIDATE_LATENCY queries=\(timings.count) p95Ms=\(p95) maxMs=\(timings.last!)")
        XCTAssertLessThan(p95, 200, "Bounded typo matching must remain interactive in a debug simulator build")
    }
    func testCancelledSentenceLeavesReusableCorrectPrefix() throws {
        let engine = try InputEngine(chinese: .bundled("pinyin"), english: .bundled("english"))
        var checks = 0
        _ = engine.candidates(String(repeating: "hd", count: 40), cancelled: { checks += 1; return checks > 35 })
        let text = String(repeating: "hd", count: 41)
        XCTAssertEqual(engine.candidates(text).first?.text, String(repeating: "好的", count: 41))
        XCTAssertEqual(engine.candidates("nihaoshijiehd").first, InputEngine(chinese: engine.chinese, english: engine.english).candidates("nihaoshijiehd").first)
    }
    func testIncrementalLatencyComparedWithPreviousSegmenter() throws {
        let engine = try InputEngine(chinese: .bundled("pinyin"), english: .bundled("english"))
        let strings = (2...80).map { String(String(repeating: "hd", count: 40).prefix($0)) }
        func timing(_ query: (String) -> [Candidate]) -> [Double] {
            strings.map { spelling in
                let start = ProcessInfo.processInfo.systemUptime; _ = query(spelling)
                return (ProcessInfo.processInfo.systemUptime - start) * 1_000
            }
        }
        // A single descheduled query can dominate a sub-100ms full trace on a
        // shared CI runner. Compare eight independent cold traces, alternate
        // execution order, and keep every sample rather than picking a best run.
        var previousTotals: [Double] = [], incrementalTotals: [Double] = [], samples: [Double] = []
        for trial in 0..<8 {
            let reference = ReferenceInputEngine(chinese: engine.chinese, english: engine.english)
            let incremental = InputEngine(chinese: engine.chinese, english: engine.english)
            let old: [Double], new: [Double]
            if trial.isMultiple(of: 2) {
                old = timing { reference.candidates($0) }; new = timing { incremental.candidates($0) }
            } else {
                new = timing { incremental.candidates($0) }; old = timing { reference.candidates($0) }
            }
            previousTotals.append(old.reduce(0,+)); incrementalTotals.append(new.reduce(0,+)); samples += new
        }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted(), middle = sorted.count / 2
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        let sorted = samples.sorted(), oldTotal = median(previousTotals), newTotal = median(incrementalTotals)
        let report: [String: Any] = ["queriesPerTrace": strings.count, "independentColdTraces": 8, "previousTraceTotalsMs": previousTotals, "incrementalTraceTotalsMs": incrementalTotals, "p50Ms": sorted[sorted.count/2], "p95Ms": sorted[Int(Double(sorted.count-1)*0.95)], "maxMs": sorted.last!, "medianTotalMs": newTotal, "previousSegmenterMedianTotalMs": oldTotal, "speedup": oldTotal/max(0.001,newTotal), "scope": "same host, same lexicon reader; alternating cold traces; median total comparison; all samples retained; not device touch latency"]
        print("CANDIDATE_LATENCY " + String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
        XCTAssertLessThan(newTotal, oldTotal * 0.8, "Incremental typing must reduce work compared with the previous segmenter")
    }
    func testProxyTrackpadExplicitRowsAndReversals() {
        var state = ProxyTrackpad(before: "abc\ndef", after: "\nghij")
        XCTAssertEqual(state.offset(translation: CGPoint(x: 0, y: -24)), -4)
        XCTAssertEqual(state.offset(translation: CGPoint(x: 0, y: 24)), 8)
        XCTAssertEqual(state.offset(translation: .zero), -4)
        XCTAssertEqual(state.offset(translation: CGPoint(x: -trackpadWidth("f"), y: 0)), -1)
        XCTAssertEqual(state.offset(translation: CGPoint(x: -.infinity, y: 0)), 0)
    }
    func testProxyTrackpadCountsComposedCharactersAndClamps() {
        var state = ProxyTrackpad(before: "a👨‍👩‍👧‍👦", after: "b")
        XCTAssertEqual(state.offset(translation: CGPoint(x: trackpadWidth("a") - trackpadWidth("a👨‍👩‍👧‍👦"), y: 0)), -1)
        XCTAssertEqual(state.offset(translation: CGPoint(x: 10000, y: 0)), 2)
        XCTAssertEqual(state.offset(translation: CGPoint(x: -10000, y: 0)), -3)
    }
    private func trackpadWidth(_ text: String) -> CGFloat {
        let font = CTFontCreateUIFontForLanguage(.system, 17, nil)!
        let value = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(value), nil, nil, nil))
    }
}
