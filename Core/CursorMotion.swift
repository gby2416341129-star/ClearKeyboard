import Foundation
import CoreGraphics

/// Fractional travel is retained, so small reversals and slow drags do not get lost.
public struct CursorMotion {
    private var remainder: CGFloat = 0
    public init() {}
    public mutating func reset() { remainder = 0 }
    public mutating func advance(points: CGFloat) -> Int {
        guard points.isFinite else { return 0 }
        remainder += points
        let steps = Int(remainder / 4.5)
        remainder -= CGFloat(steps) * 4.5
        return steps
    }
}
