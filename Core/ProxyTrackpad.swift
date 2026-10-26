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
    private var previousTranslation = CGPoint.zero
    private var previousTime: TimeInterval?
    private var horizontalTravel: CGFloat = 0
    public init(before: String, after: String) {
        let chars = Array(before + after)
        count = chars.count; origin = before.count; current = before.count
        var lines: [(Int, Int)] = [], start = 0
        for (index, character) in chars.enumerated() where character.isNewline { lines.append((start, index)); start = index + 1 }
        lines.append((start, chars.count)); rows = lines
        originRow = lines.lastIndex(where: { $0.0 <= before.count }) ?? 0
        column = before.count - lines[originRow].0
    }
    public mutating func offset(translation: CGPoint, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int {
        guard translation.x.isFinite, translation.y.isFinite, now.isFinite else { return 0 }
        let dx = translation.x - previousTranslation.x
        let elapsed = previousTime.map { max(1.0 / 240, now - $0) } ?? (1.0 / 60)
        let speed = abs(dx) / elapsed
        // Slow drags retain fine control; a fast sweep crosses several graphemes
        // in one host edit. Never enqueue intermediate character positions.
        let gain = 1 + 0.85 * min(1, max(0, (speed - 180) / 720))
        horizontalTravel += dx / 6 * gain
        previousTranslation = translation; previousTime = now
        let vertical = Int(max(-10_000, min(10_000, translation.y / 24)))
        let lower = -origin
        let upper = count - origin
        // Discard overshoot at either edge, so reversing never has a dead zone.
        horizontalTravel = min(CGFloat(upper), max(CGFloat(lower), horizontalTravel))
        let horizontal = Int(horizontalTravel)
        let target: Int
        if vertical == 0 { target = min(count, max(0, origin + horizontal)) }
        else {
            let row = rows[min(rows.count - 1, max(0, originRow + vertical))]
            target = min(row.end, max(row.start, row.start + column + horizontal))
        }
        let delta = target - current; current = target; return delta
    }
}
