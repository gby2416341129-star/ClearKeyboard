import Foundation
import CoreGraphics
import CoreText

/// The remote editor exposes offsets, not its caret rectangles. Shape the
/// available context once to give the finger a stable, proportional text plane.
/// Each sample picks a target on that plane; it never integrates character steps
/// or velocity. Only explicit newlines are used: host soft wraps are not public.
public struct ProxyTrackpad {
    private struct Row {
        let start: Int
        let stops: [CGFloat]
        var minimum: CGFloat { stops.min() ?? 0 }
        var maximum: CGFloat { stops.max() ?? 0 }
        func position(at x: CGFloat) -> Int {
            // Bidi runs can have nonmonotonic positions. Search legal grapheme
            // stops rather than splitting a glyph or assuming uniform cells.
            let index = stops.indices.min { abs(stops[$0] - x) < abs(stops[$1] - x) } ?? 0
            return start + index
        }
    }
    private let origin: Int
    private let originRow: Int
    private let originX: CGFloat
    private let rows: [Row]
    private let utf16Stops: [Int]
    private var current: Int
    private var previousTranslation = CGPoint.zero
    private var horizontalOverflow: CGFloat = 0
    public private(set) var utf16Offset = 0
    public var displacement: Int { current - origin }
    public init(before: String, after: String) {
        let chars = Array(before + after)
        let anchor = min(chars.count, before.count)
        origin = anchor; current = anchor
        var units = [0]
        for char in chars { units.append(units.last! + String(char).utf16.count) }
        utf16Stops = units
        let font = CTFontCreateUIFontForLanguage(.system, 17, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 17, nil)
        var lines: [Row] = [], start = 0
        func append(_ end: Int) {
            let text = String(chars[start..<end])
            let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let line = CTLineCreateWithAttributedString(attributed)
            let stops = (start...end).map { CTLineGetOffsetForStringIndex(line, units[$0] - units[start], nil) }
            lines.append(Row(start: start, stops: stops))
        }
        for (index, character) in chars.enumerated() where character.isNewline { append(index); start = index + 1 }
        append(chars.count); rows = lines
        let row = lines.lastIndex(where: { $0.start <= anchor }) ?? 0
        originRow = row; originX = lines[row].stops[anchor - lines[row].start]
    }
    public mutating func offset(translation: CGPoint, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int {
        utf16Offset = 0
        guard translation.x.isFinite, translation.y.isFinite, now.isFinite else { return 0 }
        let vertical = Int(max(-10_000, min(10_000, (translation.y / 24).rounded())))
        let row = rows[min(rows.count - 1, max(0, originRow + vertical))]
        let x = originX + translation.x - horizontalOverflow
        let clamped = min(row.maximum, max(row.minimum, x))
        let dx = translation.x - previousTranslation.x
        // Discard horizontal travel beyond an edge for immediate reversal, but
        // retain the desired column when moving vertically onto a shorter row.
        if (x < row.minimum && dx < 0) || (x > row.maximum && dx > 0) {
            horizontalOverflow += x - clamped
        }
        previousTranslation = translation
        let target = row.position(at: clamped)
        let delta = target - current
        utf16Offset = utf16Stops[target] - utf16Stops[current]
        current = target; return delta
    }
}
