import XCTest
import UIKit
@testable import ClearKeyboard

private final class ReceiverAppearanceBackend: ClearKeyboard.AppearanceSyncBackend {
    private let lock = NSLock()
    private var records: [String: Data] = [:]
    private var settingsCount = 0, receiptCount = 0
    private var touchedMainThread = false
    var counts: (settings: Int, receipts: Int, mainThread: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (settingsCount, receiptCount, touchedMainThread)
    }
    var revisions: (settings: UUID?, receipt: UUID?) {
        lock.lock(); defer { lock.unlock() }
        let settings = records[ClearKeyboard.AppearanceSyncClient.settingsAccount]
            .flatMap { try? ClearKeyboard.AppearanceSyncClient.decode($0).get().revision }
        let receipt = records[ClearKeyboard.AppearanceSyncClient.receiptAccount]
            .flatMap { try? ClearKeyboard.AppearanceSyncClient.decodeReceipt($0).get().revision }
        return (settings, receipt)
    }
    func read(account: String) -> Result<ClearKeyboard.AppearanceBackendRecord?, ClearKeyboard.AppearanceSyncError> {
        lock.lock(); defer { lock.unlock() }
        touchedMainThread = touchedMainThread || Thread.isMainThread
        return .success(records[account].map { ClearKeyboard.AppearanceBackendRecord(data: $0, accessGroup: "fixture.receiver.group") })
    }
    func write(_ data: Data, account: String) -> Result<String?, ClearKeyboard.AppearanceSyncError> {
        lock.lock(); defer { lock.unlock() }
        touchedMainThread = touchedMainThread || Thread.isMainThread
        records[account] = data
        if account == ClearKeyboard.AppearanceSyncClient.settingsAccount { settingsCount += 1 }
        if account == ClearKeyboard.AppearanceSyncClient.receiptAccount { receiptCount += 1 }
        return .success("fixture.receiver.group")
    }
}

@MainActor private final class ReceiverAppearanceDocument: ClearKeyboard.KeyboardDocument {
    private(set) var before = "", marked = ""
    let english: Bool
    init(english: Bool) { self.english = english }
    var contextBefore: String { before }
    var contextAfter: String { "" }
    let documentIdentity = UUID().uuidString
    var selectedText: String { "" }
    var enterTitle: String { "换行" }
    var needsGlobe: Bool { false }
    var fullAccess: Bool { true }
    var prefersEnglish: Bool { english }
    var capitalization: UITextAutocapitalizationType { .none }
    func insert(_ text: String) { before += text }
    func deleteBackward() { if !before.isEmpty { before.removeLast() } }
    func moveCursor(_ offset: Int) {}
    func beginTrackpad() {}
    func trackCursor(translation: CGPoint) {}
    func endTrackpad() {}
    func nextKeyboard() {}
    func setMarkedText(_ text: String) { before = String(before.dropLast(marked.count)) + text; marked = text }
    func commitMarkedText(_ text: String) { before = String(before.dropLast(marked.count)) + text; marked = "" }
    func unmarkText() { marked = "" }
    func clearInput() -> ClearKeyboard.DeletedInput? { nil }
    func restoreInput(_ value: ClearKeyboard.DeletedInput) -> Bool { false }
}

