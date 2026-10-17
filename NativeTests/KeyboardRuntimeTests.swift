import XCTest
import UIKit

@MainActor final class KeyboardRuntimeTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants($0) } }
    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<160 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Keyboard state did not become ready within eight seconds")
    }
    private func tap(_ action: KeyAction, in view: UIView) throws {
        let button = try XCTUnwrap(descendants(view).compactMap { $0 as? KeyButton }.first { $0.key.action == action })
        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchUpInside)
    }
    func testAZeroAndNarrowKeyLayout() {
        let button = KeyButton(key: KeyboardKey("a"))
        for size in [CGSize.zero, CGSize(width: 1, height: 1), CGSize(width: 5, height: 7), CGSize(width: 39, height: 56)] {
            button.frame = CGRect(origin: .zero, size: size)
            button.setNeedsLayout(); button.layoutIfNeeded()
            for view in descendants(button) {
                XCTAssertTrue(view.frame.origin.x.isFinite && view.frame.origin.y.isFinite)
                XCTAssertTrue(view.frame.width.isFinite && view.frame.height.isFinite)
                XCTAssertFalse(view.frame.isNull)
            }
        }
    }
    func testTypingLabChineseAndEnglishCandidates() async throws {
        let controller = TypingLabController(settings: KeyboardSettings())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.loadViewIfNeeded(); controller.view.frame = window.bounds
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        defer { window.isHidden = true; controller.model.suspend() }
        try await waitFor { controller.model.engineState == "离线就绪" }
        for letter in "nihao" { try tap(.text(String(letter)), in: controller.view) }
        try await waitFor { controller.model.candidatesAreCurrent }
        XCTAssertTrue(controller.model.candidates.contains { $0.text == "你好" }, "Pinyin did not produce a Chinese candidate")
        XCTAssertTrue(descendants(controller.view).compactMap { $0 as? UIButton }.contains { $0.title(for: .normal) == "你好" }, "Chinese candidates did not render")
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        let chineseButton = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "candidate.你好" })
        XCTAssertGreaterThan(chineseButton.bounds.width, 0, "Candidate stack must have a visible width")
        XCTAssertGreaterThan(chineseButton.bounds.height, 0)
        snapshot(controller.view, name: "pinyin-candidates")
        try tap(.space, in: controller.view)
        XCTAssertTrue(controller.textView.text.hasSuffix("你好"))
        controller.model.toggleLanguage()
        controller.model.settings.autoCapitalization = false
        controller.textView.text = ""; controller.textView.selectedRange = NSRange(location: 0, length: 0)
        controller.model.cursorChanged()
        for letter in "hell" { try tap(.text(String(letter)), in: controller.view) }
        try await waitFor { controller.model.candidatesAreCurrent }
        XCTAssertTrue(controller.model.candidates.contains { $0.text == "hello" }, "English completion did not produce hello")
        let candidate = try XCTUnwrap(controller.model.candidates.first { $0.text == "hello" })
        controller.model.choose(candidate)
        XCTAssertEqual(controller.textView.text, "hello ")
    }
    func testSelectionNotificationsAndExternalSettingsPreserveComposition() async throws {
        let settings = KeyboardSettings()
        let controller = TypingLabController(settings: settings); controller.loadViewIfNeeded()
        try await waitFor { controller.model.engineState == "离线就绪" }
        controller.model.handle(.text("n")); controller.model.handle(.text("i"))
        controller.textViewDidChangeSelection(controller.textView)
        XCTAssertEqual(controller.model.composition.raw, "ni")
        controller.model.toggleLanguage(); controller.applyExternalSettings(settings)
        XCTAssertEqual(controller.model.settings.language, .english, "A routine SwiftUI update must preserve the language selected in the keyboard")
        controller.model.suspend()
    }
    func testTextViewInputRoutesThroughChineseEngine() async throws {
        let controller = TypingLabController(settings: KeyboardSettings()); controller.loadViewIfNeeded()
        try await waitFor { controller.model.engineState == "离线就绪" }
        for letter in "nihao" {
            XCTAssertFalse(controller.textView(controller.textView, shouldChangeTextIn: controller.textView.selectedRange, replacementText: String(letter)))
        }
        try await waitFor { controller.model.candidatesAreCurrent }
        XCTAssertTrue(controller.model.candidates.contains { $0.text == "你好" })
        XCTAssertEqual(controller.textView.text, "")
        controller.model.suspend()
    }
    func testToolbarAndSideRailWorkInBothHandModes() async throws {
        let controller = TypingLabController(settings: KeyboardSettings()); controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 500)
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first)
        for mode in [HandMode.left, .right] {
            controller.model.settings.hand = mode
            surface.setToolPinned(.emoji, pinned: false); surface.setToolPinned(.oneHand, pinned: true)
            surface.reorderToolbarTool(.oneHand, before: .clipboard)
            XCTAssertEqual(controller.model.settings.toolbar[1], .oneHand)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded(); surface.layoutIfNeeded()
            for identifier in ["onehand.switch", "onehand.resize", "onehand.full"] {
                XCTAssertNotNil(descendants(surface).first { $0.accessibilityIdentifier == identifier })
            }
            snapshot(controller.view, name: "single-hand-\(mode.rawValue)")
            let full = try XCTUnwrap(descendants(surface).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "onehand.full" })
            full.sendActions(for: .touchUpInside); XCTAssertEqual(controller.model.settings.hand, .full)
        }
        controller.model.suspend()
    }
    private func snapshot(_ view: UIView, name: String) {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testKeyboardControllerLifecycle() async throws {
        let controller = KeyboardViewController(nibName: nil, bundle: nil)
        controller.textDidChange(nil)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 320)
        controller.beginAppearanceTransition(true, animated: false); controller.endAppearanceTransition()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        controller.textDidChange(nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(descendants(controller.view).compactMap { $0 as? KeyButton }.isEmpty)
        controller.beginAppearanceTransition(false, animated: false); controller.endAppearanceTransition()
    }
}
