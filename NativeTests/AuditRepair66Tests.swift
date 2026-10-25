import XCTest
import UIKit

@MainActor final class AuditRepair66Tests: XCTestCase {
    func testIndependentSettingsChangesMergeInEitherOrder() throws {
        var base = KeyboardSettings(), a = base, b = base
        a.keyColorHex = "#112233"; b.vibrationIntensity = 0.87
        let first = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: base, includeInputPreferences: true), updatedAt: Date(timeIntervalSince1970: 1))
        let color = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: a, includeInputPreferences: true), updatedAt: Date(timeIntervalSince1970: 2), changedFields: ["keyColorHex"])
        let haptic = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: b, includeInputPreferences: true), updatedAt: Date(timeIntervalSince1970: 3), changedFields: ["vibrationIntensity"])
        for records in [[first, color, haptic], [haptic, first, color]] {
            let merged = try XCTUnwrap(AppearanceEnvelope.reconciling(records))
            XCTAssertEqual(merged.snapshot.keyColorHex, "#112233"); XCTAssertEqual(merged.snapshot.vibrationIntensity, 0.87)
        }
        a.keyColorHex = nil
        let reset = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: a, includeInputPreferences: true), updatedAt: Date(timeIntervalSince1970: 4), changedFields: ["keyColorHex"])
        let merged = try XCTUnwrap(AppearanceEnvelope.reconciling([first, color, haptic, reset]))
        XCTAssertNil(merged.snapshot.keyColorHex); XCTAssertEqual(merged.snapshot.vibrationIntensity, 0.87)
    }
    func testLateBootstrapCannotOverwriteAUserEditAndPartialFirstWriteKeepsExistingSettings() throws {
        var prior = KeyboardSettings(); prior.keyHeight = 57
        var edited = prior; edited.keyColorHex = "#112233"
        let patch = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: edited, includeInputPreferences: true), updatedAt: Date(timeIntervalSince1970: 2), changedFields: ["keyColorHex"])
        let initial = try XCTUnwrap(AppearanceEnvelope.reconciling([patch]))
        XCTAssertEqual(initial.snapshot.keyHeight, 57)
        let boot = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: prior, includeInputPreferences: true), updatedAt: Date(timeIntervalSince1970: 3), fieldDates: Dictionary(uniqueKeysWithValues: AppearanceSnapshot.fieldNames.map { ($0, Date.distantPast) }))
        for records in [[patch, boot], [boot, patch], [initial, boot]] {
            let merged = try XCTUnwrap(AppearanceEnvelope.reconciling(records))
            XCTAssertEqual(merged.snapshot.keyColorHex, "#112233"); XCTAssertEqual(merged.snapshot.keyHeight, 57)
        }
    }
    func testIndependentKeychainWritersKeepBothSettingsChanges() throws {
        let service = "clear.repair66." + UUID().uuidString
        let first = AppearanceKeychainBackend(service: service, accessGroup: nil)
        let second = AppearanceKeychainBackend(service: service, accessGroup: nil)
        let account = AppearanceSyncClient.settingsAccount
        defer { _ = first.remove(account: account) }
        var a = KeyboardSettings(), b = a
        a.keyColorHex = "#112233"; b.vibrationIntensity = 0.87
        let color = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: a), updatedAt: Date(timeIntervalSince1970: 2), changedFields: ["keyColorHex"])
        let haptic = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: b), updatedAt: Date(timeIntervalSince1970: 3), changedFields: ["vibrationIntensity"])
        _ = try first.write(try AppearanceSyncClient.encode(color).get(), account: account).get()
        _ = try second.write(try AppearanceSyncClient.encode(haptic).get(), account: account).get()
        let data = try XCTUnwrap(first.read(account: account).get()?.data)
        let merged = try AppearanceSyncClient.decode(data).get()
        XCTAssertEqual(merged.snapshot.keyColorHex, "#112233"); XCTAssertEqual(merged.snapshot.vibrationIntensity, 0.87)
    }
    func testCoalescingDoesNotTurnBootstrapDefaultsIntoNewUserEdits() async throws {
        let backend = Repair66CaptureBackend()
        let link = AppearanceSettingsLink(role: .app, client: AppearanceSyncClient(backend: backend, coalesceInterval: 0.05), includeInputPreferences: true)
        defer { link.deactivate() }
        let initial = KeyboardSettings(); var color = initial; color.keyColorHex = "#112233"
        var haptic = color; haptic.vibrationIntensity = 0.87
        link.publish(initial); link.publish(color, previous: initial); link.publish(haptic, previous: color)
        for _ in 0..<200 { if backend.snapshot() != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let envelope = try AppearanceSyncClient.decode(XCTUnwrap(backend.snapshot())).get()
        XCTAssertEqual(envelope.fieldDates?["hand"], .distantPast)
        let colorDate = try XCTUnwrap(envelope.fieldDates?["keyColorHex"])
        XCTAssertGreaterThan(colorDate, .distantPast)
        XCTAssertGreaterThan(try XCTUnwrap(envelope.fieldDates?["vibrationIntensity"]), colorDate)
    }
    func testJournalCompactionKeepsOlderRealEditsAheadOfNewBootstrapValues() throws {
        let backend = AppearanceKeychainBackend(service: "clear.repair66.compaction." + UUID().uuidString, accessGroup: nil)
        let account = AppearanceSyncClient.settingsAccount
        defer { _ = backend.remove(account: account) }
        var color = KeyboardSettings(); color.keyColorHex = "#112233"; color.keyHeight = 57
        let edit = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: color), updatedAt: Date(timeIntervalSince1970: 1), changedFields: ["keyColorHex"])
        _ = try backend.write(try AppearanceSyncClient.encode(edit).get(), account: account).get()
        for index in 2...113 {
            var dates = Dictionary(uniqueKeysWithValues: AppearanceSnapshot.fieldNames.map { ($0, Date.distantPast) })
            dates["vibrationIntensity"] = Date(timeIntervalSince1970: Double(index))
            let patch = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: KeyboardSettings()), updatedAt: Date(timeIntervalSince1970: Double(index)), fieldDates: dates)
            _ = try backend.write(try AppearanceSyncClient.encode(patch).get(), account: account).get()
        }
        let data = try XCTUnwrap(backend.read(account: account).get()?.data)
        let snapshot = try AppearanceSyncClient.decode(data).get().snapshot
        XCTAssertEqual(snapshot.keyColorHex, "#112233"); XCTAssertEqual(snapshot.keyHeight, 57)
    }
    func testFirstPartialFileWriteRetainsItsFallbackWhenAnotherClientBootstraps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = AppearanceMirroredBackend(groupRoot: root, keychain: Repair66CaptureBackend())
        let account = AppearanceSyncClient.settingsAccount
        var custom = KeyboardSettings(); custom.keyHeight = 57; custom.keyColorHex = "#112233"
        let edit = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: custom), updatedAt: Date(timeIntervalSince1970: 2), changedFields: ["keyColorHex"])
        _ = try backend.write(try AppearanceSyncClient.encode(edit).get(), account: account).get()
        let boot = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: KeyboardSettings()), updatedAt: Date(timeIntervalSince1970: 3), fieldDates: Dictionary(uniqueKeysWithValues: AppearanceSnapshot.fieldNames.map { ($0, Date.distantPast) }))
        _ = try backend.write(try AppearanceSyncClient.encode(boot).get(), account: account).get()
        let record = try XCTUnwrap(backend.read(account: account).get())
        let snapshot = try AppearanceSyncClient.decode(record.data).get().snapshot
        XCTAssertEqual(snapshot.keyHeight, 57); XCTAssertEqual(snapshot.keyColorHex, "#112233")
    }
    func testChangingHapticsInsideAnEnglishFieldDoesNotChangeTheGlobalLanguage() throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        var settings = KeyboardSettings(); settings.language = .chinese; settings.automaticClipboard = false
        store.save(settings)
        let document = Repair66EnglishDocument()
        let model = KeyboardModel(document: document, defaults: defaults, wordLookup: { _, _, _ in [] })
        defer { model.suspend() }
        model.reloadSettings(); XCTAssertEqual(model.settings.language, .english)
        model.settings.vibrationEnabled = true; model.settings.vibrationIntensity = 0.87
        XCTAssertEqual(store.load().language, .chinese)
        XCTAssertEqual(store.load().resolvedVibrationIntensity, 0.87)
        XCTAssertEqual(model.settings.language, .english)
    }
    func testInvalidSettingsFieldIsRejected() {
        let bad = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: KeyboardSettings()), changedFields: ["unknown"])
        if case .success = AppearanceSyncClient.encode(bad) { XCTFail("Unknown field must not be persisted") }
    }
    func testLongArticleShapingCancelsAnObsoleteResult() {
        let preview = ClipboardInlinePreview(frame: CGRect(x: 0, y: 0, width: 220, height: 40))
        preview.show(String(repeating: "very long article 中文😀 ", count: 20000)); preview.show("新内容")
        let until = Date().addingTimeInterval(1)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        preview.layoutIfNeeded(); XCTAssertEqual(preview.text, "新内容"); XCTAssertTrue(preview.isReady)
        XCTAssertLessThanOrEqual(preview.contentSize.width, 220)
    }
    func testCapturedRevisionStaysSuppressedAcrossReactivation() throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = ClipboardObservation(defaults: defaults, owner: .keyboard)
        first.didCapture(changeCount: 72)
        let second = ClipboardObservation(defaults: defaults, owner: .keyboard)
        XCTAssertFalse(second.shouldRead(changeCount: 72, hasContent: true))
        XCTAssertTrue(second.shouldRead(changeCount: 73, hasContent: true))
    }
}
private final class Repair66CaptureBackend: AppearanceSyncBackend {
    var diagnostics = AppearanceBackendDiagnostics(configuredGroup: nil)
    private let lock = NSLock()
    private var data: Data?
    func snapshot() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func read(account: String) -> Result<AppearanceBackendRecord?, AppearanceSyncError> {
        .success(snapshot().map { AppearanceBackendRecord(data: $0, accessGroup: "fixture") })
    }
    func write(_ data: Data, account: String) -> Result<String?, AppearanceSyncError> {
        lock.lock(); self.data = data; lock.unlock(); return .success("fixture")
    }
}

@MainActor private final class Repair66EnglishDocument: KeyboardDocument {
    let contextBefore = "", contextAfter = "", selectedText = "", documentIdentity = UUID().uuidString
    let enterTitle = "换行", needsGlobe = false, fullAccess = false, prefersEnglish = true
    let capitalization = UITextAutocapitalizationType.none
    func insert(_ text: String) {}
    func deleteBackward() {}
    func moveCursor(_ offset: Int) {}
    func beginTrackpad() {}
    func trackCursor(translation: CGPoint) {}
    func endTrackpad() {}
    func nextKeyboard() {}
    func setMarkedText(_ text: String) {}
    func commitMarkedText(_ text: String) {}
    func unmarkText() {}
    func clearInput() -> DeletedInput? { nil }
    func restoreInput(_ value: DeletedInput) -> Bool { false }
}
