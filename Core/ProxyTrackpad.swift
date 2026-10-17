import Foundation
import CoreGraphics

/// Public keyboard proxies expose text offsets, not a host's visual line geometry.
/// Vertical movement therefore follows explicit newline boundaries in the visible context.
public struct ProxyTrackpad {
    private let count: Int
    private let origin: Int
    private let rows: [(start: Int, end: Int)]
    private let originRow: Int
    private let column: Int
    private var current: Int
    public init(before: String, after: String) {
        let chars = Array(before + after)
        count = chars.count; origin = before.count; current = before.count
        var lines: [(Int, Int)] = [], start = 0
        for (index, character) in chars.enumerated() where character.isNewline { lines.append((start, index)); start = index + 1 }
        lines.append((start, chars.count)); rows = lines
        originRow = lines.lastIndex(where: { $0.0 <= before.count }) ?? 0
        column = before.count - lines[originRow].0
    }
    public mutating func offset(translation: CGPoint) -> Int {
        guard translation.x.isFinite, translation.y.isFinite else { return 0 }
        let horizontal = Int(max(-100_000, min(100_000, translation.x / 6)))
        let vertical = Int(max(-10_000, min(10_000, translation.y / 24)))
        let target: Int
        if vertical == 0 { target = min(count, max(0, origin + horizontal)) }
        else {
            let row = rows[min(rows.count - 1, max(0, originRow + vertical))]
            target = min(row.end, max(row.start, row.start + column + horizontal))
        }
        let delta = target - current; current = target; return delta
    }
}