@MainActor private final class ReceiverAppearanceFixture {
    let appSuite: String, keyboardSuite: String
    let appDefaults: UserDefaults, keyboardDefaults: UserDefaults
    let backend: ReceiverAppearanceBackend
    let appClient: ClearKeyboard.AppearanceSyncClient
    let keyboardClient: ClearKeyboard.AppearanceSyncClient
    let appLink: ClearKeyboard.AppearanceSettingsLink
    let keyboardLink: ClearKeyboard.AppearanceSettingsLink
    let preferences: ClearKeyboard.Preferences
    let document: ReceiverAppearanceDocument
    let model: ClearKeyboard.KeyboardModel
    let surface: ClearKeyboard.KeyboardSurface
    let window: UIWindow
    init(english: Bool = false) throws {
        let appSuite = "clear.receiver.app." + UUID().uuidString
        let keyboardSuite = "clear.receiver.keyboard." + UUID().uuidString
        let appDefaults = try XCTUnwrap(UserDefaults(suiteName: appSuite))
        let keyboardDefaults = try XCTUnwrap(UserDefaults(suiteName: keyboardSuite))
        var initial = ClearKeyboard.KeyboardSettings()
        initial.automaticClipboard = false; initial.autoCapitalization = false
        initial.backgroundGlassStrength = 0.08; initial.keyGlassStrength = 0.08
        ClearKeyboard.SettingsStore(defaults: appDefaults).save(initial)
        ClearKeyboard.SettingsStore(defaults: keyboardDefaults).save(initial)
        let backend = ReceiverAppearanceBackend()
        let appClient = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0)
        let keyboardClient = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0)
        let appLink = ClearKeyboard.AppearanceSettingsLink(role: .app, client: appClient)
        let keyboardLink = ClearKeyboard.AppearanceSettingsLink(role: .keyboard, client: keyboardClient)
        let preferences = ClearKeyboard.Preferences(store: ClearKeyboard.SettingsStore(defaults: appDefaults), appearanceLink: appLink)
        let document = ReceiverAppearanceDocument(english: english)
        let model = ClearKeyboard.KeyboardModel(document: document, defaults: keyboardDefaults, appearanceLink: keyboardLink)
        let surface = ClearKeyboard.KeyboardSurface(model: model, systemBacked: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        self.appSuite = appSuite; self.keyboardSuite = keyboardSuite
        self.appDefaults = appDefaults; self.keyboardDefaults = keyboardDefaults
        self.backend = backend; self.appClient = appClient; self.keyboardClient = keyboardClient
        self.appLink = appLink; self.keyboardLink = keyboardLink
        self.preferences = preferences; self.document = document; self.model = model
        self.surface = surface; self.window = window
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        window.overrideUserInterfaceStyle = .dark
        let root = UIViewController(); window.rootViewController = root
        root.view.frame = window.bounds
        let scenery = CAGradientLayer(); scenery.frame = root.view.bounds
        scenery.colors = [UIColor.systemBlue.cgColor, UIColor.systemOrange.cgColor, UIColor.systemPurple.cgColor]
        scenery.startPoint = CGPoint(x: 0, y: 0); scenery.endPoint = CGPoint(x: 1, y: 1)
        root.view.layer.addSublayer(scenery)
        // Exercise the production system-backed surface, rather than the App preview.
        surface.frame = CGRect(x: 0, y: 250, width: 390, height: surface.desiredHeight)
        root.view.addSubview(surface); window.makeKeyAndVisible()
        window.layoutIfNeeded(); surface.layoutIfNeeded()
        preferences.activate()
    }
    func cleanUp() {
        preferences.deactivate(); keyboardLink.deactivate(); model.suspend(); window.isHidden = true
        appDefaults.removePersistentDomain(forName: appSuite)
        keyboardDefaults.removePersistentDomain(forName: keyboardSuite)
    }
}

