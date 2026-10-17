import XCTest
import UIKit

@MainActor final class KeyboardRuntimeTests: XCTestCase {
    private func testSettings() -> KeyboardSettings { var settings = KeyboardSettings(); settings.automaticClipboard = false; return settings }
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
        let controller = TypingLabController(settings: testSettings())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.loadViewIfNeeded(); controller.view.frame = window.bounds
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        defer { window.isHidden = true; controller.model.suspend() }
        try await waitFor { controller.model.engineState == "离线就绪" }
        for letter in "nihao" { try tap(.text(String(letter)), in: controller.view) }
        XCTAssertEqual(controller.textView.text, "nihao", "The host input must show the active pinyin")
        XCTAssertNotNil(controller.textView.markedTextRange)
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
        XCTAssertNil(controller.textView.markedTextRange)
        try tap(.language, in: controller.view)
        XCTAssertEqual(controller.model.settings.language, .english)
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
        let settings = testSettings()
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
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        try await waitFor { controller.model.engineState == "离线就绪" }
        for letter in "nihao" {
            XCTAssertFalse(controller.textView(controller.textView, shouldChangeTextIn: controller.textView.selectedRange, replacementText: String(letter)))
        }
        try await waitFor { controller.model.candidatesAreCurrent }
        XCTAssertTrue(controller.model.candidates.contains { $0.text == "你好" })
        XCTAssertEqual(controller.textView.text, "nihao")
        XCTAssertNotNil(controller.textView.markedTextRange)
        controller.model.suspend()
    }
    func testTypingLabFitsAllFourRowsWhileComposing() async throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 380)
        controller.model.handle(.text("n"))
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first)
        surface.layoutIfNeeded()
        let enter = try XCTUnwrap(descendants(surface).compactMap { $0 as? KeyButton }.first { $0.key.action == .enter })
        XCTAssertLessThanOrEqual(enter.convert(enter.bounds, to: controller.view).maxY, controller.view.bounds.maxY, "The candidate row must not clip the bottom key row")
        controller.model.suspend()
    }
    func testToolbarAndSideRailWorkInBothHandModes() async throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; controller.model.suspend() }
        controller.view.frame = window.bounds
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first)
        for mode in [HandMode.left, .right] {
            controller.model.settings.hand = mode
            surface.setToolPinned(.emoji, pinned: false); surface.setToolPinned(.oneHand, pinned: true)
            surface.reorderToolbarTool(.oneHand, before: .clipboard)
            XCTAssertEqual(controller.model.settings.toolbar[1], .oneHand)
            surface.reorderToolbarTool(.oneHand, before: .appearance)
            XCTAssertEqual(controller.model.settings.toolbar, [.language, .clipboard, .oneHand, .appearance])
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded(); surface.layoutIfNeeded()
            for identifier in ["onehand.switch", "onehand.resize", "onehand.full"] {
                XCTAssertNotNil(descendants(surface).first { $0.accessibilityIdentifier == identifier })
            }
            snapshot(controller.view, name: "single-hand-\(mode.rawValue)")
            let full = try XCTUnwrap(descendants(surface).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "onehand.full" })
            full.sendActions(for: .touchUpInside); XCTAssertEqual(controller.model.settings.hand, .full)
        }
    }
    private func snapshot(_ view: UIView, name: String) {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testKeyboardControllerLifecycle() async throws {
        // A controller can load before its remote host connects. The real UIKit proxy then has no document UUID.
        // UITextView.inputViewController does not establish an extension's remote text proxy, so this test
        // intentionally verifies pre-connection startup; TypingLab tests cover actual text editing separately.
        XCTAssertNotNil(NSClassFromString("ClearKeyboardViewController"))
        let controller = KeyboardViewController(nibName: nil, bundle: nil)
        controller.textDidChange(nil)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 320)
        controller.beginAppearanceTransition(true, animated: false); controller.endAppearanceTransition()
        try await Task.sleep(nanoseconds: 300_000_000)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        controller.textDidChange(nil)
        XCTAssertGreaterThan(controller.view.bounds.width, 0)
        XCTAssertFalse(descendants(controller.view).compactMap { $0 as? KeyButton }.isEmpty)
        for view in descendants(controller.view) { XCTAssertTrue(view.frame.origin.x.isFinite && view.frame.origin.y.isFinite) }
        controller.beginAppearanceTransition(false, animated: false); controller.endAppearanceTransition()
    }
    func testMarkedTextReplacementDeletionAndSelection() async throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        defer { controller.model.suspend() }
        try await waitFor { controller.model.engineState == "离线就绪" }
        controller.insert("前文 👨‍👩‍👧‍👦 后文")
        controller.textView.selectedRange = NSRange(location: 0, length: 2)
        controller.textViewDidChangeSelection(controller.textView)
        for letter in "nihao" { controller.model.handle(.text(String(letter))) }
        XCTAssertEqual(controller.textView.text, "nihao 👨‍👩‍👧‍👦 后文")
        controller.model.handle(.delete)
        XCTAssertEqual(controller.textView.text, "niha 👨‍👩‍👧‍👦 后文")
        controller.model.handle(.text("o"))
        try await waitFor { controller.model.candidatesAreCurrent }
        controller.model.choose(try XCTUnwrap(controller.model.candidates.first { $0.text == "你好" }))
        XCTAssertEqual(controller.textView.text, "你好 👨‍👩‍👧‍👦 后文")
        XCTAssertNil(controller.textView.markedTextRange)
        controller.model.handle(.text("n")); controller.model.clearComposition()
        XCTAssertEqual(controller.textView.text, "你好 👨‍👩‍👧‍👦 后文")
        controller.model.handle(.text("n")); controller.model.handle(.delete)
        XCTAssertEqual(controller.textView.text, "你好 👨‍👩‍👧‍👦 后文")
        XCTAssertNil(controller.textView.markedTextRange)
    }
    func testAllRowsFitHostResizeAndLargeParentCorners() async throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        defer { controller.model.suspend() }
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first)
        if #available(iOS 26.0, *) { controller.view.cornerConfiguration = .corners(radius: .fixed(180)) }
        for hand in HandMode.allCases {
            controller.model.settings.hand = hand
            for height: CGFloat in [180, 216, 240, 280] {
                surface.frame = CGRect(x: 0, y: 0, width: 393, height: height)
                surface.setNeedsLayout(); surface.layoutIfNeeded()
                for key in descendants(surface).compactMap({ $0 as? KeyButton }) {
                    let frame = key.convert(key.bounds, to: surface)
                    XCTAssertLessThanOrEqual(frame.maxY, height, "Bottom row exceeded actual host height")
                    XCTAssertGreaterThanOrEqual(frame.minX, 0); XCTAssertLessThanOrEqual(frame.maxX, 393.1)
                }
                XCTAssertEqual(surface.layer.cornerRadius, 28, accuracy: 0.5)
            }
        }
        snapshot(surface, name: "compressed-host")
    }
    func testAutomaticClipboardCaptureAndPermissionGating() async throws {
        let suite = "clear.capture.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("clipboard.json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var count = 1, reads = 0, text = "第一次复制"
        let name = Notification.Name("clear.capture." + UUID().uuidString)
        let capture = ClipboardCapture(defaults: defaults, makeStore: { ClipboardStore(url: url) }, changeCount: { count }, hasStrings: { true }, readText: { reads += 1; return text }, notificationName: name)
        var settings = KeyboardSettings(); settings.automaticClipboard = true
        capture.activate(settings: settings, allowed: false)
        XCTAssertEqual(reads, 0)
        capture.activate(settings: settings, allowed: true)
        XCTAssertEqual(ClipboardStore(url: url).clips.map(\.text), ["第一次复制"])
        capture.activate(settings: settings, allowed: true)
        XCTAssertEqual(reads, 1, "Reopening must not reread the same clipboard version")
        count += 1; text = "第二次复制"
        NotificationCenter.default.post(name: name, object: nil)
        try await waitFor { reads == 2 }
        XCTAssertEqual(ClipboardStore(url: url).clips.map(\.text), ["第二次复制", "第一次复制"])
        capture.stop(); count += 1; text = "后台复制"
        NotificationCenter.default.post(name: name, object: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(reads, 2)
        capture.activate(settings: settings, allowed: true)
        XCTAssertEqual(ClipboardStore(url: url).clips.first?.text, "后台复制")
        settings.automaticClipboard = false; capture.activate(settings: settings, allowed: true)
        count += 1; capture.captureIfChanged(); XCTAssertEqual(reads, 3)
    }
}
