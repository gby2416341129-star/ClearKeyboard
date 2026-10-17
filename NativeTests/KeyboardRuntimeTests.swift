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
    func testOneHandIconImmediatelyChangesSideWithoutAnExtraPanel() throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        defer { controller.model.suspend() }
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 700)
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first)
        surface.setToolPinned(.emoji, pinned: false); surface.setToolPinned(.oneHand, pinned: true)
        for expected in [HandMode.right, .left, .right] {
            let button = try XCTUnwrap(descendants(surface).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "toolbar.oneHand" })
            button.sendActions(for: .touchUpInside)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded(); surface.layoutIfNeeded()
            XCTAssertEqual(controller.model.settings.hand, expected)
            XCTAssertFalse(descendants(surface).compactMap { $0 as? UIButton }.contains { $0.title(for: .normal) == "完成" })
            XCTAssertTrue(descendants(surface).compactMap { $0 as? KeyButton }.allSatisfy { !$0.isHidden && $0.superview?.superview?.isHidden == false })
        }
        let full = try XCTUnwrap(descendants(surface).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "onehand.full" })
        full.sendActions(for: .touchUpInside); XCTAssertEqual(controller.model.settings.hand, .full)
    }
    func testClearAndRestoreNeverCoverNewCandidatesWithAStatusBanner() async throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        defer { controller.model.suspend() }
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 600)
        try await waitFor { controller.model.engineState == "离线就绪" }
        let delete = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyButton }.first { $0.key.action == .delete })
        for letter in "nihao" { controller.model.handle(.text(String(letter))) }
        delete.onDeleteSwipe?(true)
        delete.onDeleteSwipe?(false)
        XCTAssertEqual(controller.model.composition.raw, "nihao")
        delete.onDeleteSwipe?(true)
        for letter in "nihao" { controller.model.handle(.text(String(letter))) }
        try await waitFor { controller.model.candidatesAreCurrent }
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first)
        surface.layoutIfNeeded()
        let candidate = try XCTUnwrap(descendants(surface).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "candidate.你好" })
        XCTAssertTrue(candidate.isEnabled)
        let point = candidate.convert(CGPoint(x: candidate.bounds.midX, y: candidate.bounds.midY), to: surface)
        XCTAssertTrue(surface.hitTest(point, with: nil) === candidate, "New candidates must remain touchable immediately after clearing")
        XCTAssertFalse(descendants(surface).compactMap { $0 as? UILabel }.contains { ($0.text ?? "").hasPrefix("已清空") || ($0.text ?? "").hasPrefix("已恢复删除") })
    }
    func testDefaultKeyFacesAndSpacingMatchTheAirReferenceInEveryHandMode() throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        defer { controller.model.suspend() }
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first)
        for hand in HandMode.allCases {
            controller.model.settings.hand = hand
            surface.frame = CGRect(x: 0, y: 0, width: 420, height: surface.desiredHeight)
            surface.setNeedsLayout(); surface.layoutIfNeeded()
            let keys = descendants(surface).compactMap { $0 as? KeyButton }
            let q = try XCTUnwrap(keys.first { $0.key.action == .text("q") })
            let a = try XCTUnwrap(keys.first { $0.key.action == .text("a") })
            q.setNeedsLayout(); q.layoutIfNeeded()
            let face = try XCTUnwrap(q.subviews.compactMap { $0 as? UIVisualEffectView }.first)
            XCTAssertEqual(q.bounds.height, 56, accuracy: 0.1)
            XCTAssertEqual(face.bounds.height, 45, accuracy: 0.1)
            XCTAssertEqual(a.convert(a.bounds, to: surface).minY - q.convert(q.bounds, to: surface).minY, 56, accuracy: 0.1)
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
    func testLongAbbreviationAndUppercaseChineseLegends() async throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        defer { controller.model.suspend() }
        try await waitFor { controller.model.engineState == "离线就绪" }
        let spelling = String(repeating: "hd", count: 20)
        for letter in spelling { try tap(.text(String(letter)), in: controller.view) }
        try await waitFor { controller.model.candidatesAreCurrent }
        XCTAssertEqual(controller.textView.text, spelling)
        XCTAssertEqual(controller.model.candidates.first?.text, String(repeating: "好的", count: 20))
        let letters = descendants(controller.view).compactMap { $0 as? KeyButton }.filter {
            if case .text(let text) = $0.key.action { return text.count == 1 && text.first?.isLetter == true }; return false
        }
        XCTAssertEqual(letters.count, 26)
        XCTAssertTrue(letters.allSatisfy { $0.key.label == $0.key.label.uppercased() })
    }
    func testTrackpadDoesNotRefreshCandidatesPerStep() async throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        defer { controller.model.suspend() }
        try await waitFor { controller.model.candidatesAreCurrent }
        controller.insert("光标测试 👨‍👩‍👧‍👦 hello world")
        let original = controller.textView.text
        let onChange = controller.model.onChange
        var changes = 0
        controller.model.onChange = { changes += 1; onChange?() }
        controller.model.beginCursorMovement()
        for _ in 0..<10 { controller.model.moveCursor(-1) }
        for _ in 0..<10 { controller.model.moveCursor(1) }
        XCTAssertEqual(changes, 0, "Dragging must not query candidates or rebuild the keyboard on each move")
        XCTAssertEqual(controller.textView.text, original)
        controller.model.endCursorMovement(); XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(controller.textView.text, original)
    }
    func testClearAndUndoRestoresCompositionAndProtectsOtherDocument() async throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        defer { controller.model.suspend() }
        controller.insert("前文 👨‍👩‍👧‍👦 ")
        for letter in "nihao" { controller.model.handle(.text(String(letter))) }
        let text = controller.textView.text
        controller.model.clearInput()
        XCTAssertEqual(controller.textView.text, ""); XCTAssertTrue(controller.model.canUndoClearInput)
        XCTAssertTrue(controller.model.undoClearInput())
        XCTAssertEqual(controller.textView.text, text); XCTAssertEqual(controller.model.composition.raw, "nihao")
        XCTAssertNotNil(controller.textView.markedTextRange)
        controller.model.clearInput()
        let other = TypingLabController(settings: testSettings()); other.loadViewIfNeeded(); other.insert("其他输入框")
        defer { other.model.suspend() }
        controller.model.document = other
        XCTAssertFalse(controller.model.undoClearInput())
        XCTAssertEqual(other.textView.text, "其他输入框")
    }
    func testInlineArithmeticThroughKeyboardPages() async throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        defer { controller.model.suspend() }
        controller.model.handle(.page(.numbers))
        controller.model.handle(.text("9")); controller.model.handle(.text("9"))
        controller.model.handle(.page(.letters)); controller.model.handle(.text("x"))
        controller.model.handle(.page(.numbers))
        controller.model.handle(.text("8")); controller.model.handle(.text("8"))
        XCTAssertEqual(controller.textView.text, "99x88")
        XCTAssertEqual(controller.model.arithmetic?.candidates, ["8712", "99x88=8712"])
        let result = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "candidate.8712" })
        XCTAssertTrue(result.isEnabled); result.sendActions(for: .touchUpInside)
        XCTAssertEqual(controller.textView.text, "8712")
    }
    func testInputViewFitsOwnContentAndTransparentSurfaceHasOneOutline() throws {
        let controller = KeyboardViewController(nibName: nil, bundle: nil); controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 276)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        let input = try XCTUnwrap(controller.view as? KeyboardInputView)
        let surface = try XCTUnwrap(descendants(input).compactMap { $0 as? KeyboardSurface }.first)
        XCTAssertTrue(input.allowsSelfSizing)
        XCTAssertTrue(input.translatesAutoresizingMaskIntoConstraints)
        XCTAssertTrue(input.autoresizingMask.contains(.flexibleWidth))
        XCTAssertFalse(input.autoresizingMask.contains(.flexibleHeight))
        XCTAssertEqual(input.systemLayoutSizeFitting(CGSize(width: 393, height: 0)).height, surface.desiredHeight, accuracy: 1)
        XCTAssertTrue(surface.systemBacked); XCTAssertFalse(surface.isOpaque)
        XCTAssertEqual(surface.layer.cornerRadius, 0)
        let backdrop = try XCTUnwrap(surface.subviews.compactMap { $0 as? GlassBackdrop }.first)
        XCTAssertLessThan(backdrop.backgroundColor?.cgColor.alpha ?? 0, 0.1)
        XCTAssertFalse(backdrop.isOpaque)
    }
    func testBrowserSafeAreaDoesNotAlterRequestedKeyboardContentHeight() throws {
        let controller = KeyboardViewController(nibName: nil, bundle: nil); controller.loadViewIfNeeded()
        let input = try XCTUnwrap(controller.view as? KeyboardInputView)
        let surface = try XCTUnwrap(descendants(input).compactMap { $0 as? KeyboardSurface }.first)
        for inset: CGFloat in [0, 34, 75, 108] {
            controller.additionalSafeAreaInsets.bottom = inset
            controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: surface.desiredHeight)
            controller.view.setNeedsUpdateConstraints(); controller.view.updateConstraintsIfNeeded()
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            XCTAssertEqual(input.systemLayoutSizeFitting(CGSize(width: 420, height: 0)).height, surface.desiredHeight, accuracy: 0.5)
            XCTAssertEqual(controller.preferredContentSize.height, surface.desiredHeight, accuracy: 0.5)
            XCTAssertEqual(surface.bounds.height, surface.desiredHeight, accuracy: 0.5)
            let constraint = try XCTUnwrap(input.constraints.first { $0.identifier == "clear.keyboard.content-height" })
            XCTAssertEqual(constraint.priority, .required)
            for key in descendants(surface).compactMap({ $0 as? KeyButton }) { XCTAssertGreaterThanOrEqual(key.bounds.height, 50) }
        }
    }
    func testCachedSafariFramesNeverCompressTheExtensionKeys() throws {
        let controller = KeyboardViewController(nibName: nil, bundle: nil); controller.loadViewIfNeeded()
        let input = try XCTUnwrap(controller.view as? KeyboardInputView)
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first)
        let q = try XCTUnwrap(descendants(surface).compactMap { $0 as? KeyButton }.first { $0.accessibilityIdentifier == "key.text.q" })
        let a = try XCTUnwrap(descendants(surface).compactMap { $0 as? KeyButton }.first { $0.accessibilityIdentifier == "key.text.a" })
        for height: CGFloat in [216, 245, 276, 330, 701, 245, 276] {
            controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: height)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded(); surface.layoutIfNeeded()
            XCTAssertEqual(surface.bounds.height, surface.desiredHeight, accuracy: 0.5)
            XCTAssertEqual(surface.frame.minY, max(0, controller.view.bounds.height - surface.desiredHeight), accuracy: 0.5)
            XCTAssertEqual(input.sizeThatFits(CGSize(width: 420, height: height)).height, surface.desiredHeight, accuracy: 0.5)
            XCTAssertEqual(input.systemLayoutSizeFitting(CGSize(width: 420, height: height)).height, surface.desiredHeight, accuracy: 0.5)
            XCTAssertEqual(input.intrinsicContentSize.height, surface.desiredHeight, accuracy: 0.5)
            XCTAssertEqual(q.bounds.height, 56, accuracy: 0.5)
            XCTAssertEqual(a.frame.minY - q.frame.minY, 56, accuracy: 0.5)
            XCTAssertEqual(KeyboardGeometry.keyPlate(in: q.bounds).height, 45, accuracy: 0.5)
        }
    }
    func testTypoSentenceAppearsInCandidatesAndCommitsCorrectedChinese() async throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        defer { controller.model.suspend() }
        try await waitFor { controller.model.engineState == "离线就绪" }
        let spelling = "nichifnalemeilaopo"
        for letter in spelling { controller.model.handle(.text(String(letter))) }
        XCTAssertEqual(controller.textView.text, spelling, "Spelling repairs must not rewrite the host's active pinyin")
        try await waitFor { controller.model.candidatesAreCurrent }
        let candidate = try XCTUnwrap(controller.model.candidates.first)
        XCTAssertEqual(candidate.text, "你吃饭了没老婆")
        controller.model.choose(candidate)
        XCTAssertEqual(controller.textView.text, "你吃饭了没老婆")
        XCTAssertNil(controller.textView.markedTextRange)
    }
    func testSystemPasteControlSavesProvidedTextWithoutReadingClipboard() async throws {
        let suite = "clear.paste.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), url = root.appendingPathComponent("clips.json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var reads = 0
        let capture = ClipboardCapture(defaults: defaults, makeStore: { ClipboardStore(url: url) }, changeCount: { 1 }, hasStrings: { true }, readText: { reads += 1; return "should not be read" })
        let button = ClipboardPasteButton(capture: capture)
        let system = try XCTUnwrap(descendants(button).compactMap { $0 as? UIPasteControl }.first)
        let receiver = try XCTUnwrap(system.target as? UIResponder)
        receiver.paste(itemProviders: [NSItemProvider(object: "系统粘贴保存" as NSString)])
        try await waitFor { ClipboardStore(url: url).clips.first?.text == "系统粘贴保存" }
        XCTAssertEqual(reads, 0, "System paste payloads must not trigger a second programmatic clipboard read")
    }
    func testRapidLongTypingProducesLatestCandidates() async throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        defer { controller.model.suspend() }
        try await waitFor { controller.model.engineState == "离线就绪" }
        let spelling = String(repeating: "hd", count: 50)
        let start = ProcessInfo.processInfo.systemUptime
        for letter in spelling { controller.model.handle(.text(String(letter))) }
        try await waitFor { controller.model.candidatesAreCurrent }
        XCTAssertEqual(controller.model.composition.raw, spelling)
        XCTAssertEqual(controller.model.candidates.first?.text, String(repeating: "好的", count: 50))
        XCTAssertEqual(controller.model.candidates.first?.consumed, spelling.count)
        print("RAPID_TYPING_100_KEYS_MS \((ProcessInfo.processInfo.systemUptime-start)*1000)")
    }
    func testTrackpadUsesRealVisualLinesInTypingLab() throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 700)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        defer { controller.model.suspend() }
        let text = String(repeating: "hello world ", count: 14)
        controller.insert(text)
        let selection = try XCTUnwrap(controller.textView.selectedTextRange)
        let original = controller.textView.caretRect(for: selection.end)
        let lineHeight = try XCTUnwrap(controller.textView.font).lineHeight
        controller.model.beginCursorMovement()
        var changes = 0; controller.model.onChange = { changes += 1 }
        controller.model.trackCursor(translation: CGPoint(x: 0, y: -lineHeight))
        let moved = try XCTUnwrap(controller.textView.selectedTextRange)
        XCTAssertLessThan(controller.textView.caretRect(for: moved.end).midY, original.midY)
        XCTAssertLessThan(controller.textView.selectedRange.location, text.utf16.count)
        XCTAssertEqual(changes, 0)
        controller.model.trackCursor(translation: .zero)
        XCTAssertEqual(controller.textView.selectedRange.location, text.utf16.count)
        controller.model.endCursorMovement(); XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(controller.textView.text, text)
    }
    func testGlassShowsContentBehindKeyboard() async throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); let host = UIViewController(); host.view.backgroundColor = .systemBackground
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; controller.model.suspend() }
        let backdrop = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 276))
        let gradient = CAGradientLayer(); gradient.frame = backdrop.bounds
        gradient.colors = [UIColor.systemOrange.withAlphaComponent(0.7).cgColor, UIColor.systemTeal.withAlphaComponent(0.8).cgColor, UIColor.systemBlue.withAlphaComponent(0.7).cgColor]
        gradient.startPoint = .zero; gradient.endPoint = CGPoint(x: 1, y: 1); backdrop.layer.addSublayer(gradient)
        let label = UILabel(frame: CGRect(x: 40, y: 70, width: 310, height: 130)); label.text = "你好\nHELLO"; label.numberOfLines = 2; label.textAlignment = .center; label.font = .systemFont(ofSize: 48, weight: .bold); label.textColor = UIColor.white.withAlphaComponent(0.5); backdrop.addSubview(label)
        host.view.addSubview(backdrop)
        let surface = KeyboardSurface(model: controller.model, systemBacked: true); surface.frame = backdrop.frame; host.view.addSubview(surface)
        surface.layoutIfNeeded(); snapshot(surface.superview!, name: "glass-transparency")
    }
}
