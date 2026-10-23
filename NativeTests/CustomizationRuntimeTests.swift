import XCTest
import SwiftUI
import Combine
import UIKit
@testable import ClearKeyboard

@MainActor final class CustomizationRuntimeTests: XCTestCase {
    private func makePreferences(_ defaults: UserDefaults) -> ClearKeyboard.Preferences {
        let store = ClearKeyboard.SettingsStore(defaults: defaults)
        var settings = ClearKeyboard.KeyboardSettings(); settings.automaticClipboard = false; store.save(settings)
        return ClearKeyboard.Preferences(store: store)
    }
    func testEveryCustomizationSettingPublishesOnceAndPersists() throws {
        let suite = "clear.custom.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = makePreferences(defaults)
        preferences.activate(); defer { preferences.deactivate() }
        var changes = 0
        let subscription = preferences.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        for index in 0..<60 {
            preferences.settings.glass = index.isMultiple(of: 2) ? .mist : .clear
            preferences.settings.keyGlassStrength = Double(index % 80 + 15) / 100
            preferences.settings.keyHeight = Double(44 + index % 15)
            preferences.settings.hand = index.isMultiple(of: 2) ? .left : .right
            preferences.settings.haptics.toggle()
            preferences.settings.customAccentHex = index.isMultiple(of: 2) ? "#F80" : "#17B890"
            preferences.settings.toolbar = [.clipboard, .emoji, .appearance]
            XCTAssertEqual(ClearKeyboard.SettingsStore(defaults: defaults).load(), preferences.settings)
        }
        XCTAssertGreaterThan(changes, 300)
        XCTAssertLessThanOrEqual(changes, 420, "A setting write must not publish recursively")
        let before = changes
        preferences.reload(); preferences.settings = preferences.settings
        XCTAssertEqual(changes, before, "Identical settings should not republish")
    }
    func testBindingsNormalizeBeforePublishing() throws {
        let suite = "clear.binding.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = makePreferences(defaults)
        let root = Binding(get: { preferences.settings }, set: { preferences.settings = $0 })
        root.keyHeight.wrappedValue = 500
        root.keyGlassStrength.wrappedValue = -Double.infinity
        root.customAccentHex.wrappedValue = "#abc"
        root.toolbar.wrappedValue = [.clipboard, .clipboard, .emoji]
        XCTAssertEqual(preferences.settings.keyHeight, 58)
        XCTAssertNil(preferences.settings.keyGlassStrength)
        XCTAssertEqual(preferences.settings.customAccentHex, "#AABBCC")
        XCTAssertEqual(preferences.settings.toolbar, [.language, .clipboard, .emoji])
        XCTAssertEqual(ClearKeyboard.SettingsStore(defaults: defaults).load(), preferences.settings)
    }
    func testPreferencesReloadNormalizesInMemoryWithoutWritingBackSavedData() throws {
        let suite = "clear.preferences.reload." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = makePreferences(defaults)
        var raw = ClearKeyboard.KeyboardSettings()
        raw.automaticClipboard = false; raw.keyHeight = 500
        raw.customAccentHex = "#abc"
        raw.keyColorHex = "#fed"; raw.candidateColorHex = "#456"
        let savedData = try JSONEncoder().encode(raw)
        defaults.set(savedData, forKey: ClearKeyboard.SettingsStore.key)
        var normalized = raw; normalized.sanitize()
        XCTAssertNotEqual(savedData, try JSONEncoder().encode(normalized), "The fixture must distinguish a read from a normalized rewrite")

        for _ in 0..<2 {
            preferences.reload()
            XCTAssertEqual(preferences.settings, normalized)
            XCTAssertEqual(preferences.settings.keyHeight, 58)
            XCTAssertEqual(preferences.settings.keyColorHex, "#FFEEDD")
            XCTAssertEqual(defaults.data(forKey: ClearKeyboard.SettingsStore.key), savedData,
                           "Observing saved App settings must not echo a normalized snapshot back into the store")
        }
    }
    func testKeyboardReloadNormalizesInMemoryWithoutWritingBackSavedData() throws {
        let suite = "clear.keyboard.reload." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = CustomizationReloadDocument()
        var initial = ClearKeyboard.KeyboardSettings(); initial.automaticClipboard = false
        let model = ClearKeyboard.KeyboardModel(document: document, settings: initial, defaults: defaults)
        defer { model.suspend() }
        var raw = ClearKeyboard.KeyboardSettings()
        raw.automaticClipboard = false; raw.keyHeight = 500
        raw.customAccentHex = "#abc"
        raw.keyColorHex = "#fed"; raw.candidateColorHex = "#456"
        let savedData = try JSONEncoder().encode(raw)
        defaults.set(savedData, forKey: ClearKeyboard.SettingsStore.key)
        var normalized = raw; normalized.sanitize(); normalized.language = .english
        XCTAssertNotEqual(savedData, try JSONEncoder().encode(normalized), "The fixture must distinguish a read from a normalized rewrite")

        for _ in 0..<2 {
            model.reloadSettings()
            XCTAssertEqual(model.settings, normalized)
            XCTAssertEqual(model.settings.keyHeight, 58)
            XCTAssertEqual(model.settings.candidateColorHex, "#445566")
            XCTAssertEqual(model.settings.language, .english, "Host language traits may affect the local view without becoming a settings edit")
            XCTAssertEqual(defaults.data(forKey: ClearKeyboard.SettingsStore.key), savedData,
                           "Reading saved keyboard settings or applying host traits must not rewrite the source snapshot")
        }
    }
    func testAppAndKeyboardUseTheSameAccessibleSharedSettingsGroup() throws {
        let group = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "ClearAppGroup") as? String)
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let urls = try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
        let extensionURL = try XCTUnwrap(urls.first { $0.pathExtension == "appex" })
        let keyboard = try XCTUnwrap(Bundle(url: extensionURL))
        XCTAssertEqual(keyboard.object(forInfoDictionaryKey: "ClearAppGroup") as? String, group)
        XCTAssertNotNil(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group))
        let independentReader = try XCTUnwrap(UserDefaults(suiteName: group))
        let selected = ClearKeyboard.SharedStorage.defaults(allowShared: true)
        let key = "clear.shared.integration." + UUID().uuidString
        defer { selected.removeObject(forKey: key); independentReader.removeObject(forKey: key) }
        selected.set("from-app", forKey: key)
        XCTAssertEqual(independentReader.string(forKey: key), "from-app", "App writes must reach the suite used by its keyboard")
        independentReader.set("from-keyboard", forKey: key)
        XCTAssertEqual(selected.string(forKey: key), "from-keyboard", "Reloads must read the shared suite rather than process-local preferences")
    }
    func testLocalFallbackMigrationPreservesSharedValuesAndRunsOnlyOnce() throws {
        let oldSuite = "clear.migration.old." + UUID().uuidString, sharedSuite = "clear.migration.shared." + UUID().uuidString
        let source = try XCTUnwrap(UserDefaults(suiteName: oldSuite)), destination = try XCTUnwrap(UserDefaults(suiteName: sharedSuite))
        defer { source.removePersistentDomain(forName: oldSuite); destination.removePersistentDomain(forName: sharedSuite) }
        let learning = ["clear.learned.v1", "clear.choices.v2", "clear.numbers.v1", "clear.learned.epoch"]
        source.set(Data([1, 2, 3]), forKey: "clear.settings.v1")
        for key in learning { source.set("legacy-" + key, forKey: key) }
        destination.set(Data([4, 5]), forKey: "clear.settings.v1")
        destination.set("shared-numbers", forKey: "clear.numbers.v1")
        ClearKeyboard.SharedStorage.migrateLegacyDefaults(from: source, to: destination, groupIdentifier: "first")
        XCTAssertEqual(destination.data(forKey: "clear.settings.v1"), Data([4, 5]))
        XCTAssertEqual(destination.string(forKey: "clear.numbers.v1"), "shared-numbers")
        for key in learning where key != "clear.numbers.v1" { XCTAssertEqual(destination.string(forKey: key), "legacy-" + key) }
        XCTAssertEqual(source.data(forKey: "clear.settings.v1"), Data([1, 2, 3]))
        for key in learning + ["clear.settings.v1"] { destination.removeObject(forKey: key) }
        ClearKeyboard.SharedStorage.migrateLegacyDefaults(from: source, to: destination, groupIdentifier: "first")
        for key in learning + ["clear.settings.v1"] { XCTAssertNil(destination.object(forKey: key), "A reload may not resurrect cleared data") }
        ClearKeyboard.SharedStorage.migrateLegacyDefaults(from: source, to: destination, groupIdentifier: "second")
        XCTAssertEqual(destination.data(forKey: "clear.settings.v1"), Data([1, 2, 3]))
        for key in learning { XCTAssertEqual(destination.string(forKey: key), "legacy-" + key) }
    }
    func testMigrationHonorsLearningResetEpochBeforeCopyingOldRecords() throws {
        for epoch in [nil, "old", "shared"] as [String?] {
            let oldSuite = "clear.epoch.old." + UUID().uuidString, sharedSuite = "clear.epoch.shared." + UUID().uuidString
            let source = try XCTUnwrap(UserDefaults(suiteName: oldSuite)), destination = try XCTUnwrap(UserDefaults(suiteName: sharedSuite))
            defer { source.removePersistentDomain(forName: oldSuite); destination.removePersistentDomain(forName: sharedSuite) }
            source.set("theme", forKey: "clear.settings.v1")
            if let epoch { source.set(epoch, forKey: "clear.learned.epoch") }
            destination.set("shared", forKey: "clear.learned.epoch")
            for key in ["clear.learned.v1", "clear.choices.v2", "clear.numbers.v1"] { source.set("old-record", forKey: key) }
            ClearKeyboard.SharedStorage.migrateLegacyDefaults(from: source, to: destination, groupIdentifier: "group")
            XCTAssertEqual(destination.string(forKey: "clear.settings.v1"), "theme")
            XCTAssertEqual(destination.string(forKey: "clear.learned.epoch"), "shared")
            for key in ["clear.learned.v1", "clear.choices.v2", "clear.numbers.v1"] {
                XCTAssertEqual(destination.string(forKey: key), epoch == "shared" ? "old-record" : nil, "A shared reset must prevent restoring stale learning")
            }
        }
    }
    func testClipboardDirectoryAdoptionPreservesRecordsPhrasesAndAttachmentBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clear.clipboard.migration." + UUID().uuidString)
        let source = root.appendingPathComponent("Clear"), destination = root.appendingPathComponent("Private")
        let suite = "clear.clipboard.migration." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 10_000)
        let clips = ClearKeyboard.ClipboardStore(url: source.appendingPathComponent("clipboard.json"))
        clips.add("pinned", now: now.addingTimeInterval(-1_000)); clips.togglePin(try XCTUnwrap(clips.clips.first).id)
        clips.add("expired", now: now.addingTimeInterval(-1_000))
        let bytes = Data([3, 1, 4, 1, 5, 9])
        XCTAssertTrue(clips.addAttachment(bytes, typeIdentifier: "public.data", name: "attachment", now: now))
        let phrases = ClearKeyboard.ClipboardStore(url: source.appendingPathComponent("common-phrases.json")); phrases.add("常用语", now: now)
        let originalJSON = try Data(contentsOf: source.appendingPathComponent("clipboard.json"))
        let originalPhrases = try Data(contentsOf: source.appendingPathComponent("common-phrases.json"))
        ClearKeyboard.SharedStorage.adoptLegacyClipboardDirectory(from: source, to: destination, defaults: defaults, groupIdentifier: "group")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("clipboard.json")), originalJSON)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("common-phrases.json")), originalPhrases)
        let restored = ClearKeyboard.ClipboardStore(url: destination.appendingPathComponent("clipboard.json"))
        XCTAssertEqual(restored.clips, clips.clips, "IDs, dates, pinning and attachment metadata must survive without replaying records")
        XCTAssertEqual(restored.attachmentData(for: try XCTUnwrap(restored.clips.first { $0.attachment != nil })), bytes)
        restored.prune(lifetime: 60, now: now)
        XCTAssertEqual(Set(restored.clips.map(\.text)), ["pinned", "attachment"])
    }
    func testClipboardAdoptionDoesNotOverwriteExistingOrRestoreClearedSharedHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clear.clipboard.existing." + UUID().uuidString)
        let source = root.appendingPathComponent("Clear"), destination = root.appendingPathComponent("Private")
        let suite = "clear.clipboard.existing." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let stale = Data("old-records".utf8), cleared = Data("[]".utf8)
        try stale.write(to: source.appendingPathComponent("clipboard.json")); try cleared.write(to: destination.appendingPathComponent("clipboard.json"))
        ClearKeyboard.SharedStorage.adoptLegacyClipboardDirectory(from: source, to: destination, defaults: defaults, groupIdentifier: "group")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("clipboard.json")), cleared)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("clipboard.json")), stale)
        try FileManager.default.removeItem(at: destination)
        ClearKeyboard.SharedStorage.adoptLegacyClipboardDirectory(from: source, to: destination, defaults: defaults, groupIdentifier: "group")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "A completed migration decision may not resurrect cleared shared history")
    }
    func testFailedClipboardAdoptionKeepsLocalDataAndCanRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clear.clipboard.retry." + UUID().uuidString)
        let source = root.appendingPathComponent("Clear"), parent = root.appendingPathComponent("not-created-yet"), destination = parent.appendingPathComponent("Private")
        let suite = "clear.clipboard.retry." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = Data("preserve me".utf8); try bytes.write(to: source.appendingPathComponent("clipboard.json"))
        ClearKeyboard.SharedStorage.adoptLegacyClipboardDirectory(from: source, to: destination, defaults: defaults, groupIdentifier: "group")
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("clipboard.json")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        ClearKeyboard.SharedStorage.adoptLegacyClipboardDirectory(from: source, to: destination, defaults: defaults, groupIdentifier: "group")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("clipboard.json")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }
    func testLiveCustomizationFormSurvivesRepeatedUpdates() async throws {
        let suite = "clear.form.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = makePreferences(defaults)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: NavigationStack { ClearKeyboard.CustomizationView() }.environmentObject(preferences))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; preferences.deactivate() }
        for index in 0..<12 {
            preferences.settings.accent = index.isMultiple(of: 2) ? .rose : .ocean
            preferences.settings.hand = index.isMultiple(of: 2) ? .left : .full
            preferences.settings.keyHeight = Double(44 + index)
            preferences.settings.glass = index.isMultiple(of: 2) ? .mist : .clear
            try await Task.sleep(nanoseconds: 40_000_000)
            window.layoutIfNeeded()
        }
        XCTAssertNotNil(host.view.window)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "customization-live"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testObservedAppearancePagesUpdateTheirActualRenderedKeyboard() async throws {
        let suite = "clear.appearance.render." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = makePreferences(defaults)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.overrideUserInterfaceStyle = .dark
        defer { window.isHidden = true }
        func findPreview(_ view: UIView) -> ClearKeyboard.KeyboardAppearancePreview? {
            if let result = view as? ClearKeyboard.KeyboardAppearancePreview { return result }
            return view.subviews.lazy.compactMap(findPreview).first
        }
        func renderedPixels(_ preview: UIView) throws -> Data {
            let rect = preview.convert(preview.bounds, to: window).integral.intersection(window.bounds)
            let valid = !rect.isEmpty && !rect.isNull && rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
            _ = try XCTUnwrap(valid ? rect : nil, "The preview must be visible before comparing its rendered pixels")
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let crop = try XCTUnwrap(image.cgImage?.cropping(to: rect))
            return try XCTUnwrap(UIImage(cgImage: crop).pngData())
        }
        for item in ClearKeyboard.AppearanceItem.allCases {
            print("APPEARANCE_RENDER begin " + item.rawValue)
            let host = UIHostingController(rootView: ClearKeyboard.AppAppearanceDetail(item: item).environmentObject(preferences))
            window.rootViewController = host; window.makeKeyAndVisible()
            try await Task.sleep(nanoseconds: 120_000_000); window.layoutIfNeeded()
            let preview = try XCTUnwrap(findPreview(host.view), item.rawValue)
            let oldValue = preview.accessibilityValue, oldPixels = try renderedPixels(preview)
            switch item {
            case .keyGlass: preferences.settings.keyGlassStrength = 0.96
            case .keyColor: preferences.settings.keyColorHex = "#292C39"
            case .candidateColor: preferences.settings.candidateColorHex = "#FF3399"
            case .candidateSize: preferences.settings.candidateTextSize = .extraLarge
            }
            for _ in 0..<100 {
                if preview.accessibilityValue != oldValue { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            window.layoutIfNeeded()
            XCTAssertNotEqual(preview.accessibilityValue, oldValue, "The observed destination kept stale settings: " + item.rawValue)
            XCTAssertNotEqual(try renderedPixels(preview), oldPixels, "Only the setting value changed; the keyboard pixels did not: " + item.rawValue)
            XCTAssertEqual(ClearKeyboard.SettingsStore(defaults: defaults).load(), preferences.settings)
            print("APPEARANCE_RENDER end " + item.rawValue)
        }
    }
}

@MainActor private final class CustomizationReloadDocument: ClearKeyboard.KeyboardDocument {
    var contextBefore: String { "" }
    var contextAfter: String { "" }
    let documentIdentity = UUID().uuidString
    var selectedText: String { "" }
    var enterTitle: String { "换行" }
    var needsGlobe: Bool { false }
    var fullAccess: Bool { false }
    var prefersEnglish: Bool { true }
    var capitalization: UITextAutocapitalizationType { .none }
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
    func clearInput() -> ClearKeyboard.DeletedInput? { nil }
    func restoreInput(_ value: ClearKeyboard.DeletedInput) -> Bool { false }
}
