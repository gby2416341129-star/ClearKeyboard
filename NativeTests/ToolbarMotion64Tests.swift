import XCTest
import UIKit
import Security

@MainActor final class ToolbarMotion64Tests: XCTestCase {
    private final class Document: KeyboardDocument {
        let documentIdentity = UUID().uuidString
        let contextBefore = "", contextAfter = "", selectedText = ""
        let enterTitle = "换行", needsGlobe = false, prefersEnglish = false
        let fullAccess: Bool
        init(fullAccess: Bool = false) { self.fullAccess = fullAccess }
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
    private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
    private final class MemoryBackend: AppearanceSyncBackend {
        private let lock = NSLock()
        private var records: [String: Data] = [:]
        func read(account: String) -> Result<AppearanceBackendRecord?, AppearanceSyncError> {
            lock.lock(); defer { lock.unlock() }
            return .success(records[account].map { AppearanceBackendRecord(data: $0, accessGroup: "fixture.shared") })
        }
        func write(_ data: Data, account: String) -> Result<String?, AppearanceSyncError> {
            lock.lock(); defer { lock.unlock() }; records[account] = data
            return .success("fixture.shared")
        }
    }
    private final class UnavailableKeychain: AppearanceSyncBackend {
        func read(account: String) -> Result<AppearanceBackendRecord?, AppearanceSyncError> { .failure(.keychain(errSecMissingEntitlement)) }
        func write(_ data: Data, account: String) -> Result<String?, AppearanceSyncError> { .failure(.keychain(errSecMissingEntitlement)) }
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Settings did not reach the other process model")
    }
    private func button(_ name: String, in surface: UIView) throws -> UIButton {
        try XCTUnwrap(views(surface).first { $0.accessibilityIdentifier == "toolbar." + name } as? UIButton)
    }
    private func fixture(vibration: KeyboardVibration? = nil) -> (Document, KeyboardModel, KeyboardSurface) {
        let document = Document(); var settings = KeyboardSettings()
        settings.toolbar = ToolbarTool.allCases; settings.vibrationIntensity = 0.63
        let model = KeyboardModel(document: document, settings: settings,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let surface = KeyboardSurface(model: model, toolbarVibration: vibration)
        surface.frame = CGRect(x: 0, y: 0, width: 390, height: 310); surface.layoutIfNeeded()
        return (document, model, surface)
    }
    private func display(_ surface: UIView) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); let controller = UIViewController()
        window.rootViewController = controller; controller.view.backgroundColor = .systemBackground
        controller.view.addSubview(surface); window.makeKeyAndVisible(); window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08)); return window
    }
    func testToolbarTapsEmitOneHapticAndDoNotWaitForTheAnimation() throws {
        var pulses: [CGFloat] = []
        let vibration = KeyboardVibration(emit: { pulses.append($0) })
        let (document, model, surface) = fixture(vibration: vibration)
        defer { withExtendedLifetime(document) {} }
        for name in ["emoji", "keyColor", "keyColor", "compatibility", "compatibility", "tools", "tools"] {
            try button(name, in: surface).sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(pulses.count, 7)
        XCTAssertTrue(pulses.allSatisfy { abs($0 - KeyboardVibration.profile(intensity: 0.63, mode: .crisp).intensity) < 0.001 })
        XCTAssertNotEqual(model.settings.localPinyinComposition, true)
        XCTAssertTrue(views(surface).compactMap { $0 as? KeyboardAppearancePanelView }.isEmpty)
    }
    func testCompatibilityChangesItsIndicatorWithoutOpeningOrReplacingAPanel() throws {
        let (document, model, surface) = fixture(); defer { withExtendedLifetime(document) {} }
        let toggle = try button("compatibility", in: surface)
        toggle.sendActions(for: .touchUpInside)
        XCTAssertEqual(model.settings.localPinyinComposition, true)
        XCTAssertEqual(toggle.accessibilityLabel, "兼容输入，已开启")
        XCTAssertFalse(views(surface).contains { $0.accessibilityLabel == "键盘工具" && $0 is UIStackView })
        try button("emoji", in: surface).sendActions(for: .touchUpInside)
        let content = try XCTUnwrap(views(surface).first { $0.accessibilityLabel == "表情" && !($0 is UIButton) })
        toggle.sendActions(for: .touchUpInside)
        XCTAssertNotEqual(model.settings.localPinyinComposition, true)
        XCTAssertEqual(toggle.accessibilityLabel, "兼容输入，已关闭")
        XCTAssertTrue(content.superview === surface)
        XCTAssertFalse(views(surface).contains { $0.accessibilityIdentifier == "keyboard.compatibleInput" })
    }
    func testRapidVisiblePanelSwitchesLeaveOnlyTheLatestContent() throws {
        let (document, _, surface) = fixture(); defer { withExtendedLifetime(document) {} }
        let window = try display(surface); defer { window.isHidden = true }
        for name in ["emoji", "keyColor", "textColor", "textColor", "keyColor"] {
            try button(name, in: surface).sendActions(for: .touchUpInside)
            surface.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            XCTAssertLessThanOrEqual(views(surface).filter { $0.accessibilityIdentifier == "toolbar.transition.snapshot" }.count, 1)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        let panels = views(surface).compactMap { $0 as? KeyboardAppearancePanelView }
        XCTAssertEqual(panels.count, 1); XCTAssertEqual(panels.first?.selected, .keyColor)
        XCTAssertEqual(panels.first?.alpha, 1)
        XCTAssertFalse(views(surface).contains { $0.accessibilityIdentifier == "toolbar.transition.snapshot" })
        XCTAssertEqual(views(surface).compactMap { $0 as? KeyboardAppearancePreview }.count, 1)
        try button("keyColor", in: surface).sendActions(for: .touchUpInside)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertTrue(views(surface).compactMap { $0 as? KeyboardAppearancePanelView }.isEmpty)
    }
    func testCompatibilityIndicatorNativePhoneLayoutsInBothThemes() throws {
        let (document, model, surface) = fixture(); defer { withExtendedLifetime(document) {} }
        let window = try display(surface); defer { window.isHidden = true }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            try button("compatibility", in: surface).sendActions(for: .touchUpInside)
            surface.layoutIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            let image = UIGraphicsImageRenderer(bounds: surface.bounds).image { _ in
                surface.drawHierarchy(in: surface.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Toolbar64-" + (style == .dark ? "dark" : "light")
            attachment.lifetime = .keepAlways; add(attachment)
            try button("compatibility", in: surface).sendActions(for: .touchUpInside)
        }
        model.clipboardCapture.acceptText("陈哲：编程数学常规班 16次课 老生续费")
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            surface.layoutIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let image = UIGraphicsImageRenderer(bounds: surface.bounds).image { _ in
                surface.drawHierarchy(in: surface.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Clipboard64-" + (style == .dark ? "dark" : "light")
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }
    func testClipboardTextCentersVerticallyAndKeepsHorizontalBrowsing() {
        let preview = ClipboardInlinePreview()
        for height in [CGFloat(36), 44, 52] {
            preview.frame = CGRect(x: 0, y: 0, width: 160, height: height)
            preview.show(String(repeating: "陈哲：编程数学16次课 ", count: 30)); preview.layoutIfNeeded()
            let line = preview.renderedLineRect
            XCTAssertEqual(line.midY, height / 2, accuracy: 0.5)
            XCTAssertEqual(preview.contentSize.height, height, accuracy: 0.5)
            XCTAssertGreaterThan(preview.contentSize.width, preview.bounds.width)
            preview.setContentOffset(CGPoint(x: 50, y: 0), animated: false)
            preview.setNeedsLayout(); preview.layoutIfNeeded()
            XCTAssertEqual(preview.contentOffset.x, 50, accuracy: 0.5)
            XCTAssertEqual(preview.contentOffset.y, 0, accuracy: 0.5)
        }
    }
    func testEveryAppPreferenceReachesTheKeyboardAndKeyboardChangesReachTheApp() async throws {
        let backend = MemoryBackend()
        let appLink = AppearanceSettingsLink(role: .app, client: AppearanceSyncClient(backend: backend, coalesceInterval: 0), includeInputPreferences: true)
        let keyboardLink = AppearanceSettingsLink(role: .keyboard, client: AppearanceSyncClient(backend: backend, coalesceInterval: 0), includeInputPreferences: true)
        let appDefaults = UserDefaults(suiteName: UUID().uuidString)!, keyboardDefaults = UserDefaults(suiteName: UUID().uuidString)!
        let preferences = Preferences(store: SettingsStore(defaults: appDefaults), appearanceLink: appLink)
        let document = Document(fullAccess: true)
        let model = KeyboardModel(document: document, defaults: keyboardDefaults, appearanceLink: keyboardLink)
        preferences.activate(); defer { preferences.deactivate(); keyboardLink.deactivate(); withExtendedLifetime(document) {} }
        var value = KeyboardSettings()
        value.language = .english; value.keyHeight = 56; value.hand = .left; value.oneHandWidth = 0.72
        value.keyColorHex = "#558DF2"; value.candidateColorHex = "#D799BC"; value.candidateTextSize = .large
        value.keyGlassStrength = 0.21; value.accent = .rose; value.customAccentHex = "#E3AC72"
        value.vibrationEnabled = true; value.vibrationIntensity = 0.9; value.vibrationMode = .soft; value.toolbar = ToolbarTool.allCases
        value.localPinyinComposition = true; value.fuzzyPairs = ["n/l"]; value.predictions = false
        value.learnChoices = false; value.autoCapitalization = false
        value.automaticClipboard = false; value.clipboardLifetimeHours = 0
        preferences.settings = value
        let expected = AppearanceSnapshot(settings: value, includeInputPreferences: true)
        try await waitFor { expected.isApplied(to: model.settings) }
        XCTAssertEqual(AppearanceSnapshot(settings: model.settings, includeInputPreferences: true), expected)
        XCTAssertEqual(AppearanceSnapshot(settings: SettingsStore(defaults: keyboardDefaults).load(), includeInputPreferences: true), expected)
        model.settings.vibrationIntensity = 0.12; model.settings.vibrationMode = .crisp; model.settings.keyColorHex = "#7573F5"
        try await waitFor { preferences.settings.vibrationIntensity == 0.12 && preferences.settings.vibrationMode == .crisp && preferences.settings.keyColorHex == "#7573F5" }
        XCTAssertEqual(SettingsStore(defaults: appDefaults).load().vibrationIntensity, 0.12)
        model.reloadSettings(); keyboardLink.refresh()
        XCTAssertEqual(model.settings.vibrationIntensity, 0.12)
    }
    func testReSignedKeychainCanReadTheSavedItemWhenConfiguredGroupIsUnavailable() async throws {
        let service = "clear.motion64.fixture." + UUID().uuidString
        let writer = AppearanceKeychainBackend(service: service, accessGroup: "invalid." + UUID().uuidString)
        let reader = AppearanceKeychainBackend(service: service, accessGroup: "another.invalid." + UUID().uuidString)
        defer { _ = writer.remove(account: AppearanceSyncClient.settingsAccount) }
        let value = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: KeyboardSettings(), includeInputPreferences: true))
        let data = try AppearanceSyncClient.encode(value).get()
        let saved = try await Task.detached { try writer.write(data, account: AppearanceSyncClient.settingsAccount).get() }.value
        XCTAssertNotNil(saved)
        let record = try await Task.detached { try reader.read(account: AppearanceSyncClient.settingsAccount).get() }.value
        let restored = try AppearanceSyncClient.decode(XCTUnwrap(record).data).get()
        XCTAssertEqual(restored.snapshot, value.snapshot)
        XCTAssertEqual(restored.revision, value.revision)
        XCTAssertEqual(restored.updatedAt, value.updatedAt)
        XCTAssertFalse(try XCTUnwrap(restored.fieldDates).isEmpty, "Journal reads retain the field timestamps used to merge independent edits")
    }
    func testBothProcessesFindTheCommonGroupWhenTheirPrimaryGroupsDiffer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let common = root.appendingPathComponent("common")
        let app = AppearanceMirroredBackend(groupRootProvider: { root.appendingPathComponent("app") },
            keychain: UnavailableKeychain(), additionalGroupRootsProvider: { [common] })
        let keyboard = AppearanceMirroredBackend(groupRootProvider: { root.appendingPathComponent("keyboard") },
            keychain: UnavailableKeychain(), additionalGroupRootsProvider: { [common] })
        var settings = KeyboardSettings(); settings.vibrationEnabled = true; settings.vibrationIntensity = 0.8
        let first = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: settings, includeInputPreferences: true))
        _ = try app.write(AppearanceSyncClient.encode(first).get(), account: AppearanceSyncClient.settingsAccount).get()
        XCTAssertEqual(try AppearanceSyncClient.decode(XCTUnwrap(keyboard.read(account: AppearanceSyncClient.settingsAccount).get()).data).get(), first)
        settings.vibrationIntensity = 0.15
        let next = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: settings, includeInputPreferences: true), updatedAt: first.updatedAt.addingTimeInterval(1))
        _ = try keyboard.write(AppearanceSyncClient.encode(next).get(), account: AppearanceSyncClient.settingsAccount).get()
        let received = try AppearanceSyncClient.decode(XCTUnwrap(app.read(account: AppearanceSyncClient.settingsAccount).get()).data).get()
        XCTAssertEqual(received.snapshot, next.snapshot); XCTAssertEqual(received.revision, next.revision)
    }
    func testToolbarStopsWithWholeIconsAndRestoresThatPosition() throws {
        let old = UserDefaults.standard.object(forKey: "clear.toolbar.offset.v1")
        defer { UserDefaults.standard.set(old, forKey: "clear.toolbar.offset.v1") }
        let (document, _, surface) = fixture(); defer { withExtendedLifetime(document) {} }
        let scroll = try XCTUnwrap(views(surface).compactMap { $0 as? ToolbarScrollView }.first)
        XCTAssertGreaterThan(scroll.bounds.width, 200)
        scroll.setContentOffset(CGPoint(x: 65, y: 0), animated: false)
        surface.scrollViewDidEndDragging(scroll, willDecelerate: false)
        XCTAssertEqual(scroll.contentOffset.x, 65, accuracy: 0.5)
        XCTAssertNotNil(scroll.layer.mask)
        XCTAssertTrue(surface.beginToolbarDrag(.clipboard))
        scroll.setContentOffset(CGPoint(x: 91, y: 0), animated: false)
        surface.finishToolbarDrag()
        XCTAssertEqual(scroll.contentOffset.x, 91, accuracy: 0.5)
        let (secondDocument, _, restored) = fixture(); defer { withExtendedLifetime(secondDocument) {} }
        let second = try XCTUnwrap(views(restored).compactMap { $0 as? ToolbarScrollView }.first)
        XCTAssertEqual(second.contentOffset.x, 91, accuracy: 0.5)
    }
    func testVibrationStrengthUsesDistinctActuatorStylesAndZeroIsSilent() {
        var pulses: [CGFloat] = [], styles: [Int] = []
        let vibration = KeyboardVibration(emit: { pulses.append($0) })
        vibration.pulse(intensity: 0)
        for mode in VibrationMode.allCases {
            for value in [0.1, 0.4, 0.65, 1.0] {
                vibration.pulse(intensity: value, mode: mode)
                if let style = vibration.requestedStyle { styles.append(style.rawValue) }
            }
        }
        XCTAssertEqual(pulses.count, 8)
        XCTAssertEqual(Set(styles).count, 2)
        XCTAssertEqual(Array(styles.prefix(4)), Array(repeating: UIImpactFeedbackGenerator.FeedbackStyle.rigid.rawValue, count: 4))
        XCTAssertEqual(Array(styles.suffix(4)), Array(repeating: UIImpactFeedbackGenerator.FeedbackStyle.soft.rawValue, count: 4))
        XCTAssertTrue(zip(pulses.prefix(3), pulses.dropFirst().prefix(3)).allSatisfy { $0 < $1 })
        XCTAssertTrue(zip(pulses.suffix(4).prefix(3), pulses.suffix(3)).allSatisfy { $0 < $1 })
    }
    func testClipboardAndWordSelectionHaveOnlyTheToolbarReturnButton() throws {
        let (document, _, surface) = fixture(); defer { withExtendedLifetime(document) {} }
        try button("clipboard", in: surface).sendActions(for: .touchUpInside)
        let panel = try XCTUnwrap(views(surface).compactMap { $0 as? ClipboardPanel }.first)
        XCTAssertEqual(views(surface).filter { $0 is UIButton && $0.accessibilityLabel == "返回键盘" }.count, 1)
        panel.selectText("甲乙丙丁")
        XCTAssertEqual(views(surface).filter { $0 is UIButton && $0.accessibilityLabel == "返回键盘" }.count, 1)
        XCTAssertNil(views(panel).first { $0.accessibilityIdentifier == "clipboard.insertSelection" })
        XCTAssertNotNil(views(surface).first { $0.accessibilityIdentifier == "clipboard.insertSelection" && !$0.isHidden })
        try button("tools", in: surface).sendActions(for: .touchUpInside)
        XCTAssertNil(panel.superview)
    }
}
