import Foundation

@main struct ClipboardObservationChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func main() {
        let suite = "clear.clipboard.observation.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Reproduce the previous shared-counter failure: a keyboard attempt,
        // including a refusal, must leave the app's first attempt available.
        defaults.set(7, forKey: "clear.clipboard.observedChangeCount.v1")
        let keyboard = ClipboardObservation(defaults: defaults, owner: .keyboard)
        let app = ClipboardObservation(defaults: defaults, owner: .app)
        require(keyboard.shouldRead(changeCount: 7, hasContent: true), "The legacy counter hid the keyboard attempt")
        keyboard.didAttempt(changeCount: 7)
        require(app.shouldRead(changeCount: 7, hasContent: true), "The extension suppressed the app's permission opportunity")
        require(!app.shouldRead(changeCount: 7, hasContent: false), "An empty clipboard triggered an attempt")
        require(app.shouldRead(changeCount: 7, hasContent: true), "Empty metadata consumed the first real read")
        app.didAttempt(changeCount: 7)
        require(!app.shouldRead(changeCount: 7, hasContent: true), "One copy caused repeated reads")
        require(!keyboard.shouldRead(changeCount: 7, hasContent: true), "One owner's read invalidated the other owner's counter")
        require(app.shouldRead(changeCount: 8, hasContent: true), "A later copy did not become readable")
        app.didAttempt(changeCount: 8)
        app.retry()
        require(app.shouldRead(changeCount: 8, hasContent: true), "Returning from Settings could not retry")
        app.didAttempt(changeCount: 8)
        require(!app.shouldRead(changeCount: 8, hasContent: true), "Retry read the same version twice")
        require(!keyboard.shouldRead(changeCount: 7, hasContent: true), "An app retry reset the keyboard")
        let resumedApp = ClipboardObservation(defaults: defaults, owner: .app)
        require(!resumedApp.shouldRead(changeCount: 8, hasContent: true), "Relaunch forgot a denied or completed attempt")
        print("PASS: separate app/keyboard attempts, legacy migration, empty clipboard, deduplication and one-shot Settings retry; no iOS permission UI claim")
    }
}
