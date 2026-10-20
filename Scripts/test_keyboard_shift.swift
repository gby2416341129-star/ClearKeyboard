import Foundation

@main struct ShiftChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func main() throws {
        var checks = 0
        for start in [0.0, 1, 10_000] {
            var state = KeyboardShift()
            state.tap(now: start)
            check(state.shifted && !state.capsLocked, "A single Shift did not enable one literal capital")
            state.interruptTapSequence()
            if !state.capsLocked { state.shifted = false }
            check(!state.shifted && !state.capsLocked, "One letter did not restore ordinary pinyin entry")
            // A typed letter separates these physical taps even within 300 ms.
            state.tap(now: start + 0.1)
            check(state.shifted && !state.capsLocked, "Typing one capital accidentally locked the next Shift")
            state.tap(now: start + 0.2)
            check(state.shifted && state.capsLocked, "Two consecutive taps did not lock capitals")
            for _ in 0..<40 {
                state.interruptTapSequence()
                if !state.capsLocked { state.shifted = false }
                check(state.shifted && state.capsLocked, "A locked capital stopped after one letter")
                checks += 1
            }
            state.tap(now: start + 0.21)
            check(!state.shifted && !state.capsLocked, "A tap did not unlock capitals")
            state.tap(now: start + 0.22)
            check(state.shifted && !state.capsLocked, "A new tap inherited an obsolete double-tap sequence")
            state.reset()
            check(!state.shifted && !state.capsLocked, "A real language switch retained temporary case")
            state.tap(now: start + 1)
            state.tap(now: start + 2)
            check(!state.shifted && !state.capsLocked, "Two separated taps locked capitals")
            // English automatic capitalization uses the same ordinary case flag.
            state.shifted = true
            state.interruptTapSequence()
            state.tap(now: start + 3)
            check(!state.shifted && !state.capsLocked, "Shift could not cancel automatic capitalization")
            state.tap(now: start + 3.1)
            check(state.shifted && state.capsLocked, "An English auto-capitalized first letter broke double-tap caps lock")
            checks += 10
        }
        print("KEYBOARD_SHIFT_CHECKS passed checks=\(checks); single literal, consecutive double tap, unlock, intervening letter, reset, automatic case")
    }
}
