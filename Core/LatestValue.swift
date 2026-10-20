import Foundation

/// A display consumer keeps one pending value. Taking it is a barrier: values
/// submitted afterwards belong to the next frame, never to a queued old frame.
public struct LatestValue<Value> {
    private var value: Value?
    public var isPending: Bool { value != nil }
    public init() {}
    public mutating func replace(with next: Value) { value = next }
    public mutating func take() -> Value? {
        let next = value; value = nil; return next
    }
    public mutating func discard() { value = nil }
}

/// Sparse keys need no display wait. Only another host write within the same
/// refresh interval joins the next frame, so bursts leave time for drawing.
public struct FrameWriteCadence {
    private var lastWrite = -Double.infinity
    public init() {}
    public func canWriteImmediately(now: Double, maximumFramesPerSecond: Int) -> Bool {
        now - lastWrite >= 1 / Double(max(1, maximumFramesPerSecond))
    }
    public mutating func didWrite(now: Double) { lastWrite = now }
}
