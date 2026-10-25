import XCTest
import UIKit
import SwiftUI
@testable import ClearKeyboard

@MainActor final class GlassDesignRuntimeTests: XCTestCase {
    func testVibrationEventsAreSynchronousOrderedAndNeverQueueLatePulses() async throws {
        var received: [CGFloat] = []
        let feedback = KeyboardVibration { received.append($0) }
        feedback.prepare()
        for index in 1...200 { feedback.pulse(intensity: Double(index)/200) }
        XCTAssertEqual(received.count, 200)
        for index in 0..<200 { XCTAssertEqual(received[index], CGFloat(0.22 + 0.78 * Double(index+1)/200), accuracy: 0.00001) }
        feedback.pulse(intensity: 0); feedback.pulse(intensity: .nan)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(received.count, 200, "No delayed, duplicate, zero-strength or invalid pulses")
        received = []
        let key = KeyButton(key: KeyboardKey("Q"), vibration: feedback)
        var settings = KeyboardSettings(); settings.vibrationEnabled = true; settings.vibrationIntensity = 0.6823
        key.apply(settings)
        var actions = 0
        key.onAction = { _ in actions += 1; XCTAssertEqual(received.count, actions, "Exactly one synchronous impact precedes each accepted tap") }
        for _ in 0..<200 { key.sendActions(for: .touchDown); key.sendActions(for: .touchUpInside) }
        XCTAssertEqual(actions, 200); XCTAssertEqual(received.count, 200)
        key.onAction = nil
        settings.vibrationEnabled = false; key.apply(settings)
        key.sendActions(for: .touchDown); key.sendActions(for: .touchUpInside)
        XCTAssertEqual(received.count, 200, "Disabled feedback must not submit actuator events")
    }
    func testRetiredMaterialAndTapFeedbackKeysAreNotWrittenBack() throws {
        let original = KeyboardSettings()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["glass"] = "mist"; object["haptics"] = true
        let value = try JSONDecoder().decode(KeyboardSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(value, original)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String:Any])
        XCTAssertNil(saved["glass"]); XCTAssertNil(saved["haptics"])
    }
    func testVibrationSettingsSyncAndSanitizeWithoutChangingInput() throws {
        var settings = KeyboardSettings(); settings.vibrationEnabled = true; settings.vibrationIntensity = 0.6823
        var receiver = KeyboardSettings(); receiver.language = .english
        let snapshot = AppearanceSnapshot(settings: settings)
        let result = snapshot.applying(to: receiver)
        XCTAssertTrue(result.usesVibration); XCTAssertEqual(result.resolvedVibrationIntensity, 0.6823)
        XCTAssertEqual(result.language, .english)
        settings.vibrationIntensity = .infinity; settings.sanitize(); XCTAssertNil(settings.vibrationIntensity)
    }
    func testSliderAccessibilityCommitsOnlyChangedValuesAndRetainsContinuousPrecision() {
        let view = ValueSliderView(); var changes: [Double] = []
        view.configure(title: "强度", value: 0.45, range: 0...1, defaultValue: 0.45, identifier: "test", percent: true)
        view.onCommit = { changes.append($0) }
        view.slider.value = 0.6823; view.slider.sendActions(for: .valueChanged)
        view.slider.sendActions(for: .valueChanged)
        XCTAssertEqual(changes.count, 1); XCTAssertEqual(changes[0], 0.6823, accuracy: 0.00001)
    }
    func testUnifiedGlassScreensAtPhoneSizeInLightAndDark() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKey() }
        let suite = "clear.glass.visual." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(store: SettingsStore(defaults: defaults))
        preferences.settings.automaticClipboard = false
        func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
        func capture(_ name: String) async throws {
            try await Task.sleep(nanoseconds: 300_000_000); window.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat(); format.scale = window.screen.scale
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image); attachment.name = "Glass58-" + name
            attachment.lifetime = .keepAlways; add(attachment)
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            let theme = style == .dark ? "dark" : "light"
            let pages: [(String, AnyView)] = [
                ("root-native-tabs", AnyView(RootView())),
                ("home", AnyView(HomeView(selectedTab: .constant(.home)))),
                ("custom", AnyView(CustomizationView())),
                ("input", AnyView(InputSettingsView())),
                ("clipboard-settings", AnyView(ClipboardSettingsView())),
                ("about", AnyView(InputAboutView())),
                ("fuzzy", AnyView(FuzzySettingsView()))
            ]
            for (name, page) in pages {
                if name == "root-native-tabs" {
                    window.rootViewController = UIHostingController(rootView: page.environmentObject(preferences))
                } else {
                    window.rootViewController = UIHostingController(rootView: NavigationStack { page }.environmentObject(preferences))
                }
                window.makeKeyAndVisible()
                try await capture(name + "-" + theme)
                XCTAssertFalse(views(window).contains { $0.accessibilityIdentifier == "custom.footer" })
            }
            for strength in [0.0, 0.5, 1.0] {
                preferences.settings.keyGlassStrength = strength
                window.rootViewController = UIHostingController(rootView: NavigationStack { AppAppearanceDetail(item: .keyGlass) }.environmentObject(preferences))
                window.makeKeyAndVisible()
                try await capture("transmission-\(Int(strength*100))-" + theme)
            }
            preferences.settings.keyGlassStrength = nil
            var settings = KeyboardSettings(); settings.automaticClipboard = false
            let controller = TypingLabController(settings: settings)
            window.rootViewController = controller; window.makeKeyAndVisible(); controller.loadViewIfNeeded(); window.layoutIfNeeded()
            let surface = try XCTUnwrap(views(controller.view).compactMap { $0 as? KeyboardSurface }.first)
            let url = SharedStorage.clipboardURL(allowShared: surface.model.document?.fullAccess == true)
            let original = try? Data(contentsOf: url)
            defer {
                controller.model.suspend()
                if let original { try? original.write(to: url, options: .atomic) }
                else { try? FileManager.default.removeItem(at: url) }
            }
            ClipboardStore(url: url).clear(); ClipboardStore(url: url).add("(021) 3747 9330")
            surface.model.clipboardCapture.onCapture?()
            try await capture("recent-clipboard-" + theme)
            views(surface).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "clipboard.recent.close" }?.sendActions(for: .touchUpInside)
            try await capture("keyboard-" + theme)
            let clipboardButton = try XCTUnwrap(views(surface).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "toolbar.clipboard" })
            clipboardButton.sendActions(for: .touchUpInside)
            XCTAssertTrue(views(surface).contains { $0 is ClipboardPanel })
            try await capture("clipboard-panel-" + theme)
            surface.closePanel()
            views(surface).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "toolbar.tools" }?.sendActions(for: .touchUpInside)
            try await capture("tools-" + theme)
        }
    }
}
