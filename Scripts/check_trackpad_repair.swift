import Foundation
import CoreGraphics

@main enum TrackpadRepairCheck {
    static func main() {
        var fast = ProxyTrackpad(before: "12345678", after: "")
        precondition(fast.offset(translation: .zero, now: 0) == 0)
        // One finger update jumps directly from 8 to 2; no six-edit queue.
        precondition(fast.offset(translation: CGPoint(x: -20, y: 0), now: 0.02) == -6)
        precondition(fast.offset(translation: CGPoint(x: -14, y: 0), now: 0.22) == 1)
        var precise = ProxyTrackpad(before: "12345678", after: "")
        _ = precise.offset(translation: .zero, now: 0)
        precondition(precise.offset(translation: CGPoint(x: -6, y: 0), now: 0.2) == -1)
        precondition(precise.offset(translation: CGPoint(x: -12, y: 0), now: 0.4) == -1)
        precondition(precise.offset(translation: CGPoint(x: -6, y: 0), now: 0.6) == 1)
        _ = precise.offset(translation: CGPoint(x: -1000, y: 0), now: 0.8)
        precondition(precise.offset(translation: CGPoint(x: -994, y: 0), now: 1) == 1)
        precondition(precise.offset(translation: CGPoint(x: CGFloat.nan, y: 0), now: 2) == 0)
        var lines = ProxyTrackpad(before: "abc\ndef\nxyz", after: "")
        precondition(lines.offset(translation: CGPoint(x: 0, y: -24), now: 0) == -4)
        precondition(lines.offset(translation: .zero, now: 1) == 4)
        var unicode = ProxyTrackpad(before: "A👨‍👩‍👧‍👦é中", after: "🇨🇳Z")
        _ = unicode.offset(translation: .zero, now: 0)
        precondition(unicode.offset(translation: CGPoint(x: -12, y: 0), now: 1) == -2)
        precondition(unicode.offset(translation: .zero, now: 2) == 2)
        print("Trackpad: direct jump, precise reversal, bounds, multiline and grapheme offsets passed")
    }
}
