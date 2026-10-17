import XCTest
import CoreGraphics
@testable import ClearCore

final class CandidateLatencyTests: XCTestCase {
    func testOptimizedCandidatesKeepReferenceResults() throws {
        let engine = try InputEngine.bundled()
        let reference = ReferenceInputEngine(chinese: engine.chinese, english: engine.english)
        for input in ["nihao", "nh", "hdhdhdhdhdhd", "womenshiyongshurufa", "nihaohd", "xi'an", "zhongguoren", "haodehaodehaodehaode", "wmsysrf"] {
            XCTAssertEqual(engine.candidates(input).first, reference.candidates(input).first, input)
        }
    }
    func testCancelledSentenceLeavesReusableCorrectPrefix() throws {
        let engine = try InputEngine.bundled()
        var checks = 0
        _ = engine.candidates(String(repeating: "hd", count: 40), cancelled: { checks += 1; return checks > 35 })
        let text = String(repeating: "hd", count: 41)
        XCTAssertEqual(engine.candidates(text).first?.text, String(repeating: "好的", count: 41))
        XCTAssertEqual(engine.candidates("nihaoshijiehd").first, InputEngine(chinese: engine.chinese, english: engine.english).candidates("nihaoshijiehd").first)
    }
    func testIncrementalLatencyComparedWithPreviousSegmenter() throws {
        let engine = try InputEngine.bundled()
        let reference = ReferenceInputEngine(chinese: engine.chinese, english: engine.english)
        let strings = (2...80).map { String(String(repeating: "hd", count: 40).prefix($0)) }
        func timing(_ query: (String) -> [Candidate]) -> [Double] {
            strings.map { spelling in
                let start = ProcessInfo.processInfo.systemUptime; _ = query(spelling)
                return (ProcessInfo.processInfo.systemUptime - start) * 1_000
            }
        }
        let old = timing { reference.candidates($0) }, new = timing { engine.candidates($0) }
        let sorted = new.sorted(), oldTotal = old.reduce(0,+), newTotal = new.reduce(0,+)
        let report: [String: Any] = ["queries": strings.count, "p50Ms": sorted[sorted.count/2], "p95Ms": sorted[Int(Double(sorted.count-1)*0.95)], "maxMs": sorted.last!, "totalMs": newTotal, "previousSegmenterTotalMs": oldTotal, "speedup": oldTotal/max(0.001,newTotal), "scope": "same host, same current lexicon reader; previous segmentation code versus optimized code; not device touch latency"]
        print("CANDIDATE_LATENCY " + String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
        XCTAssertLessThan(newTotal, oldTotal * 0.8, "Incremental typing must reduce work compared with the previous segmenter")
    }
    func testProxyTrackpadExplicitRowsAndReversals() {
        var state = ProxyTrackpad(before: "abc\ndef", after: "\nghij")
        XCTAssertEqual(state.offset(translation: CGPoint(x: 0, y: -24)), -4)
        XCTAssertEqual(state.offset(translation: CGPoint(x: 0, y: 24)), 8)
        XCTAssertEqual(state.offset(translation: .zero), -4)
        XCTAssertEqual(state.offset(translation: CGPoint(x: -6, y: 0)), -1)
        XCTAssertEqual(state.offset(translation: CGPoint(x: -.infinity, y: 0)), 0)
    }
    func testProxyTrackpadCountsComposedCharactersAndClamps() {
        var state = ProxyTrackpad(before: "a👨‍👩‍👧‍👦", after: "b")
        XCTAssertEqual(state.offset(translation: CGPoint(x: -6, y: 0)), -1)
        XCTAssertEqual(state.offset(translation: CGPoint(x: 10000, y: 0)), 2)
        XCTAssertEqual(state.offset(translation: CGPoint(x: -10000, y: 0)), -3)
    }
}
