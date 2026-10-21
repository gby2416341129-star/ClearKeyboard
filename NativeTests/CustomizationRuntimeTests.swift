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
            preferences.settings.glassOpacity = Double(index % 80 + 15) / 100
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
        root.glassOpacity.wrappedValue = -.infinity
        root.customAccentHex.wrappedValue = "#abc"
        root.toolbar.wrappedValue = [.clipboard, .clipboard, .emoji]
        XCTAssertEqual(preferences.settings.keyHeight, 58)
        XCTAssertEqual(preferences.settings.glassOpacity, 0.52)
        XCTAssertEqual(preferences.settings.customAccentHex, "#AABBCC")
        XCTAssertEqual(preferences.settings.toolbar, [.language, .clipboard, .emoji])
        XCTAssertEqual(ClearKeyboard.SettingsStore(defaults: defaults).load(), preferences.settings)
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
        func findPreview(_ view: UIView) -> KeyboardAppearancePreview? {
            if let result = view as? KeyboardAppearancePreview { return result }
            return view.subviews.lazy.compactMap(findPreview).first
        }
        func renderedPixels(_ preview: UIView) throws -> Data {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let rect = preview.convert(preview.bounds, to: window).integral.intersection(window.bounds)
            let crop = try XCTUnwrap(image.cgImage?.cropping(to: rect))
            return try XCTUnwrap(UIImage(cgImage: crop).pngData())
        }
        for item in AppearanceItem.allCases {
            let host = UIHostingController(rootView: AppAppearanceDetail(item: item).environmentObject(preferences))
            window.rootViewController = host; window.makeKeyAndVisible()
            try await Task.sleep(nanoseconds: 120_000_000); window.layoutIfNeeded()
            let preview = try XCTUnwrap(findPreview(host.view), item.rawValue)
            let oldValue = preview.accessibilityValue, oldPixels = try renderedPixels(preview)
            switch item {
            case .backgroundGlass: preferences.settings.backgroundGlassStrength = 0.96
            case .keyGlass: preferences.settings.keyGlassStrength = 0.96
            case .backgroundColor: preferences.settings.backgroundColorHex = "#E3AC72"
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
        }
    }
}