@MainActor final class AppearanceReceiverRuntimeTests: XCTestCase {
    private enum FixtureFailure: Error { case timeout }
    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    private func visibleCandidateInk(_ fixture: ReceiverAppearanceFixture) -> [UILabel] {
        views(fixture.surface).compactMap { $0 as? UILabel }.filter { label in
            guard label.accessibilityIdentifier == "candidate.currentInk", label.window === fixture.window,
                  !label.bounds.isEmpty else { return false }
            var ancestor: UIView? = label
            while let view = ancestor {
                if view.isHidden || view.alpha == 0 { return false }
                if view === fixture.surface { break }
                ancestor = view.superview
            }
            return label.convert(label.bounds, to: fixture.surface).intersects(fixture.surface.bounds)
        }
    }
    private func waitFor(_ condition: () -> Bool, message: String) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail(message); throw FixtureFailure.timeout
    }
    private func synchronize(_ fixture: ReceiverAppearanceFixture) async throws {
        await withCheckedContinuation { continuation in fixture.appClient.flush { continuation.resume() } }
        fixture.keyboardLink.refresh()
        let expected = ClearKeyboard.AppearanceSnapshot(settings: fixture.preferences.settings)
        try await waitFor({ ClearKeyboard.AppearanceSnapshot(settings: fixture.model.settings) == expected },
                          message: "The independent keyboard model did not receive the App's appearance")
        try await waitFor({
            let revisions = fixture.backend.revisions
            return revisions.settings != nil && revisions.settings == revisions.receipt
        }, message: "The receiver did not acknowledge this revision")
        fixture.appLink.refresh()
        try await waitFor({ fixture.preferences.appearanceSyncStatus == .receivedByKeyboard },
                          message: "The production receiver did not acknowledge the applied appearance")
        fixture.surface.layoutIfNeeded()
    }
    private func prepare(_ fixture: ReceiverAppearanceFixture) async throws {
        XCTAssertTrue(fixture.surface.systemBacked)
        XCTAssertFalse(views(fixture.surface).contains { $0 is ClearKeyboard.KeyboardAppearancePreview })
        XCTAssertNotEqual(fixture.appSuite, fixture.keyboardSuite)
        try await waitFor({ fixture.backend.counts.settings > 0 }, message: "The App did not publish its initial appearance")
        try await synchronize(fixture)
    }
    private func pixels(_ fixture: ReceiverAppearanceFixture, surfaceRect: CGRect) throws -> Data {
        let rect = fixture.surface.convert(surfaceRect, to: fixture.window).integral.intersection(fixture.window.bounds)
        XCTAssertFalse(rect.isEmpty); XCTAssertFalse(rect.isNull)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds, format: format).image { _ in
            XCTAssertTrue(fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true))
        }
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: rect))
        return try XCTUnwrap(UIImage(cgImage: crop).pngData())
    }
    private func stablePixels(_ fixture: ReceiverAppearanceFixture, surfaceRect: CGRect) async throws -> Data {
        var previous: Data?
        for _ in 0..<16 {
            try await Task.sleep(nanoseconds: 30_000_000)
            fixture.window.layoutIfNeeded()
            let current = try pixels(fixture, surfaceRect: surfaceRect)
            if current == previous { return current }
            previous = current
        }
        XCTFail("The fixed keyboard crop did not settle before its appearance comparison")
        throw FixtureFailure.timeout
    }
    private func keyCrop(_ fixture: ReceiverAppearanceFixture) throws -> CGRect {
        let key = try XCTUnwrap(views(fixture.surface).compactMap { $0 as? ClearKeyboard.KeyButton }.first { $0.key.action == .text("q") })
        let face = try XCTUnwrap(views(key).first { $0.accessibilityIdentifier == "key.face" })
        // A key-face patch excludes changing letter ink and unrelated candidate text.
        return face.convert(CGRect(x: 4, y: 3, width: max(1, face.bounds.width - 8), height: 7), to: fixture.surface)
    }
    private func assertEdit(_ fixture: ReceiverAppearanceFixture, name: String, crop: CGRect,
                            edit: (inout ClearKeyboard.KeyboardSettings) -> Void) async throws {
        let before = try await stablePixels(fixture, surfaceRect: crop)
        var value = fixture.preferences.settings; edit(&value); fixture.preferences.settings = value
        try await synchronize(fixture)
        let after = try await stablePixels(fixture, surfaceRect: crop)
        XCTAssertNotEqual(after, before, "Only the setting changed; actual keyboard pixels did not: " + name)
        XCTAssertEqual(ClearKeyboard.SettingsStore(defaults: fixture.keyboardDefaults).load(), fixture.model.settings)
        XCTAssertFalse(fixture.backend.counts.mainThread, "Appearance transport must not run I/O on the key-event thread")
    }
    private func composeNihao(_ fixture: ReceiverAppearanceFixture) async throws {
        try await waitFor({ fixture.model.engineState == "离线就绪" }, message: "The production input engine did not load")
        for letter in "nihao" { fixture.model.handle(.text(String(letter))) }
        try await waitFor({ fixture.model.candidatesAreCurrent && !self.visibleCandidateInk(fixture).isEmpty },
                          message: "The real candidate strip did not display current Chinese candidates")
        XCTAssertEqual(fixture.model.composition.raw, "nihao")
    }
    func testIndependentAppAppearanceWritesChangeActualSystemBackedKeyboardPixels() async throws {
        XCTAssertFalse(UIAccessibility.isReduceTransparencyEnabled, "The material fixture requires transparency")
        XCTAssertFalse(ProcessInfo.processInfo.isLowPowerModeEnabled, "The material fixture requires its normal rendering branch")
        let fixture = try ReceiverAppearanceFixture(); defer { fixture.cleanUp() }
        try await prepare(fixture)
        let background = CGRect(x: 12, y: fixture.surface.bounds.height - 6, width: 366, height: 4)
        try await assertEdit(fixture, name: "background glass", crop: background) { $0.backgroundGlassStrength = 0.96 }
        let key = try keyCrop(fixture)
        try await assertEdit(fixture, name: "key glass", crop: key) { $0.keyGlassStrength = 0.96 }
        try await assertEdit(fixture, name: "background color", crop: background) { $0.backgroundColorHex = "#E3AC72" }
        try await assertEdit(fixture, name: "key color", crop: key) { $0.keyColorHex = "#292C39" }
        try await composeNihao(fixture)
        let label = try XCTUnwrap(visibleCandidateInk(fixture).first)
        let inkCrop = label.convert(label.bounds, to: fixture.surface)
        try await assertEdit(fixture, name: "candidate ink", crop: inkCrop) { $0.candidateColorHex = "#FF3399" }
        let expected = try XCTUnwrap(ClearKeyboard.KeyboardSettings.color(hex: "#FF3399"))
        let inks = visibleCandidateInk(fixture)
        XCTAssertFalse(inks.isEmpty)
        XCTAssertTrue(inks.allSatisfy { $0.textColor.isEqual(expected) })
        XCTAssertEqual(fixture.model.composition.raw, "nihao", "An appearance receive must not clear live pinyin")
    }
    func testIndependentAppMaterialSwitchesChangeActualKeyboardPixels() async throws {
        XCTAssertFalse(UIAccessibility.isReduceTransparencyEnabled)
        XCTAssertFalse(ProcessInfo.processInfo.isLowPowerModeEnabled)
        let fixture = try ReceiverAppearanceFixture(); defer { fixture.cleanUp() }
        try await prepare(fixture)
        let key = try keyCrop(fixture)
        for preset in [ClearKeyboard.GlassPreset.mist, .solid, .clear] {
            try await assertEdit(fixture, name: "material " + preset.rawValue, crop: key) { $0.glass = preset }
            XCTAssertEqual(fixture.model.settings.glass, preset)
        }
    }
    func testAppearanceReceiptPreservesLiveChineseCompositionAndDoesNotEchoWrites() async throws {
        let fixture = try ReceiverAppearanceFixture(); defer { fixture.cleanUp() }
        try await prepare(fixture); try await composeNihao(fixture)
        let count = fixture.backend.counts.settings
        fixture.preferences.settings.backgroundColorHex = "#558DF2"
        try await synchronize(fixture)
        XCTAssertEqual(fixture.model.composition.raw, "nihao")
        XCTAssertEqual(fixture.document.before, "nihao")
        XCTAssertEqual(fixture.model.settings.language, .chinese)
        XCTAssertEqual(fixture.backend.counts.settings, count + 1, "Receiving and acknowledging an App edit must not publish it again")
        let settled = fixture.backend.counts
        for _ in 0..<8 { fixture.keyboardLink.refresh(); fixture.appLink.refresh() }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(fixture.backend.counts.settings, settled.settings)
        XCTAssertEqual(fixture.backend.counts.receipts, settled.receipts, "Repeated refreshes must not create a receipt notification loop")
    }
    func testAppAppearanceDoesNotReplaceTheKeyboardEnglishLanguage() async throws {
        let fixture = try ReceiverAppearanceFixture(english: true); defer { fixture.cleanUp() }
        try await prepare(fixture)
        XCTAssertEqual(fixture.preferences.settings.language, .chinese)
        XCTAssertEqual(fixture.model.settings.language, .english)
        fixture.preferences.settings.keyColorHex = "#D799BC"
        try await synchronize(fixture)
        XCTAssertEqual(fixture.model.settings.keyColorHex, "#D799BC")
        XCTAssertEqual(fixture.model.settings.language, .english)
        XCTAssertEqual(fixture.preferences.settings.language, .chinese)
    }
    func testReceivingAppearanceKeepsNewerSavedInputPreferences() async throws {
        let fixture = try ReceiverAppearanceFixture(); defer { fixture.cleanUp() }
        try await prepare(fixture)
        for defaults in [fixture.appDefaults, fixture.keyboardDefaults] {
            let store = ClearKeyboard.SettingsStore(defaults: defaults)
            var saved = store.load(); saved.language = .english; saved.learnChoices = false; saved.predictions = false
            store.save(saved)
        }
        // The visible models intentionally still contain the previous input
        // preferences. Receiving appearance must not persist that stale state.
        let snapshot = ClearKeyboard.AppearanceSnapshot(settings: {
            var value = fixture.preferences.settings; value.backgroundColorHex = "#D799BC"; return value
        }())
        let envelope = ClearKeyboard.AppearanceEnvelope(snapshot: snapshot)
        await withCheckedContinuation { continuation in
            fixture.appClient.publish(envelope) { _ in continuation.resume() }
        }
        fixture.appLink.refresh(); fixture.keyboardLink.refresh()
        try await waitFor({ fixture.model.settings.backgroundColorHex == "#D799BC" && fixture.preferences.settings.backgroundColorHex == "#D799BC" }, message: "The external appearance did not reach both models")
        for defaults in [fixture.appDefaults, fixture.keyboardDefaults] {
            let saved = ClearKeyboard.SettingsStore(defaults: defaults).load()
            XCTAssertEqual(saved.language, .english); XCTAssertFalse(saved.learnChoices); XCTAssertFalse(saved.predictions)
        }
        XCTAssertEqual(fixture.model.settings.language, .chinese)
    }
    func testActiveAppReloadRestoresLatestAppearanceWithoutPublishingOldDefaults() async throws {
        let fixture = try ReceiverAppearanceFixture(); defer { fixture.cleanUp() }
        try await prepare(fixture)
        fixture.preferences.settings.backgroundColorHex = "#558DF2"
        try await synchronize(fixture)
        let writes = fixture.backend.counts.settings
        let store = ClearKeyboard.SettingsStore(defaults: fixture.appDefaults)
        var stale = store.load(); stale.backgroundColorHex = nil; store.save(stale)
        fixture.preferences.reload()
        try await waitFor({ fixture.preferences.settings.backgroundColorHex == "#558DF2" }, message: "An active App reload left the old defaults appearance visible")
        XCTAssertEqual(fixture.backend.counts.settings, writes, "A stale defaults observation must not become a new appearance revision")
    }
}
