import Foundation
import CoreGraphics
import CoreText

@main enum TrackpadRepairCheck {
    static func main() {
        var fast = ProxyTrackpad(before: "12345678", after: "")
        precondition(fast.offset(translation: .zero, now: 0) == 0)
        // One finger update jumps directly from 8 to 2; no six-edit queue.
        let jump = advance("345678")
        precondition(fast.offset(translation: CGPoint(x: -jump, y: 0), now: 0.02) == -6)
        precondition(fast.offset(translation: CGPoint(x: -jump + advance("3"), y: 0), now: 0.22) == 1)
        var precise = ProxyTrackpad(before: "12345678", after: "")
        _ = precise.offset(translation: .zero, now: 0)
        let step = advance("8")
        precondition(precise.offset(translation: CGPoint(x: -step, y: 0), now: 0.2) == -1)
        precondition(precise.offset(translation: CGPoint(x: -step * 2, y: 0), now: 0.4) == -1)
        precondition(precise.offset(translation: CGPoint(x: -step, y: 0), now: 0.6) == 1)
        _ = precise.offset(translation: CGPoint(x: -1000, y: 0), now: 0.8)
        precondition(precise.offset(translation: CGPoint(x: -1000 + step, y: 0), now: 1) == 1)
        precondition(precise.offset(translation: CGPoint(x: CGFloat.nan, y: 0), now: 2) == 0)
        var lines = ProxyTrackpad(before: "abc\ndef\nxyz", after: "")
        precondition(lines.offset(translation: CGPoint(x: 0, y: -24), now: 0) == -4)
        precondition(lines.offset(translation: .zero, now: 1) == 4)
        var unicode = ProxyTrackpad(before: "A👨‍👩‍👧‍👦é中", after: "🇨🇳Z")
        _ = unicode.offset(translation: .zero, now: 0)
        let text = "A👨‍👩‍👧‍👦é中"
        precondition(unicode.offset(translation: CGPoint(x: advance("A👨‍👩‍👧‍👦") - advance(text), y: 0), now: 1) == -2)
        precondition(unicode.offset(translation: .zero, now: 2) == 2)
        print("Trackpad: direct jump, precise reversal, bounds, multiline and grapheme offsets passed")
    }
    static func advance(_ text: String) -> CGFloat {
        let font = CTFontCreateUIFontForLanguage(.system, 17, nil)!
        let value = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(value), nil, nil, nil))
    }
}
