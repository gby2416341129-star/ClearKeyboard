import XCTest
import UIKit

@MainActor final class ToolbarMotion64Tests: XCTestCase {
    private final class Document: KeyboardDocument {
        let contextBefore = "", contextAfter = "", selectedText = ""
        let enterTitle = "换行", needsGlobe = false, fullAccess = false, prefersEnglish = false
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
    private func button(_ name: String, in surface: UIView) throws -> UIButton {
        try XCTUnwrap(views(surface).first { $0.accessibilityIdentifier == "toolbar." + name } as? UIButton)
    }
    private func fixture(vibration: KeyboardVibration? = nil) -> (Document, KeyboardModel, KeyboardSurface) {
        let document = Document(); var settings = KeyboardSettings()
        settings.toolbar = ToolbarTool.allCases; settings.vibrationIntensity = 0.63
        let model = KeyboardModel(document: document, settings: settings,
            defaults: UserDefaults(suiteName: UUID().uuidString)!, wordLookup: { _, _, _ in [] })
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
        XCTAssertTrue(pulses.allSatisfy { abs($0 - 0.63) < 0.001 })
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
            let line = preview.layoutManager.usedRect(for: preview.textContainer)
            XCTAssertEqual(line.midY + preview.textContainerInset.top, height / 2, accuracy: 0.5)
            XCTAssertEqual(preview.contentSize.height, height, accuracy: 0.5)
            XCTAssertGreaterThan(preview.contentSize.width, preview.bounds.width)
            preview.setContentOffset(CGPoint(x: 50, y: 0), animated: false)
            preview.setNeedsLayout(); preview.layoutIfNeeded()
            XCTAssertEqual(preview.contentOffset.x, 50, accuracy: 0.5)
            XCTAssertEqual(preview.contentOffset.y, 0, accuracy: 0.5)
        }
    }
}
