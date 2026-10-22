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
        try XCTSkipIf(UIAccessibility.isReduceTransparencyEnabled || ProcessInfo.processInfo.isLowPowerModeEnabled)
        for style in [UIUserInterfaceStyle.light, .dark] {
            var colors: [UIColor] = []
            for key in KeyboardLayout.rows(page: .letters, globe: false).last!.keys {
                let button = KeyButton(key: key); button.overrideUserInterfaceStyle = style
                var settings = testSettings(); settings.customAccentHex = "#FF00FF"
                button.apply(settings)
                let face = try XCTUnwrap(button.subviews.first { $0.accessibilityIdentifier == "key.face" })
                let color = try XCTUnwrap(face.backgroundColor)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
                XCTAssertEqual(r, g, accuracy: 0.001); XCTAssertEqual(g, b, accuracy: 0.001)
                XCTAssertLessThan(a, 0.95, "The key must transmit the continuous glass backdrop")
                colors.append(color)
                settings.glass = .solid; button.apply(settings)
                XCTAssertEqual(face.backgroundColor?.cgColor.alpha ?? 0, 1, accuracy: 0.001)
                let label = try XCTUnwrap(descendants(button).compactMap { $0 as? CenteredKeyLabel }.first)
                XCTAssertEqual(label.textColor.resolvedColor(with: button.traitCollection), UIColor.label.resolvedColor(with: button.traitCollection))
            }
            XCTAssertTrue(colors.dropFirst().allSatisfy { $0.isEqual(colors[0]) }, "Space and language must use the same neutral bottom-row material")
        }
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
        let backdrop = try XCTUnwrap(input.subviews.compactMap { $0 as? GlassBackdrop }.first)
        XCTAssertEqual(backdrop.frame, input.bounds)
        XCTAssertFalse(surface.subviews.contains { $0 is GlassBackdrop }, "The controller must paint its root once, not stack another whole background in its key surface")
        XCTAssertLessThan(backdrop.backgroundColor?.cgColor.alpha ?? 0, 0.1)
        XCTAssertFalse(backdrop.isOpaque)
    }
    private func materialImage(_ view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            XCTAssertTrue(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true))
        }
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
    private func assertOwnedColorReachesEveryEdge(_ input: UIView, name: String) throws {
        let backdrop = try XCTUnwrap(input.subviews.compactMap { $0 as? GlassBackdrop }.first)
        let image = materialImage(backdrop)
        for x in [CGFloat(1), input.bounds.midX, input.bounds.width - 2] {
            for y in [CGFloat(1), input.bounds.midY, input.bounds.height - 2] {
                let color = try materialPixel(image, at: CGPoint(x: x, y: y))
                XCTAssertLessThan(color[0], 15)
                XCTAssertGreaterThan(color[1], 70); XCTAssertLessThan(color[1], 105)
                XCTAssertGreaterThan(color[2], 240); XCTAssertGreaterThan(color[3], 250,
                    "The selected solid color must not fade into a dark halo at an owned edge")
            }
        }
        XCTAssertEqual(backdrop.frame, input.bounds)
        XCTAssertFalse(descendants(backdrop).contains { $0.layer.mask is CAGradientLayer })
        let attachment = XCTAttachment(image: materialImage(input)); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
    func testRootBackdropCoversExtraHostHeightWithoutChangingKeyGeometry() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 640)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let controller = KeyboardViewController(nibName: nil, bundle: nil)
        host.addChild(controller); controller.loadViewIfNeeded(); host.view.addSubview(controller.view)
        controller.didMove(toParent: host)
        let input = try XCTUnwrap(controller.inputView)
        let surface = try XCTUnwrap(descendants(input).compactMap { $0 as? KeyboardSurface }.first)
        let defaults = SharedStorage.defaults(allowShared: controller.fullAccess)
        let saved = defaults.data(forKey: SettingsStore.key)
        defer {
            surface.model.suspend()
            if let saved { defaults.set(saved, forKey: SettingsStore.key) } else { defaults.removeObject(forKey: SettingsStore.key) }
        }
        var settings = testSettings(); settings.glass = .solid
        settings.backgroundColorHex = "#0057FF"; settings.keyColorHex = "#292C39"
        surface.model.settings = settings
        let requested = try XCTUnwrap(input.constraints.first { $0.identifier == "clear.keyboard.content-height" })
        // Simulate an external host allocation that temporarily wins over the
        // requested height. Only this fixture lowers the request's priority.
        requested.priority = .defaultHigh
        let allocated = input.heightAnchor.constraint(equalToConstant: surface.desiredHeight)
        NSLayoutConstraint.activate([input.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            input.topAnchor.constraint(equalTo: host.view.topAnchor, constant: 150),
            input.widthAnchor.constraint(equalToConstant: 393), allocated])
        let backdrop = try XCTUnwrap(input.subviews.compactMap { $0 as? GlassBackdrop }.first)
        let q = try XCTUnwrap(descendants(surface).compactMap { $0 as? KeyButton }.first { $0.key.action == .text("q") })
        let a = try XCTUnwrap(descendants(surface).compactMap { $0 as? KeyButton }.first { $0.key.action == .text("a") })
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            host.view.backgroundColor = style == .dark ? .black : .white
            for extra: CGFloat in [0, 18, 0] {
                allocated.constant = surface.desiredHeight + extra
                settleLayout(host.view); settleLayout(input)
                XCTAssertEqual(backdrop.frame, input.bounds, "Only painting the fixed key surface leaves extra host height uncovered")
                XCTAssertEqual(surface.bounds.height, surface.desiredHeight, accuracy: 0.5)
                XCTAssertEqual(surface.frame.minY, extra, accuracy: 0.5)
                XCTAssertEqual(q.bounds.height, 56, accuracy: 0.5)
                XCTAssertEqual(a.frame.minY - q.frame.minY, 56, accuracy: 0.5)
                XCTAssertEqual(KeyboardGeometry.keyPlate(in: q.bounds).height, 45, accuracy: 0.5)
                print("KEYBOARD_ROOT_COVERAGE style=\(style.rawValue) extra=\(extra) root=\(input.bounds) background=\(backdrop.frame) surface=\(surface.frame) pitch=\(q.bounds.height)")
                try assertOwnedColorReachesEveryEdge(input, name: "owned-root-full-color-\(style == .dark ? "dark" : "light")-extra\(Int(extra))")
            }
        }
    }
    func testPublicResponderHostedInputViewPaintsItsOwnBoundsInBothStyles() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            host.view.backgroundColor = style == .dark ? .black : .white
            let controller = KeyboardViewController(nibName: nil, bundle: nil); controller.loadViewIfNeeded()
            let input = try XCTUnwrap(controller.inputView)
            input.overrideUserInterfaceStyle = style
            let surface = try XCTUnwrap(descendants(input).compactMap { $0 as? KeyboardSurface }.first)
            let defaults = SharedStorage.defaults(allowShared: controller.fullAccess)
            let saved = defaults.data(forKey: SettingsStore.key)
            let field = UITextField(frame: CGRect(x: 20, y: 80, width: 300, height: 44))
            field.borderStyle = .roundedRect; field.placeholder = "Public input-view appearance fixture"
            field.keyboardAppearance = style == .dark ? .dark : .light
            field.inputView = input; host.view.addSubview(field)
            defer {
                field.resignFirstResponder(); field.removeFromSuperview(); surface.model.suspend()
                if let saved { defaults.set(saved, forKey: SettingsStore.key) } else { defaults.removeObject(forKey: SettingsStore.key) }
            }
            var settings = testSettings(); settings.glass = .solid
            settings.backgroundColorHex = "#0057FF"; settings.keyColorHex = "#292C39"
            surface.model.settings = settings
            XCTAssertTrue(field.becomeFirstResponder())
            try await waitFor { input.window != nil && input.bounds.width > 0 && input.bounds.height >= surface.desiredHeight }
            try await Task.sleep(nanoseconds: 300_000_000)
            settleLayout(input)
            let backdrop = try XCTUnwrap(input.subviews.compactMap { $0 as? GlassBackdrop }.first)
            XCTAssertEqual(backdrop.frame, input.bounds)
            let keyboardWindow = try XCTUnwrap(input.window)
            let owned = input.convert(input.bounds, to: keyboardWindow)
            print("KEYBOARD_PUBLIC_INPUT_HOST style=\(style.rawValue) inputViewStyle=\(input.inputViewStyle.rawValue) ownedRootInWindow=\(owned) root=\(input.bounds) background=\(backdrop.frame) surface=\(surface.frame) outerSystemAreaVerified=false")
            try assertOwnedColorReachesEveryEdge(input, name: "public-host-owned-full-color-\(style == .dark ? "dark" : "light")")
            // This public responder fixture shows UIKit's surrounding material
            // for visual review; it is not an extension's remote host process.
            snapshot(keyboardWindow, name: "public-input-host-context-\(style == .dark ? "dark" : "light")")
        }
    }
    func testControlledInputHostKeepsOwnedFramesAndCapturesMaterialContext() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.frame = CGRect(x: 0, y: 0, width: 433, height: 640)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        let caption = UILabel(frame: CGRect(x: 20, y: 42, width: 393, height: 48))
        caption.text = "受控不透明底板：上 17pt / 下 74pt\n仅布局与材质参考，非远程键盘宿主"
        caption.numberOfLines = 2; caption.font = .systemFont(ofSize: 13); host.view.addSubview(caption)
        let controller = KeyboardViewController(nibName: nil, bundle: nil)
        host.addChild(controller); controller.loadViewIfNeeded()
        let input = try XCTUnwrap(controller.inputView)
        let surface = try XCTUnwrap(descendants(input).compactMap { $0 as? KeyboardSurface }.first)
        let defaults = SharedStorage.defaults(allowShared: controller.fullAccess), saved = defaults.data(forKey: SettingsStore.key)
        defer {
            surface.model.suspend()
            if let saved { defaults.set(saved, forKey: SettingsStore.key) } else { defaults.removeObject(forKey: SettingsStore.key) }
        }
        let cap: CGFloat = 17, footer: CGFloat = 74
        let shell = UIView(frame: CGRect(x: 20, y: 110, width: 393, height: cap + surface.desiredHeight + footer))
        shell.layer.cornerRadius = 30; shell.layer.cornerCurve = .continuous; shell.clipsToBounds = true
        // A live system material changes its sampling between captures. An
        // opaque, controlled base isolates actual out-of-bounds drawing from
        // compositor/backdrop changes; it is not a simulated native renderer.
        let base = UIView(); base.isOpaque = true
        base.frame = shell.bounds; shell.addSubview(base); host.view.addSubview(shell)
        shell.addSubview(input); controller.didMove(toParent: host)
        NSLayoutConstraint.activate([input.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            input.topAnchor.constraint(equalTo: shell.topAnchor, constant: cap),
            input.widthAnchor.constraint(equalTo: shell.widthAnchor)])
        let globe = UIImageView(image: UIImage(systemName: "globe"))
        globe.contentMode = .scaleAspectFit
        globe.frame = CGRect(x: 24, y: cap + surface.desiredHeight + 17, width: 28, height: 28)
        shell.addSubview(globe)
        let backdrop = try XCTUnwrap(input.subviews.compactMap { $0 as? GlassBackdrop }.first)
        let q = try XCTUnwrap(descendants(surface).compactMap { $0 as? KeyButton }.first { $0.key.action == .text("q") })
        let variants: [(String, GlassPreset, String?)] = [
            ("default-glass", .clear, nil), ("blue-glass", .mist, "#0057FF"),
            ("blue-solid", .solid, "#0057FF"), ("default-solid", .solid, nil)
        ]
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            host.view.backgroundColor = style == .dark ? UIColor(white: 0.08, alpha: 1) : UIColor(white: 0.94, alpha: 1)
            shell.backgroundColor = style == .dark ? UIColor(white: 0.18, alpha: 1) : UIColor(white: 0.84, alpha: 1)
            base.backgroundColor = shell.backgroundColor
            globe.tintColor = style == .dark ? .white : .black
            for (name, material, color) in variants {
                var settings = testSettings(); settings.glass = material; settings.backgroundColorHex = color
                settings.backgroundGlassStrength = 0.8; settings.keyColorHex = "#292C39"
                surface.model.settings = settings
                settleLayout(host.view); settleLayout(input)
                try await Task.sleep(nanoseconds: 60_000_000)
                XCTAssertEqual(backdrop.frame, input.bounds)
                XCTAssertTrue(backdrop.clipsToBounds)
                XCTAssertEqual(input.frame.minY, cap, accuracy: 0.5)
                XCTAssertEqual(shell.bounds.height - input.frame.maxY, footer, accuracy: 0.5)
                XCTAssertEqual(surface.bounds.height, surface.desiredHeight, accuracy: 0.5)
                XCTAssertEqual(q.bounds.height, 56, accuracy: 0.5)
                backdrop.isHidden = true; let baseline = materialImage(shell)
                backdrop.isHidden = false; let blended = materialImage(shell)
                let x = shell.bounds.midX
                // A whole UIInputView drawHierarchy snapshot at 1x can mix
                // compositor changes with resampling beside a 3x owned edge.
                // Keep these raw observations for diagnosis; they are neither
                // an owner-only drawing oracle nor proof of native shell tint.
                for outside in [input.frame.minY - 1, input.frame.maxY + 1] {
                    let actual = try materialPixel(blended, at: CGPoint(x: x, y: outside))
                    let original = try materialPixel(baseline, at: CGPoint(x: x, y: outside))
                    print("CONTROLLED_INPUT_HOST_PIXEL style=\(style.rawValue) case=\(name) material=\(material) color=\(color ?? "default") sample=\(CGPoint(x: x, y: outside)) baselineRGBA=\(original) visibleRGBA=\(actual) maxRGBDelta=\(pixelDistance(actual, original)) rendererScale=1 screenScale=\(window.screen.scale) externalNativePaintOracle=false")
                }
                if name == "blue-solid" {
                    let center = try materialPixel(materialImage(backdrop), at: CGPoint(x: input.bounds.midX, y: input.bounds.midY))
                    XCTAssertLessThan(center[0], 15); XCTAssertGreaterThan(center[2], 240)
                    let hardReference = UIView(frame: input.bounds); hardReference.backgroundColor = UIColor(red: 0, green: 87 / 255, blue: 1, alpha: 1)
                    input.insertSubview(hardReference, aboveSubview: backdrop)
                    snapshot(host.view, name: "simulated-shell-hard-edge-reference-\(style == .dark ? "dark" : "light")")
                    hardReference.removeFromSuperview()
                }
                snapshot(host.view, name: "controlled-owned-color-boundary-\(style == .dark ? "dark" : "light")-\(name)")
                print("SIMULATED_MATERIAL_SHELL style=\(style.rawValue) case=\(name) cap=17 footer=74 root=\(input.frame) keyPitch=\(q.bounds.height) actualRemoteHostVerified=false")
            }
        }
    }
    func testSolidBackdropStaysWithinOwnedBoundsAtNativeScaleAndResets() throws {
        let scale = UIScreen.main.scale
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 128))
        host.isOpaque = true
        let backdrop = GlassBackdrop()
        host.addSubview(backdrop)

        struct Pixels {
            let width: Int
            let height: Int
            let rgba: [UInt8]
            func at(_ x: Int, _ y: Int) -> [UInt8] {
                let index = (y * width + x) * 4
                return Array(rgba[index..<(index + 4)])
            }
        }
        func rendered() throws -> Pixels {
            host.layoutIfNeeded(); backdrop.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale; format.preferredRange = .standard; format.opaque = true
            // No responder, UIInputView, live material, rounded shell, screenshot
            // resampling or render-server snapshot participates in this oracle.
            let image = UIGraphicsImageRenderer(bounds: host.bounds, format: format).image { context in
                host.layer.render(in: context.cgContext)
            }
            let cg = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(cg.width, Int(host.bounds.width * scale))
            XCTAssertEqual(cg.height, Int(host.bounds.height * scale))
            var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            try bytes.withUnsafeMutableBytes { raw in
                let context = try XCTUnwrap(CGContext(data: raw.baseAddress,
                    width: cg.width, height: cg.height, bitsPerComponent: 8,
                    bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
            }
            return Pixels(width: cg.width, height: cg.height, rgba: bytes)
        }

        for style in [UIUserInterfaceStyle.light, .dark] {
            host.overrideUserInterfaceStyle = style
            // Fixed opaque RGB colors keep the outside reference independent of
            // a native material or an asynchronously resolved dynamic UIColor.
            host.backgroundColor = style == .dark
                ? UIColor(red: 23.0 / 255, green: 29.0 / 255, blue: 37.0 / 255, alpha: 1)
                : UIColor(red: 241.0 / 255, green: 237.0 / 255, blue: 229.0 / 255, alpha: 1)
            for size in [CGSize(width: 96, height: 64), CGSize(width: 112, height: 84), CGSize(width: 96, height: 64)] {
                // Native-pixel-aligned and centered, including after resize back to
                // the original size. No pixels straddle a fractional owned edge.
                backdrop.frame = CGRect(x: (host.bounds.width - size.width) / 2,
                                        y: (host.bounds.height - size.height) / 2,
                                        width: size.width, height: size.height)
                for value in [backdrop.frame.minX, backdrop.frame.minY,
                              backdrop.frame.maxX, backdrop.frame.maxY] {
                    XCTAssertEqual(value * scale, (value * scale).rounded(), accuracy: 0.0001)
                }
                var settings = testSettings()
                settings.glass = .solid; settings.backgroundColorHex = "#0057FF"
                backdrop.apply(settings, systemBacked: true)
                backdrop.layoutIfNeeded()
                XCTAssertTrue(backdrop.clipsToBounds)
                XCTAssertTrue(backdrop.subviews.compactMap { $0 as? UIVisualEffectView }.allSatisfy { $0.effect == nil },
                              "The deterministic layer-render oracle applies only to solid output")

                backdrop.isHidden = true; let baseline = try rendered()
                backdrop.isHidden = false; let painted = try rendered()
                let minX = Int((backdrop.frame.minX * scale).rounded())
                let minY = Int((backdrop.frame.minY * scale).rounded())
                let maxX = Int((backdrop.frame.maxX * scale).rounded())
                let maxY = Int((backdrop.frame.maxY * scale).rounded())
                let band = 4 // Four physical pixels, not a guessed native cap size.
                var changedOutside = 0
                for y in (minY - band)..<(maxY + band) {
                    for x in (minX - band)..<(maxX + band)
                        where x < minX || x >= maxX || y < minY || y >= maxY {
                        if painted.at(x, y) != baseline.at(x, y) { changedOutside += 1 }
                    }
                }
                XCTAssertEqual(changedOutside, 0,
                               "Every pixel in all four exterior bands must retain the opaque reference exactly")
                // Inspect first/last interior pixel rows and columns as well as the
                // center, so a blank or accidentally hidden backdrop cannot pass.
                for y in [minY, (minY + maxY) / 2, maxY - 1] {
                    for x in [minX, (minX + maxX) / 2, maxX - 1] {
                        let blue = painted.at(x, y)
                        XCTAssertLessThan(blue[0], 15); XCTAssertGreaterThan(blue[1], 70)
                        XCTAssertLessThan(blue[1], 105); XCTAssertGreaterThan(blue[2], 240)
                        XCTAssertEqual(blue[3], 255)
                    }
                }

                // Sensitivity control: a known opaque sibling deliberately crosses
                // every owned edge. It must change the exterior pixels. This guards
                // the coordinate mapping and reference capture against a vacuous
                // always-zero result, without changing the production backdrop.
                let overdraw = UIView(frame: backdrop.frame.insetBy(dx: -2 / scale, dy: -2 / scale))
                overdraw.backgroundColor = .magenta; overdraw.isOpaque = true
                host.addSubview(overdraw)
                let spilled = try rendered()
                overdraw.removeFromSuperview()
                for point in [(minX - 1, (minY + maxY) / 2), (maxX, (minY + maxY) / 2),
                              ((minX + maxX) / 2, minY - 1), ((minX + maxX) / 2, maxY)] {
                    XCTAssertNotEqual(spilled.at(point.0, point.1), baseline.at(point.0, point.1),
                                      "The oracle must detect a known opaque spill on every side")
                }

                backdrop.apply(testSettings(), systemBacked: true)
                let reset = try rendered()
                XCTAssertEqual(reset.rgba, baseline.rgba,
                               "Resetting the selected skin must restore the complete opaque reference, including interior pixels")
            }
        }
    }
    func testOwnedBackgroundKeepsFullEdgeColorThroughResizeAndStrengthChanges() async throws {
        XCTAssertFalse(UIAccessibility.isReduceTransparencyEnabled)
        XCTAssertFalse(ProcessInfo.processInfo.isLowPowerModeEnabled)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        let scenery = CAGradientLayer(); scenery.frame = host.view.bounds
        scenery.colors = [UIColor.systemOrange.cgColor, UIColor.systemIndigo.cgColor, UIColor.systemPink.cgColor]
        scenery.startPoint = .zero; scenery.endPoint = CGPoint(x: 1, y: 1); host.view.layer.addSublayer(scenery)
        // A fine pattern makes blur strength observable; a linear gradient's
        // local mean can remain unchanged even when the effect is working.
        for index in 0..<60 {
            let stripe = UIView(frame: CGRect(x: CGFloat(index) * 8, y: 0, width: 8, height: max(640, host.view.bounds.height)))
            stripe.backgroundColor = index.isMultiple(of: 2) ? .white : .black
            host.view.addSubview(stripe)
        }
        let backdrop = GlassBackdrop(); host.view.addSubview(backdrop)
        var settings = testSettings(); settings.glass = .solid; settings.backgroundColorHex = "#0057FF"
        backdrop.frame = .zero; backdrop.apply(settings, systemBacked: true)
        for size in [CGSize(width: 320, height: 260), CGSize(width: 350, height: 310), CGSize(width: 320, height: 260)] {
            backdrop.frame = CGRect(origin: CGPoint(x: 20, y: 90), size: size)
            for systemBacked in [true, false, true] {
                backdrop.apply(settings, systemBacked: systemBacked); settleLayout(backdrop)
                let image = materialImage(backdrop)
                let edge = try materialPixel(image, at: CGPoint(x: size.width / 2, y: 1))
                let center = try materialPixel(image, at: CGPoint(x: size.width / 2, y: size.height / 2))
                XCTAssertGreaterThan(center[2], 240); XCTAssertLessThan(center[0], 15)
                XCTAssertGreaterThan(edge[3], 250); XCTAssertGreaterThan(edge[2], 240)
                XCTAssertLessThan(pixelDistance(edge, center), 3,
                    "Owned skin edges must retain the same solid color after every resize and hosting change")
            }
        }
        settings.backgroundColorHex = nil; settings.glass = .clear; settings.backgroundGlassStrength = 0
        backdrop.apply(settings, systemBacked: true); settleLayout(backdrop)
        backdrop.isHidden = true
        try await Task.sleep(nanoseconds: 60_000_000)
        let baseline = materialImage(host.view)
        backdrop.isHidden = false
        try await Task.sleep(nanoseconds: 60_000_000)
        let low = materialImage(host.view)
        settings.backgroundGlassStrength = 1; backdrop.apply(settings, systemBacked: true); settleLayout(backdrop)
        try await Task.sleep(nanoseconds: 60_000_000)
        let high = materialImage(host.view)
        let center = CGPoint(x: backdrop.frame.midX, y: backdrop.frame.midY)
        XCTAssertGreaterThan(pixelDistance(try materialPixel(low, at: center), try materialPixel(high, at: center)), 3,
                             "Fusion must not make the background strength control ineffective in the interior")
        let effect = try XCTUnwrap(backdrop.subviews.compactMap { $0 as? UIVisualEffectView }.first)
        XCTAssertEqual(effect.mask?.bounds, effect.bounds)
        XCTAssertFalse(descendants(backdrop).contains { $0.layer.mask is CAGradientLayer })
        snapshot(host.view, name: "owned-background-resized-strength-high")
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
        let base = try XCTUnwrap(descendants(preview).first { $0.accessibilityIdentifier == "appearance.native-base" } as? UIVisualEffectView)
        XCTAssertTrue(base.effect is UIBlurEffect)
        let backdrop = try XCTUnwrap(descendants(preview).compactMap { $0 as? GlassBackdrop }.first)
        let keys = descendants(preview).compactMap { $0 as? KeyButton }
        let q = try XCTUnwrap(keys.first { $0.key.action == .text("q") })
        let a = try XCTUnwrap(keys.first { $0.key.action == .text("a") })
        let shift = try XCTUnwrap(keys.first { $0.key.action == .shift })
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style; host.view.backgroundColor = .systemBackground
            var settings = testSettings(); settings.glass = .solid; settings.backgroundColorHex = "#0057FF"
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
                    XCTAssertEqual(backdrop.frame, canvas.bounds); XCTAssertEqual(base.frame, canvas.bounds)
                    let caption = try XCTUnwrap(descendants(q).compactMap { $0 as? CenteredKeyLabel }.first)
                    XCTAssertEqual(caption.font.pointSize, 23, accuracy: 0.1)
                    XCTAssertEqual(caption.layer.contentsScale, window.screen.scale * scale, accuracy: 0.01)
                    let fitted = preview.fittingSize(forWidth: size.width)
                    XCTAssertEqual(fitted.height / fitted.width, canvas.bounds.height / canvas.bounds.width, accuracy: 0.0001)
                }
            }
            settings.keyHeight = 50; settings.backgroundColorHex = "#FF5733"; settings.candidateColorHex = "#558DF2"
            preview.apply(settings)
            preview.frame.size = preview.fittingSize(forWidth: 350)
            settleLayout(preview)
            let color = try materialPixel(materialImage(backdrop), at: CGPoint(x: backdrop.bounds.midX, y: backdrop.bounds.midY))
            XCTAssertGreaterThan(color[0], 240); XCTAssertLessThan(color[2], 80)
            XCTAssertTrue(preview.accessibilityValue?.contains("backgroundColor:#FF5733") == true)
            snapshot(preview, name: "preview-proportional-\(style == .dark ? "dark" : "light")")
        }
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
        let controller = TypingLabController(settings: testSettings()); controller.loadViewIfNeeded()
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
    func testToolbarArtworkHasMatchingVisibleFootprints() throws {
        func alphaBounds(_ image: UIImage) throws -> CGRect {
            let cg = try XCTUnwrap(image.cgImage); let width = cg.width, height = cg.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            try pixels.withUnsafeMutableBytes { raw in
                let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            }
            var minX = width, minY = height, maxX = 0, maxY = 0
            for y in 0..<height { for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 24 {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            } }
            return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
        }
        let bounds = try ["doc.on.clipboard.fill", "face.smiling.fill", "paintpalette.fill"].map { try alphaBounds(ToolArtwork.image(symbol: $0, size: 32)) }
        let widths = bounds.map(\.width), heights = bounds.map(\.height)
        XCTAssertLessThan(widths.max()! / widths.min()!, 1.12)
        XCTAssertLessThan(heights.max()! / heights.min()!, 1.12)
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
        for glass in GlassPreset.allCases { prefs.settings.glass = glass }
        for value in [0.15, 0.5, 1.0] { prefs.settings.glassOpacity = value }
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
