import Foundation

/// Letter case is independent of the selected input language. Only consecutive
/// Shift taps lock capitals; a typed letter ends the double-tap sequence.
struct KeyboardShift {
    var shifted = false
    var capsLocked = false
    private var lastTap = -Double.infinity
    mutating func tap(now: Double) {
        if capsLocked {
            reset(); return
        }
        if shifted, now - lastTap >= 0, now - lastTap < 0.3 {
            capsLocked = true
        } else {
            shifted.toggle(); capsLocked = false
        }
        lastTap = now
    }
    mutating func interruptTapSequence() { lastTap = -Double.infinity }
    mutating func reset() { shifted = false; capsLocked = false; lastTap = -Double.infinity }
}
