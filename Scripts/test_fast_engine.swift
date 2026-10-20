import Foundation

@main struct FastEngineChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func main() throws {
        let engine = try InputEngine.bundled()
        var rows: [[String: Any]] = []
        for (unit, expected) in [("jd", "记得"), ("hd", "好的"), ("nh", "你好"), ("xx", "谢谢"), ("zj", "再见")] {
            for count in [3, 8, 64, 128] {
                let raw = String(repeating: unit, count: count), text = String(repeating: expected, count: count)
                let started = ProcessInfo.processInfo.systemUptime
                let words = engine.immediateCandidates(raw), head = engine.candidates(raw, limit: 9)
                let ms = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                require(words.first?.text == text && head.first?.text == text, "Fast and final repeat rows disagree")
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
        for raw in ["jtzgsm", "lzqnmd", "busuanchadla", "wogeimam", "mamncfm"] {
            rows.append(["input": raw, "head": engine.candidates(raw, limit: 9).map(\.text)])
        }
        print(String(data: try JSONSerialization.data(withJSONObject: ["status": "passed", "rows": rows,
            "scope": "macOS release, real Swift InputEngine and Rime; excludes UIKit, physical phone and display frame rate"], options: [.sortedKeys]), encoding: .utf8)!)
    }
}
