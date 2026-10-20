import Foundation
import CoreText

@main struct CandidateLayoutChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func main() throws {
        var checks = 0
        for viewportWidth in [CGFloat(320), 390, 440, 1024] {
            for height in [CGFloat(44), 52] {
                var layout = CandidateStripLayout()
                let widths = (0..<4095).map { CGFloat(46 + ($0 * 47) % 460) }
                var calls = 0
                func measure(_ index: Int) -> CGFloat { calls += 1; return widths[index] }
                let first = layout.extend(count: widths.count,
                    viewport: CGRect(x: 0, y: 0, width: viewportWidth, height: height), measure: measure)
                check(first <= 16 && first == calls, "First paint measured the whole candidate page")
                check(layout.width >= viewportWidth && layout.width < viewportWidth * 3 + 506, "First paint did not cover the viewport")
                var offset: CGFloat = 0
                while layout.frames.count < widths.count {
                    let oldFrames = layout.frames, oldCalls = calls
                    offset = min(offset + viewportWidth * 0.75, max(0, layout.width - viewportWidth))
                    layout.extend(count: widths.count,
                        viewport: CGRect(x: offset, y: 0, width: viewportWidth, height: height), measure: measure)
                    check(Array(layout.frames.prefix(oldFrames.count)) == oldFrames, "Appending moved a visible word")
                    check(calls - oldCalls <= 16, "Prefetch work grew with the page length")
                    check(layout.width >= offset + viewportWidth, "A normal scroll exposed an unmeasured gap")
                    checks += 1
                }
                check(calls == widths.count, "A word was measured repeatedly while scrolling")
                var x: CGFloat = 0
                for index in widths.indices {
                    check(layout.frames[index] == CGRect(x: x, y: 0, width: widths[index], height: height), "Lazy positions differ from eager positions")
                    check(layout.firstIndex(at: x + widths[index] / 2) == index, "Hit testing selected another word")
                    x += widths[index]; checks += 2
                }
                let beforeReverse = calls
                layout.extend(count: widths.count, viewport: CGRect(x: 0, y: 0, width: viewportWidth, height: height), measure: measure)
                check(calls == beforeReverse, "Reverse scrolling remeasured the prefix")
                layout.resize(height: 60)
                check(layout.frames.allSatisfy { $0.height == 60 }, "Resizing left old hit-test heights")
                layout.reset()
                layout.extend(count: 30, viewport: CGRect(x: 0, y: 0, width: viewportWidth, height: height), through: 29, measure: measure)
                check(layout.frames.count == 30, "An explicitly focused accessibility candidate has no exact frame")
            }
        }
        for points in [CGFloat(16), 19, 22, 25] {
            let font = CTFontCreateUIFontForLanguage(.system, points, nil)!
            let text = (0..<4095).map { "候选词\($0)" + ($0 % 9 == 0 ? String(repeating: "连续输入与候选词", count: 8) : "") }
            func width(_ index: Int) -> CGFloat {
                let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text[index], attributes: attributes) as CFAttributedString)
                return max(42, ceil(CTLineGetTypographicBounds(line, nil, nil, nil)) + 20) + 4
            }
            // Warm the font once for each comparison. This measures real text
            // shaping cost on macOS, not UIKit, GPU rendering, or iPhone FPS.
            _ = width(0)
            let oldStart = ProcessInfo.processInfo.systemUptime
            let eagerWidth = text.indices.reduce(CGFloat.zero) { $0 + width($1) }
            let eagerMS = (ProcessInfo.processInfo.systemUptime - oldStart) * 1000
            var layout = CandidateStripLayout(), measurements = 0
            let newStart = ProcessInfo.processInfo.systemUptime
            layout.extend(count: text.count, viewport: CGRect(x: 0, y: 0, width: 440, height: 44)) { index in
                measurements += 1; return width(index)
            }
            let lazyMS = (ProcessInfo.processInfo.systemUptime - newStart) * 1000
            check(measurements <= 16 && layout.width >= 440 && layout.width < eagerWidth, "Text shaping is not bounded to the viewport")
            print("CANDIDATE_LAYOUT_BENCH " + String(data: try JSONSerialization.data(withJSONObject:
                ["points": Double(points), "pageCandidates": text.count, "firstPaintMeasurements": measurements,
                 "eagerTextMS": eagerMS, "viewportTextMS": lazyMS,
                 "scope": "same macOS CoreText font and strings; layout and shaping only; not iPhone frame rate"],
                options: [.sortedKeys]), encoding: .utf8)!)
        }
        print("CANDIDATE_LAYOUT_CHECKS passed comparisons=\(checks); append, reverse, resize, hit testing, explicit accessibility focus")
    }
}
