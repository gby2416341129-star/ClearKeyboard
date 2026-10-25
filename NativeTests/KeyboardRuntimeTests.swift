import XCTest
import UIKit
import SwiftUI

@MainActor final class KeyboardRuntimeTests: XCTestCase {
    private func testSettings() -> KeyboardSettings { var settings = KeyboardSettings(); settings.automaticClipboard = false; return settings }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants($0) } }
    private func settleLayout(_ view: UIView) {
        // The first pass installs fitting constraints; a normal run loop then lays them out.
        // These detached fixtures explicitly perform both passes before inspecting frames.
        for _ in 0..<2 {
            view.setNeedsUpdateConstraints(); view.updateConstraintsIfNeeded()
            view.setNeedsLayout(); view.layoutIfNeeded()
        }
    }
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
        try await waitFor { self.descendants(controller.view).compactMap { $0 as? UIButton }.contains { $0.accessibilityIdentifier == "candidate.你好" } }
        XCTAssertTrue(descendants(controller.view).compactMap { $0 as? UILabel }.contains { $0.text == "你好" && !$0.isHidden }, "Chinese candidate ink did not render")
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
            XCTAssertFalse(descendants(surface).compactMap { $0 as? UIButton }.contains { !$0.isHidden && $0.title(for: .normal) == "完成" })
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
        try await waitFor { self.descendants(surface).compactMap { $0 as? UIButton }.contains { $0.accessibilityIdentifier == "candidate.你好" && !$0.isHidden } }
        let candidate = try XCTUnwrap(descendants(surface).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "candidate.你好" })
        XCTAssertTrue(candidate.isEnabled)
        let point = candidate.convert(CGPoint(x: candidate.bounds.midX, y: candidate.bounds.midY), to: surface)
        let scroll = try XCTUnwrap(descendants(surface).compactMap { $0 as? CandidateScrollView }.first)
        XCTAssertTrue(surface.hitTest(point, with: nil) === scroll, "Word taps must reach the same row surface as gap drags")
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
            let face = try XCTUnwrap(q.subviews.first { $0.accessibilityIdentifier == "key.face" })
            XCTAssertEqual(q.bounds.height, 56, accuracy: 0.1)
            XCTAssertEqual(face.bounds.height, 45, accuracy: 0.1)
            XCTAssertEqual(a.convert(a.bounds, to: surface).minY - q.convert(q.bounds, to: surface).minY, 56, accuracy: 0.1)
        }
    }
    func testBottomRowSpaceIsCenteredAndLanguageStillSwitchesWithOneTap() throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        defer { controller.model.suspend() }
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first)
        for hand in HandMode.allCases {
            controller.model.settings.hand = hand
            surface.frame = CGRect(x: 0, y: 0, width: 420, height: surface.desiredHeight)
            settleLayout(surface)
            let space = try XCTUnwrap(descendants(surface).compactMap { $0 as? KeyButton }.first { $0.key.action == .space })
            let layout = KeyboardGeometry.layout(size: surface.bounds.size, metrics: .init(), hand: hand)
            let hit = space.convert(space.bounds, to: surface)
            let plate = try XCTUnwrap(space.subviews.first { $0.accessibilityIdentifier == "key.face" })
            space.layoutIfNeeded()
            XCTAssertEqual(hit.midX, layout.keys.midX, accuracy: 0.1)
            XCTAssertEqual(plate.convert(plate.bounds, to: surface).midX, layout.keys.midX, accuracy: 0.1)
            XCTAssertEqual(hit.height, 56, accuracy: 0.1)
            controller.model.settings.language = .chinese
            try tap(.language, in: surface)
            XCTAssertEqual(controller.model.settings.language, .english)
            try tap(.language, in: surface)
            XCTAssertEqual(controller.model.settings.language, .chinese)
        }
    }
    func testNeutralKeyFacesRemainTranslucentAndSolidFallbackIsOpaque() throws {
        let lens = LiquidGlassView(radius: 8)
        lens.configure(tint: nil, strength: 0.5, fallback: .gray, reduced: false)
        if #available(iOS 26.0, *) { XCTAssertTrue(lens.effect is UIGlassEffect) }
        lens.configure(tint: nil, strength: 0.5, fallback: .gray, reduced: true)
        XCTAssertNil(lens.effect)
        XCTAssertEqual(lens.backgroundColor?.cgColor.alpha ?? 0, 1, accuracy: 0.001)
    }
    func testCandidateAccentRemainsReadableOnLightAndDarkMaterials() {
        func linear(_ value: CGFloat) -> Double {
            let v = Double(value); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            for hex in ["#298A70", "#3370B8", "#AF5278", "#646E7A", "#FFFFFF", "#000000", "#FF00FF"] {
                var settings = testSettings(); settings.customAccentHex = hex
                let color = settings.accentInkColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                color.getRed(&r, green: &g, blue: &b, alpha: &a)
                let ink = linear(r)*0.2126 + linear(g)*0.7152 + linear(b)*0.0722
                let background = linear(style == .dark ? 0.18 : 0.97)
                XCTAssertGreaterThanOrEqual((max(ink, background)+0.05)/(min(ink, background)+0.05), 4.5, hex)
            }
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
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 600)
        settleLayout(controller.view)
        controller.model.handle(.page(.numbers))
        controller.model.handle(.text("9")); controller.model.handle(.text("9"))
        controller.model.handle(.page(.letters)); controller.model.handle(.text("x"))
        controller.model.handle(.page(.numbers))
        controller.model.handle(.text("8")); controller.model.handle(.text("8"))
        XCTAssertEqual(controller.textView.text, "99x88")
        XCTAssertEqual(controller.model.arithmetic?.candidates, ["8712", "99x88=8712"])
        settleLayout(controller.view)
        try await waitFor { self.descendants(controller.view).compactMap { $0 as? UIButton }.contains { $0.accessibilityIdentifier == "candidate.8712" && !$0.isHidden } }
        let result = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "candidate.8712" })
        let point = result.convert(CGPoint(x: result.bounds.midX, y: result.bounds.midY), to: controller.view)
        let scroll = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? CandidateScrollView }.first)
        XCTAssertTrue(controller.view.hitTest(point, with: nil) === scroll)
        scroll.selectCandidate(at: scroll.convert(point, from: controller.view))
        XCTAssertEqual(controller.textView.text, "8712")
    }
    func testInputViewFitsOwnContentAndTransparentSurfaceHasOneOutline() throws {
        let controller = KeyboardViewController(nibName: nil, bundle: nil); controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 276)
        settleLayout(controller.view)
        let input = try XCTUnwrap(controller.inputView)
        let surface = try XCTUnwrap(descendants(input).compactMap { $0 as? KeyboardSurface }.first)
        XCTAssertTrue(input.allowsSelfSizing)
        XCTAssertFalse(input.translatesAutoresizingMaskIntoConstraints)
        XCTAssertEqual(input.constraints.filter { $0.identifier == "clear.keyboard.content-height" }.count, 1)
        XCTAssertEqual(input.systemLayoutSizeFitting(.zero).height, surface.desiredHeight, accuracy: 0.5)
        XCTAssertEqual(input.systemLayoutSizeFitting(.zero).width, 393, accuracy: 0.5)
        XCTAssertEqual(controller.preferredContentSize, .zero)
        XCTAssertTrue(surface.systemBacked); XCTAssertFalse(surface.isOpaque)
        XCTAssertEqual(surface.layer.cornerRadius, 0)
        XCTAssertFalse(input.subviews.contains { $0 is UIVisualEffectView }, "The extension must use the system base without a custom background layer")
    }
    private func materialImage(_ view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        let target = view.window ?? view
        let image = UIGraphicsImageRenderer(bounds: target.bounds, format: format).image { _ in
            XCTAssertTrue(target.drawHierarchy(in: target.bounds, afterScreenUpdates: true))
        }
        let rect = view.convert(view.bounds, to: target)
        guard let cropped = image.cgImage?.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped)
    }
    private func materialPixel(_ image: UIImage, at point: CGPoint) throws -> [Int] {
        let bitmap = try XCTUnwrap(image.cgImage)
        let pixel = try XCTUnwrap(bitmap.cropping(to: CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.map(Int.init)
    }
    private func pixelDistance(_ left: [Int], _ right: [Int]) -> Int {
        zip(left.prefix(3), right.prefix(3)).map { abs($0 - $1) }.max() ?? 0
    }
    func testAppearancePreviewUsesOneUniformlyScaledKeyboardCanvas() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        let preview = KeyboardAppearancePreview(frame: CGRect(x: 20, y: 100, width: 350, height: 276))
        host.view.addSubview(preview)
        let canvas = try XCTUnwrap(descendants(preview).first { $0.accessibilityIdentifier == "appearance.keyboard-canvas" })
        XCTAssertFalse(descendants(preview).contains { $0.accessibilityIdentifier == "appearance.native-base" })
        let keys = descendants(preview).compactMap { $0 as? KeyButton }
        let q = try XCTUnwrap(keys.first { $0.key.action == .text("q") })
        let a = try XCTUnwrap(keys.first { $0.key.action == .text("a") })
        let shift = try XCTUnwrap(keys.first { $0.key.action == .shift })
        func assertRenderedContrast(_ key: KeyButton, phase: String, expectedDarkFace: Bool? = nil) throws {
            settleLayout(key)
            let face = try XCTUnwrap(descendants(key).first { $0.accessibilityIdentifier == "key.face" })
            let image = materialImage(key)
            let bitmap = try XCTUnwrap(image.cgImage)
            let scaleX = CGFloat(bitmap.width) / key.bounds.width
            let scaleY = CGFloat(bitmap.height) / key.bounds.height
            let faceRect = face.convert(face.bounds, to: key).applying(CGAffineTransform(scaleX: scaleX, y: scaleY))
            // Inspect the composited window crop in its actual display size,
            // below the glass rim and above the glyph, with no isolated lens
            // snapshot or native-coordinate samples on a scaled preview.
            let base = try materialPixel(image, at: CGPoint(x: faceRect.midX, y: faceRect.minY + 6 * scaleY))
            XCTAssertGreaterThan(base[3], 250, phase)
            if let expectedDarkFace {
                if expectedDarkFace { XCTAssertLessThan(base.prefix(3).max() ?? 255, 160, phase) }
                else { XCTAssertGreaterThan(base.prefix(3).min() ?? 0, 200, phase) }
            }
            var pixels = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: bitmap.width, height: bitmap.height,
                    bitsPerComponent: 8, bytesPerRow: bitmap.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
            }
            func luminance(_ red: Int, _ green: Int, _ blue: Int) -> Double {
                func linear(_ byte: Int) -> Double {
                    let value = Double(byte) / 255
                    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                return linear(red) * 0.2126 + linear(green) * 0.7152 + linear(blue) * 0.0722
            }
            let background = luminance(base[0], base[1], base[2])
            let glyphArea = faceRect.insetBy(dx: 8 * scaleX, dy: 8 * scaleY).intersection(CGRect(x: 0,y: 0,width: bitmap.width,height: bitmap.height))
            var visibleInkPixels = 0
            for y in max(0, Int(ceil(glyphArea.minY)))..<min(bitmap.height, Int(floor(glyphArea.maxY))) {
                for x in max(0, Int(ceil(glyphArea.minX)))..<min(bitmap.width, Int(floor(glyphArea.maxX))) {
                    let offset = (y * bitmap.width + x) * 4
                    let ink = luminance(Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
                    let ratio = (max(ink, background) + 0.05) / (min(ink, background) + 0.05)
                    let requiredContrast = key.key.action == .shift || key.key.action == .delete ? 3.0 : 4.5
                    if pixels[offset + 3] > 240 && ratio >= requiredContrast { visibleInkPixels += 1 }
                }
            }
            XCTAssertGreaterThanOrEqual(visibleInkPixels, 4, "\(phase): rendered letters and symbols must remain distinct from their actual face")
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style; host.view.backgroundColor = .systemBackground
            var settings = testSettings()
            for keyHeight: Double in [44, 50, 58] {
                settings.keyHeight = keyHeight
                for size in [CGSize(width: 350, height: 166), CGSize(width: 350, height: 250), CGSize(width: 250, height: 130)] {
                    preview.frame.size = size; preview.apply(settings); settleLayout(preview)
                    for key in keys { settleLayout(key) }
                    let pitch = KeyboardGeometry.Metrics(keyHeight: keyHeight).rowPitch
                    XCTAssertEqual(q.bounds.height, pitch, accuracy: 0.01)
                    XCTAssertEqual(a.frame.minY - q.frame.minY, pitch, accuracy: 0.01)
                    XCTAssertEqual(canvas.transform.a, canvas.transform.d, accuracy: 0.00001,
                        "Keys, candidates and symbols must share a single scale rather than compressing rows")
                    XCTAssertEqual(canvas.transform.b, 0); XCTAssertEqual(canvas.transform.c, 0)
                    let scale = canvas.transform.a
                    XCTAssertEqual(q.convert(q.bounds, to: preview).height, pitch * scale, accuracy: 0.1)
                    XCTAssertEqual(shift.convert(shift.bounds, to: preview).height, pitch * scale, accuracy: 0.1)
                    XCTAssertTrue(preview.bounds.insetBy(dx: -0.1, dy: -0.1).contains(canvas.frame))
                    let caption = try XCTUnwrap(descendants(q).compactMap { $0 as? CenteredKeyLabel }.first)
                    XCTAssertEqual(caption.font.pointSize, 23, accuracy: 0.1)
                    XCTAssertEqual(caption.layer.contentsScale, window.screen.scale * scale, accuracy: 0.01)
                    let fitted = preview.fittingSize(forWidth: size.width)
                    XCTAssertEqual(fitted.height / fitted.width, canvas.bounds.height / canvas.bounds.width, accuracy: 0.0001)
                }
            }
            settings.keyHeight = 50; settings.candidateColorHex = "#558DF2"
            preview.apply(settings)
            preview.frame.size = preview.fittingSize(forWidth: 350)
            settleLayout(preview)
            try assertRenderedContrast(q, phase: "preview \(style) Q", expectedDarkFace: style == .dark)
            try assertRenderedContrast(shift, phase: "preview \(style) Shift", expectedDarkFace: style == .dark)
            snapshot(preview, name: "preview-proportional-\(style == .dark ? "dark" : "light")")
        }
        // No settings write accompanies this trait change. A key must update
        // from its own inherited trait, not wait for a parent's render pass.
        window.overrideUserInterfaceStyle = .light; settleLayout(window)
        try assertRenderedContrast(q, phase: "dark-to-light Q", expectedDarkFace: false)
        try assertRenderedContrast(shift, phase: "dark-to-light Shift", expectedDarkFace: false)

        // Cold SwiftUI previews can receive settings before joining a window.
        // Their initial unspecified/light face must not survive dark adoption.
        window.overrideUserInterfaceStyle = .dark
        let cold = KeyboardAppearancePreview(frame: CGRect(x: 20, y: 100, width: 350, height: 230))
        var coldSettings = testSettings(); 
        cold.apply(coldSettings)
        host.view.addSubview(cold); cold.frame.size = cold.fittingSize(forWidth: 350); settleLayout(cold)
        let coldKeys = descendants(cold).compactMap { $0 as? KeyButton }
        let coldQ = try XCTUnwrap(coldKeys.first { $0.key.action == .text("q") })
        let coldShift = try XCTUnwrap(coldKeys.first { $0.key.action == .shift })
        try assertRenderedContrast(coldQ, phase: "apply-before-window dark Q", expectedDarkFace: true)
        try assertRenderedContrast(coldShift, phase: "apply-before-window dark Shift", expectedDarkFace: true)
        snapshot(cold, name: "preview-contrast-cold-dark")
        coldSettings.keyColorHex = "#FFFFFF"; cold.apply(coldSettings); settleLayout(cold)
        try assertRenderedContrast(coldQ, phase: "explicit white key dark Q")
        try assertRenderedContrast(coldShift, phase: "explicit white key dark Shift")
        snapshot(cold, name: "preview-contrast-cold-dark-white-keys")
    }
    func testKeyboardObeysHostWidthInsideALargerWindow() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let controller = KeyboardViewController(nibName: nil, bundle: nil)
        host.addChild(controller); controller.loadViewIfNeeded()
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(controller.view); controller.didMove(toParent: host)
        let width = controller.view.widthAnchor.constraint(equalToConstant: 320)
        width.identifier = "test.host-width"
        NSLayoutConstraint.activate([width,
            controller.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            controller.view.topAnchor.constraint(equalTo: host.view.topAnchor)])
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first)
        let q = try XCTUnwrap(descendants(surface).compactMap { $0 as? KeyButton }.first { $0.key.action == .text("q") })
        for hostWidth: CGFloat in [320, 360, 320] {
            width.constant = hostWidth
            settleLayout(host.view); settleLayout(controller.view)
            XCTAssertEqual(controller.view.bounds.width, hostWidth, accuracy: 0.5)
            XCTAssertEqual(surface.bounds.width, hostWidth, accuracy: 0.5)
            XCTAssertEqual(surface.bounds.height, surface.desiredHeight, accuracy: 0.5)
            XCTAssertEqual(q.bounds.height, 56, accuracy: 0.5)
            let fallback = try XCTUnwrap(controller.view.constraints.first { $0.identifier == "clear.keyboard.system-width" })
            XCTAssertLessThan(fallback.priority.rawValue, width.priority.rawValue)
            XCTAssertEqual(fallback.constant, hostWidth, accuracy: 0.5)
            XCTAssertEqual(controller.view.constraints.filter { $0.identifier == "clear.keyboard.content-height" }.count, 1)
        }
    }
    func testTypingAndHandChangesDoNotRenegotiateHeight() throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        defer { controller.model.suspend() }
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first)
        var heights: [CGFloat] = []
        surface.onHeightChange = { heights.append($0) }
        for hand in HandMode.allCases {
            controller.model.settings.hand = hand
            controller.model.handle(.text("n")); controller.model.handle(.delete)
            surface.render()
        }
        XCTAssertTrue(heights.isEmpty)
        controller.model.settings.keyHeight = 58
        XCTAssertEqual(heights, [308])
        surface.render(); surface.render()
        XCTAssertEqual(heights, [308])
        controller.model.settings.keyHeight = 50
        XCTAssertEqual(heights, [308, 276])
    }
    func testBrowserSafeAreaDoesNotAlterRequestedKeyboardContentHeight() throws {
        let controller = KeyboardViewController(nibName: nil, bundle: nil); controller.loadViewIfNeeded()
        let input = try XCTUnwrap(controller.inputView)
        let surface = try XCTUnwrap(descendants(input).compactMap { $0 as? KeyboardSurface }.first)
        for inset: CGFloat in [0, 34, 75, 108] {
            controller.additionalSafeAreaInsets.bottom = inset
            controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: surface.desiredHeight)
            settleLayout(controller.view)
            XCTAssertTrue(input.allowsSelfSizing)
            XCTAssertEqual(controller.preferredContentSize, .zero)
            XCTAssertEqual(surface.bounds.height, surface.desiredHeight, accuracy: 0.5)
            let constraint = try XCTUnwrap(input.constraints.first { $0.identifier == "clear.keyboard.content-height" })
            XCTAssertEqual(constraint.priority, .required)
            XCTAssertEqual(constraint.constant, surface.desiredHeight, accuracy: 0.5)
            for key in descendants(surface).compactMap({ $0 as? KeyButton }) { XCTAssertGreaterThanOrEqual(key.bounds.height, 50) }
        }
    }
    func testCachedSafariFramesNeverCompressTheExtensionKeys() throws {
        let controller = KeyboardViewController(nibName: nil, bundle: nil); controller.loadViewIfNeeded()
        let input = try XCTUnwrap(controller.inputView)
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first)
        let q = try XCTUnwrap(descendants(surface).compactMap { $0 as? KeyButton }.first { $0.accessibilityIdentifier == "key.text.q" })
        let a = try XCTUnwrap(descendants(surface).compactMap { $0 as? KeyButton }.first { $0.accessibilityIdentifier == "key.text.a" })
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: surface.desiredHeight)
        settleLayout(controller.view)
        for height: CGFloat in [216, 245, 276, 330, 701, 245, 276] {
            controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: height)
            settleLayout(controller.view); surface.layoutIfNeeded()
            XCTAssertEqual(surface.bounds.height, surface.desiredHeight, accuracy: 0.5)
            XCTAssertEqual(surface.frame.minY, controller.view.bounds.height - surface.desiredHeight, accuracy: 0.5)
            XCTAssertEqual(input.constraints.filter { $0.identifier == "clear.keyboard.content-height" }.count, 1)
            XCTAssertEqual(input.systemLayoutSizeFitting(.zero).height, surface.desiredHeight, accuracy: 0.5)
            XCTAssertEqual(controller.preferredContentSize, .zero)
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
    func testLegalPinyinTypoCommitsCorrectChineseWithoutChangingLayout() async throws {
        var settings = testSettings(); settings.learnChoices = false
        let controller = TypingLabController(settings: settings); controller.loadViewIfNeeded()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        defer { controller.model.suspend() }
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 700)
        try await waitFor { controller.model.engineState == "离线就绪" }
        let spelling = "nichifankema"
        for letter in spelling { controller.model.handle(.text(String(letter))) }
        try await waitFor { controller.model.candidatesAreCurrent }
        settleLayout(controller.view)
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first)
        surface.layoutIfNeeded()
        let q = try XCTUnwrap(descendants(surface).compactMap { $0 as? KeyButton }.first { $0.key.action == .text("q") })
        XCTAssertEqual(surface.desiredHeight, 276)
        XCTAssertEqual(q.bounds.height, 56, accuracy: 0.5)
        XCTAssertEqual(controller.textView.text, spelling)
        XCTAssertNotNil(controller.textView.markedTextRange)
        XCTAssertEqual(controller.model.candidates.first?.text, "你吃饭了吗")
        try await waitFor { self.descendants(surface).compactMap { $0 as? UIButton }.contains { $0.accessibilityIdentifier == "candidate.你吃饭了吗" && !$0.isHidden } }
        let candidate = try XCTUnwrap(descendants(surface).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "candidate.你吃饭了吗" })
        XCTAssertTrue(candidate.isEnabled); candidate.sendActions(for: .touchUpInside)
        XCTAssertEqual(controller.textView.text, "你吃饭了吗")
        XCTAssertNil(controller.textView.markedTextRange)
    }
    func testMixedInitialsTypoRendersAndCommitsWithoutChangingHostPinyin() async throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        defer { controller.model.suspend() }
        try await waitFor { controller.model.engineState == "离线就绪" }
        let spelling = "nichifankm"
        for letter in spelling { controller.model.handle(.text(String(letter))) }
        try await waitFor { controller.model.candidatesAreCurrent }
        XCTAssertEqual(controller.textView.text, spelling)
        XCTAssertEqual(controller.model.candidates.first?.text, "你吃饭了吗")
        try tap(.space, in: controller.view)
        XCTAssertEqual(controller.textView.text, "你吃饭了吗")
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
    func testHeldLetterSurvivesCaseChangesWithoutReplacingItsView() throws {
        var settings = testSettings(); settings.language = .english; settings.autoCapitalization = false
        let controller = TypingLabController(settings: settings); controller.loadViewIfNeeded()
        let key = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyButton }.first { $0.key.action == .text("a") })
        key.sendActions(for: .touchDown); controller.model.handle(.shift)
        let after = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyButton }.first { $0.key.action == .text("a") })
        XCTAssertTrue(key === after)
        key.sendActions(for: .touchUpInside)
        XCTAssertEqual(controller.textView.text, "A")
    }
    func testCandidateRefreshDuringScrollKeepsTheVisibleControlsAndOffset() async throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        try await waitFor { controller.model.engineState == "离线就绪" }
        for ch in "shi" { controller.model.handle(.text(String(ch))) }
        try await waitFor { controller.model.candidatesAreCurrent }
        settleLayout(controller.view)
        let button = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier?.hasPrefix("candidate.") == true })
        let scroll = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? CandidateScrollView }.first)
        XCTAssertFalse(scroll.delaysContentTouches); XCTAssertTrue(scroll.touchesShouldCancel(in: button))
        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        scroll.contentOffset = CGPoint(x: 32, y: 0)
        controller.model.refreshCandidates()
        try await waitFor { controller.model.candidatesAreCurrent }
        XCTAssertTrue(descendants(controller.view).contains { $0 === button })
        XCTAssertEqual(scroll.contentOffset.x, 32, accuracy: 0.1)
        scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: true)
        scroll.delegate?.scrollViewDidEndDecelerating?(scroll)
        XCTAssertEqual(scroll.contentOffset.x, 32, accuracy: 0.1)
    }
    func testImmediateSpaceAndFollowingKeysKeepEnglishInChineseMode() async throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        try await waitFor { controller.model.engineState == "离线就绪" }
        for ch in "iphone" { controller.model.handle(.text(String(ch))) }
        controller.model.handle(.space)
        for ch in "wodeiphone" { controller.model.handle(.text(String(ch))) }
        controller.model.handle(.space)
        try await waitFor { controller.model.composition.isEmpty && controller.textView.text == "iphone我的iphone" }
        XCTAssertEqual(controller.model.settings.language, .chinese)
    }
    func testToolbarArtworkHasMatchingVisibleFootprints() async throws {
        func alphaBounds(_ image: UIImage, brand: Bool = false) throws -> CGRect {
            let cg = try XCTUnwrap(image.cgImage); let width = cg.width, height = cg.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            try pixels.withUnsafeMutableBytes { raw in
                let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            }
            var minX = width, minY = height, maxX = 0, maxY = 0
            var visibleAlpha: [UInt8] = []
            for y in 0..<height { for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 24 {
                visibleAlpha.append(pixels[(y * width + x) * 4 + 3])
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            } }
            visibleAlpha.sort()
            XCTAssertFalse(visibleAlpha.isEmpty)
            if !visibleAlpha.isEmpty {
                if brand {
                    XCTAssertLessThan(visibleAlpha[visibleAlpha.count/2],128,"Keep the approved organic brand material translucent")
                    XCTAssertLessThan(visibleAlpha.last!,230,"Keep the approved organic brand's thin translucent rim")
                }
                XCTAssertLessThan(visibleAlpha.count,width*height,"The selected glyphs retain transparent outer corners")
            }
            return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
        }
        let symbols = ["character.bubble.fill", "doc.on.clipboard.fill", "face.smiling.fill", "keyboard.fill", "paintpalette.fill", "rectangle.3.group.fill", "desktopcomputer", "key.glass", "key.color", "candidate.color", "candidate.size"]
        // Match the shared keyline, not both dimensions: a clipboard must
        // retain its portrait silhouette instead of being padded with a disk.
        for size in [CGFloat(20), 28, 32] {
            let artwork = symbols.map { symbol in
                let source = ToolArtwork.image(symbol: symbol,size: size,scale: 3)
                let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = false
                return UIGraphicsImageRenderer(size: CGSize(width: size,height: size),format: format).image { _ in
                    source.draw(in: CGRect(x: 0,y: 0,width: size,height: size))
                }
            } + [ToolArtwork.brand(size: size)]
            let bounds = try artwork.enumerated().map { try alphaBounds($0.element,brand: $0.offset == symbols.count) }
            let sides = bounds.map { max($0.width,$0.height) }
            XCTAssertLessThan(sides.max()! / sides.min()!, 1.20)
            for rect in bounds {
                XCTAssertGreaterThanOrEqual(max(rect.width,rect.height),size*3*0.68)
                XCTAssertLessThanOrEqual(max(rect.width,rect.height),ceil(size*3*0.95))
                XCTAssertLessThan(abs(rect.midX-size*1.5),size*0.12)
                XCTAssertLessThan(abs(rect.midY-size*1.5),size*0.12)
            }
        }
        let names = ["语言", "剪贴板", "表情", "单手", "外观", "工具栏", "兼容输入", "按键玻璃", "按键颜色", "文字颜色", "文字大小", "澈"]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKey() }
        for style in [UIUserInterfaceStyle.light,.dark] {
            let dark = style == .dark
            window.overrideUserInterfaceStyle = style
            let controller = UIViewController(); window.rootViewController = controller
            controller.view.backgroundColor = dark ? UIColor(white: 0.085,alpha: 1) : UIColor(red: 0.96,green: 0.96,blue: 0.98,alpha: 1)
            let canvas = UIView(frame: CGRect(x: 0,y: 80,width: 420,height: 352)); controller.view.addSubview(canvas)
            canvas.backgroundColor = controller.view.backgroundColor
            // An actual host backdrop, only in this visual fixture: the color
            // boundary must remain visible through the native glass symbols.
            for column in 0..<12 {
                let stripe = UIView(frame: CGRect(x: CGFloat(column)*35,y: 176,width: 35,height: 176))
                stripe.backgroundColor = column%2 == 0
                    ? UIColor(red: dark ? 0.12 : 0.58,green: dark ? 0.25 : 0.69,blue: dark ? 0.43 : 0.88,alpha: 1)
                    : UIColor(red: dark ? 0.36 : 0.85,green: dark ? 0.18 : 0.60,blue: dark ? 0.28 : 0.70,alpha: 1)
                canvas.addSubview(stripe)
            }
            for group in 0..<2 { for index in names.indices {
                let x = CGFloat(index%6)*70, y = CGFloat(group*176+(index/6)*84)
                let icon: UIView = index < symbols.count ? ToolIconView(symbol: symbols[index]) : UIImageView(image: ToolArtwork.brand(size: 32))
                icon.frame = CGRect(x: x+19,y: y+12,width: 32,height: 32); canvas.addSubview(icon)
                let label = UILabel(frame: CGRect(x: x+2,y: y+53,width: 66,height: 20)); label.text = names[index]
                label.textAlignment = .center; label.font = .systemFont(ofSize: 11); label.textColor = dark ? .white : UIColor(white: 0.12,alpha: 1); canvas.addSubview(label)
            } }
            window.makeKeyAndVisible(); window.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 160_000_000)
            let format = UIGraphicsImageRendererFormat(); format.scale = 3
            let image = UIGraphicsImageRenderer(bounds: canvas.bounds,format: format).image { _ in
                XCTAssertTrue(canvas.drawHierarchy(in: canvas.bounds,afterScreenUpdates: true))
            }
            if dark {
                let bitmap = try XCTUnwrap(image.cgImage)
                var rgba = [UInt8](repeating: 0,count: bitmap.width*bitmap.height*4)
                try rgba.withUnsafeMutableBytes { raw in
                    let context = try XCTUnwrap(CGContext(data: raw.baseAddress,width: bitmap.width,height: bitmap.height,bitsPerComponent: 8,bytesPerRow: bitmap.width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                    context.draw(bitmap,in: CGRect(x: 0,y: 0,width: CGFloat(bitmap.width),height: CGFloat(bitmap.height)))
                }
                let firstPixelIsTop = Int(max(rgba[0],rgba[1],rgba[2]))-Int(min(rgba[0],rgba[1],rgba[2])) < 10
                for index in symbols.indices {
                    let left = (19+index%6*70)*3, top = (12+index/6*84)*3
                    var chromaticBrightness: [UInt8] = []
                    for y in top..<(top+96) { for x in left..<(left+96) {
                        let rasterY = firstPixelIsTop ? y : bitmap.height-1-y
                        let offset = (rasterY*bitmap.width+x)*4
                        let peak = max(rgba[offset],rgba[offset+1],rgba[offset+2])
                        let low = min(rgba[offset],rgba[offset+1],rgba[offset+2])
                        if peak > 45 && Int(peak)-Int(low) > 10 { chromaticBrightness.append(peak) }
                    } }
                    chromaticBrightness.sort()
                    XCTAssertFalse(chromaticBrightness.isEmpty,symbols[index])
                    if !chromaticBrightness.isEmpty {
                        XCTAssertGreaterThanOrEqual(chromaticBrightness[chromaticBrightness.count/2],150,"The body, not just one reflection, must have a normal bright color: \(symbols[index])")
                        XCTAssertGreaterThanOrEqual(chromaticBrightness[chromaticBrightness.count*9/10],180,"Normal colors must remain bright on a dark host: \(symbols[index])")
                    }
                }
            }
            let attachment = XCTAttachment(image: image); attachment.name = "Glass58-icons-native-" + (dark ? "dark" : "light")
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testSelectedAbbreviationIsRememberedBeforeTheNextDecoderQuery() async throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        try await waitFor { controller.model.engineState == "离线就绪" }
        for character in "ganghuam" { controller.model.handle(.text(String(character))) }
        try await waitFor { controller.model.candidates.contains { $0.text == "钢化膜" } && controller.model.candidatesAreCurrent }
        let film = try XCTUnwrap(controller.model.candidates.first { $0.text == "钢化膜" })
        controller.model.choose(film)
        XCTAssertEqual(controller.textView.text, "钢化膜")
        for character in "ganghuam" { controller.model.handle(.text(String(character))) }
        try await waitFor { controller.model.candidatesAreCurrent && controller.model.candidates.prefix(4).contains { $0.text == "钢化膜" } }
        controller.model.choose(try XCTUnwrap(controller.model.candidates.first { $0.text == "钢化膜" }))
        XCTAssertEqual(controller.textView.text, "钢化膜钢化膜")
    }
    func testNewSpellingInterruptsOldCandidateDeceleration() async throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        try await waitFor { controller.model.engineState == "离线就绪" }
        for character in "shi" { controller.model.handle(.text(String(character))) }
        try await waitFor { controller.model.candidatesAreCurrent }; settleLayout(controller.view)
        let scroll = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? CandidateScrollView }.first)
        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: true)
        controller.model.clearComposition()
        let start = ProcessInfo.processInfo.systemUptime
        for character in "nichifankm" { controller.model.handle(.text(String(character))) }
        try await waitFor { controller.model.candidatesAreCurrent && controller.model.candidates.first?.text == "你吃饭了吗" }
        settleLayout(controller.view)
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        print("VISIBLE_CANDIDATE_LATENCY rapidKeys=10 firstCurrentMs=\(elapsed)")
        XCTAssertFalse(scroll.holdsCandidateUpdates)
        let first = descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "candidate.你吃饭了吗" }
        XCTAssertNotNil(first); XCTAssertTrue(first?.isEnabled == true)
        XCTAssertLessThan(elapsed, 500, "The current row must not wait for a 1–2 second inertial scroll")
    }
    func testClipboardIsContentFirstAndSupportsSelection() throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        let panel = ClipboardPanel(model: controller.model)
        panel.frame = CGRect(x: 0, y: 0, width: 370, height: 264); settleLayout(panel)
        let labels = descendants(panel).compactMap { ($0 as? UILabel)?.text }.joined(separator: " ")
        XCTAssertFalse(labels.contains("自动收录已开启")); XCTAssertFalse(labels.contains("从其他 App 粘贴"))
        XCTAssertEqual(descendants(panel).compactMap { $0 as? UISegmentedControl }.first?.numberOfSegments, 2)
        panel.selectText("朱鸿毅 编程 16 次课 2800"); settleLayout(panel)
        let collection = try XCTUnwrap(descendants(panel).compactMap { $0 as? UICollectionView }.first)
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 9)
    }
    func testThreeAppPagesRenderWithoutEmbeddingAKeyboardOnHome() throws {
        let suite = "clear.pages." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(store: SettingsStore(defaults: defaults))
        let pages = [AnyView(HomeView(selectedTab: .constant(.home)).environmentObject(prefs)),
                     AnyView(CustomizationView().environmentObject(prefs)), AnyView(InputSettingsView().environmentObject(prefs))]
        for (index, page) in pages.enumerated() {
            let host = UIHostingController(rootView: page)
            host.loadViewIfNeeded(); host.view.frame = CGRect(x: 0, y: 0, width: 420, height: 912); settleLayout(host.view)
            XCTAssertFalse(descendants(host.view).contains { $0 is KeyboardSurface }, "App page \(index) must not build an embedded keyboard")
            XCTAssertTrue(host.view.bounds.width > 0)
        }
        for value in [0.15, 0.5, 1.0] { prefs.settings.keyGlassStrength = value }
        prefs.settings.learnChoices = false; XCTAssertFalse(prefs.settings.learnChoices)
        prefs.clearLearning()
        XCTAssertNil(defaults.data(forKey: "clear.choices.v2"))
    }
    func testWaitingSpaceIsCancelledWhenTheEditingContextChanges() async throws {
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
        try await waitFor { controller.model.engineState == "离线就绪" }
        for character in "womenjintianquchifan" { controller.model.handle(.text(String(character))) }
        controller.model.handle(.space)
        controller.textView.text = "第二个"; controller.textView.selectedRange = NSRange(location: 3, length: 0)
        controller.model.cursorChanged()
        for character in "nihao" { controller.model.handle(.text(String(character))) }
        try await waitFor { controller.model.candidatesAreCurrent && controller.model.candidates.first?.text == "你好" }
        controller.model.handle(.space)
        XCTAssertEqual(controller.textView.text, "第二个你好")
    }

}
