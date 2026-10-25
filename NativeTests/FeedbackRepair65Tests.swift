import XCTest
import UIKit

@MainActor final class FeedbackRepair65Tests: XCTestCase {
    private final class Document: KeyboardDocument {
        var text = "", cursor = 0, selectedText = ""
        let documentIdentity = UUID().uuidString
        var contextBefore: String { String(text.prefix(cursor)) }
        var contextAfter: String { String(text.dropFirst(cursor)) }
        let enterTitle = "换行", needsGlobe = false, fullAccess = true, prefersEnglish = false
        let capitalization = UITextAutocapitalizationType.none
        var usesLocalPinyinComposition: Bool { true }
        func insert(_ value: String) { text = contextBefore + value + contextAfter; cursor += value.count }
        func deleteBackward() {
            guard cursor > 0 else { return }
            var left = contextBefore; let right = contextAfter; left.removeLast(); cursor -= 1; text = left + right
        }
        func moveCursor(_ offset: Int) { cursor = min(text.count, max(0, cursor + offset)) }
        func beginTrackpad() {}
        func trackCursor(translation: CGPoint) {}
        func endTrackpad() {}
        func nextKeyboard() {}
        func setMarkedText(_ text: String) {}
        func commitMarkedText(_ text: String) { insert(text) }
        func unmarkText() {}
        func clearInput() -> DeletedInput? { nil }
        func restoreInput(_ value: DeletedInput) -> Bool { false }
    }
    private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
    private func fixture() -> (Document, KeyboardModel, KeyboardSurface, ClipboardSuggestionState) {
        let document = Document(), defaults = UserDefaults(suiteName: UUID().uuidString)!
        let state = ClipboardSuggestionState(defaults: defaults)
        var settings = KeyboardSettings(); settings.toolbar = ToolbarTool.allCases; settings.automaticClipboard = false
        let model = KeyboardModel(document: document, settings: settings, defaults: defaults, wordLookup: { _, _, _ in [] })
        let surface = KeyboardSurface(model: model, suggestionState: state)
        surface.frame = CGRect(x: 0, y: 0, width: 390, height: 310); surface.layoutIfNeeded()
        return (document, model, surface, state)
    }
    private func button(_ id: String, in root: UIView) throws -> UIButton {
        try XCTUnwrap(views(root).first { $0.accessibilityIdentifier == id } as? UIButton)
    }
    private func display(_ view: UIView) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; controller.view.backgroundColor = .systemBackground
        controller.view.addSubview(view); window.makeKeyAndVisible(); window.layoutIfNeeded(); return window
    }
    private func capture(_ view: UIView, name: String) -> UIImage {
        views(view).forEach { $0.layer.displayIfNeeded() }
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { view.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        return image
    }
    func testLongArticleActuallyDrawsTheMiddleAndTailWithoutAWideBackingView() async throws {
        let preview = ClipboardInlinePreview(); preview.frame = CGRect(x: 12, y: 20, width: 260, height: 40)
        let window = try display(preview); defer { window.isHidden = true }
        let text = (0..<2400).map { "第\($0)段 中文😀 e\u{301} https://example.org/\($0)。" }.joined(separator: "\n") + "文章终点甲乙丙丁"
        preview.show(text); preview.layoutIfNeeded()
        let ready = Date().addingTimeInterval(10)
        while !preview.isReady && Date() < ready { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(preview.isReady); preview.layoutIfNeeded()
        let end = preview.contentSize.width - preview.bounds.width
        XCTAssertGreaterThan(end, 100_000)
        var pictures: [Data] = []
        for (name, x) in [("start", CGFloat(0)), ("middle", end / 2), ("tail", end)] {
            preview.setContentOffset(CGPoint(x: x, y: 0), animated: false)
            preview.layoutIfNeeded()
            pictures.append(try XCTUnwrap(capture(preview, name: "Clipboard65-" + name).pngData()))
            XCTAssertGreaterThan(preview.lastDrawnGlyphCount, 0)
            XCTAssertLessThan(preview.lastDrawnGlyphCount, 1024)
            XCTAssertGreaterThan(preview.visibleStringRange.length, 0)
            XCTAssertLessThanOrEqual(preview.subviews.first?.bounds.width ?? .infinity, 260)
            XCTAssertEqual(preview.contentOffset.x, x, accuracy: 0.5)
        }
        XCTAssertNotEqual(pictures[0], pictures[1]); XCTAssertNotEqual(pictures[1], pictures[2])
        XCTAssertGreaterThan(NSMaxRange(preview.visibleStringRange), (preview.text as NSString).length - 48)
    }
    func testConsumedCopySurvivesRefreshRelaunchAndChangedHistoryIDs() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!, clip = Clip(text: "关闭后的同一次复制")
        let state = ClipboardSuggestionState(defaults: defaults)
        state.consume(clip, revision: 108)
        let restarted = ClipboardSuggestionState(defaults: defaults)
        XCTAssertTrue(restarted.isConsumed(clip, revision: 109))
        XCTAssertTrue(restarted.isConsumed(Clip(text: clip.text), revision: 108))
        XCTAssertFalse(restarted.isConsumed(Clip(text: clip.text), revision: 109))
        XCTAssertFalse(restarted.isConsumed(Clip(text: "新的复制内容"), revision: 108))
        restarted.consumeInputRevision(110)
        XCTAssertTrue(ClipboardSuggestionState(defaults: defaults).isConsumed(Clip(text: "输入之后才读到的旧复制"), revision: 110))
        XCTAssertFalse(restarted.isConsumed(Clip(text: "之后真正的新复制"), revision: 111))
    }
    func testCloseAndAllContentKeyTypesSuppressTheOldCopyWithoutDeletingHistory() throws {
        let (document, model, surface, state) = fixture(); defer { withExtendedLifetime(document) {} }
        let text = "复制提示65-" + UUID().uuidString
        UIPasteboard.general.string = text
        model.clipboardCapture.acceptText(text)
        let suggestion = try XCTUnwrap(views(surface).first { $0.accessibilityIdentifier == "clipboard.recent" })
        XCTAssertFalse(suggestion.isHidden)
        try button("clipboard.recent.close", in: surface).sendActions(for: .touchUpInside)
        XCTAssertTrue(suggestion.isHidden)
        model.clipboardCapture.acceptText(text); XCTAssertTrue(suggestion.isHidden)
        let reopened = KeyboardSurface(model: model, suggestionState: state)
        reopened.frame = surface.frame; reopened.layoutIfNeeded()
        let next = try XCTUnwrap(views(reopened).first { $0.accessibilityIdentifier == "clipboard.recent" })
        XCTAssertTrue(next.isHidden)
        for (index, action) in [KeyAction.text("a"), .literal("B"), .text("1"), .text("？")].enumerated() {
            model.settings.language = index == 0 ? .chinese : .english
            let value = text + "-\(index)"
            UIPasteboard.general.string = value
            model.clipboardCapture.acceptText(value); XCTAssertFalse(next.isHidden)
            model.handle(action); XCTAssertTrue(next.isHidden)
            model.clipboardCapture.acceptText(value); XCTAssertTrue(next.isHidden)
            // Start the next independent copy with an empty composition. An
            // active pinyin draft intentionally hides every clipboard hint.
            model.handle(.delete)
            XCTAssertTrue(model.composition.isEmpty)
        }
        XCTAssertTrue(ClipboardStore(url: SharedStorage.clipboardURL(allowShared: true)).clips.contains { $0.text == text })
    }
    func testSelectionDoneSharesTheToolbarAndFinishesWithoutReinserting() throws {
        let (document, _, surface, _) = fixture()
        let window = try display(surface); defer { window.isHidden = true; withExtendedLifetime(document) {} }
        try button("toolbar.clipboard", in: surface).sendActions(for: .touchUpInside)
        let panel = try XCTUnwrap(views(surface).compactMap { $0 as? ClipboardPanel }.first)
        panel.selectText("甲乙丙丁"); surface.layoutIfNeeded(); panel.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.22))
        let done = try button("clipboard.insertSelection", in: surface)
        let brand = try button("toolbar.tools", in: surface)
        XCTAssertEqual(done.convert(done.bounds, to: surface).midY, brand.convert(brand.bounds, to: surface).midY, accuracy: 0.5)
        let words = try XCTUnwrap(views(panel).first { $0.accessibilityIdentifier == "clipboard.selection.words" })
        XCTAssertLessThanOrEqual(words.frame.minY, 5)
        XCTAssertTrue(panel.setSelection([0, 2])); XCTAssertEqual(document.text, "甲丙")
        XCTAssertTrue(panel.setSelection([2])); XCTAssertEqual(document.text, "丙")
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style; surface.layoutIfNeeded()
            _ = capture(surface, name: "Selection65-" + (style == .dark ? "dark" : "light"))
        }
        done.sendActions(for: .touchUpInside)
        XCTAssertEqual(document.text, "丙"); XCTAssertNil(panel.superview)
    }
    func testRapidToolbarDirectionChangesNeverSnapOrRestartAnOffsetAnimation() throws {
        let (document, _, surface, _) = fixture(); defer { withExtendedLifetime(document) {} }
        let scroll = try XCTUnwrap(views(surface).compactMap { $0 as? ToolbarScrollView }.first)
        let end = scroll.contentSize.width - scroll.bounds.width
        let started = CACurrentMediaTime()
        for step in 0..<240 {
            let x = CGFloat(step % 60 < 30 ? step % 30 : 30 - step % 30) / 30 * end
            surface.scrollViewWillBeginDragging(scroll)
            scroll.setContentOffset(CGPoint(x: x, y: 0), animated: false); scroll.layoutIfNeeded()
            if step % 30 == 0 { surface.scrollViewDidEndDragging(scroll, willDecelerate: false) }
            XCTAssertEqual(scroll.contentOffset.x, x, accuracy: 0.5)
        }
        XCTAssertLessThan(CACurrentMediaTime() - started, 3)
        scroll.contentOffset.x = end / 2; scroll.layoutIfNeeded()
        let gradient = try XCTUnwrap(scroll.layer.mask as? CAGradientLayer)
        let colors = try XCTUnwrap(gradient.colors as? [CGColor])
        XCTAssertEqual(colors.first?.alpha, 0); XCTAssertEqual(colors.last?.alpha, 0)
        XCTAssertGreaterThan(gradient.locations?[1].doubleValue ?? 0, 0)
        let window = try display(surface); defer { window.isHidden = true }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style; surface.layoutIfNeeded()
            _ = capture(surface, name: "Toolbar65-" + (style == .dark ? "dark" : "light"))
        }
    }
    func testBothHapticChoicesPersistAndReachTheActualKeyWhileLegacySettingsDefaultToCrisp() throws {
        var legacy = KeyboardSettings(); legacy.vibrationMode = nil
        let restored = try JSONDecoder().decode(KeyboardSettings.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(restored.resolvedVibrationMode, .crisp)
        let (document, model, surface, _) = fixture(); defer { withExtendedLifetime(document) {} }
        try button("toolbar.vibration", in: surface).sendActions(for: .touchUpInside)
        let toggle = try XCTUnwrap(views(surface).first { $0.accessibilityIdentifier == "keyboard.vibration.enabled" } as? UISwitch)
        let choices = try XCTUnwrap(views(surface).first { $0.accessibilityIdentifier == "keyboard.vibration.mode" } as? UISegmentedControl)
        toggle.isOn = true; toggle.sendActions(for: .valueChanged)
        var pulses: [CGFloat] = []
        let feedback = KeyboardVibration(emit: { pulses.append($0) })
        let key = KeyButton(key: KeyboardKey("a"), vibration: feedback)
        for (index, mode) in VibrationMode.allCases.enumerated() {
            choices.selectedSegmentIndex = index; choices.sendActions(for: .valueChanged)
            XCTAssertEqual(model.settings.resolvedVibrationMode, mode)
            key.apply(model.settings); key.sendActions(for: .touchDown)
            XCTAssertEqual(feedback.requestedStyle, mode == .crisp ? .rigid : .soft)
            key.sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(pulses.count, 2); XCTAssertGreaterThan(pulses[0], pulses[1])
        try button("toolbar.vibration", in: surface).sendActions(for: .touchUpInside)
        XCTAssertFalse(views(surface).contains { $0 is KeyboardHapticPanel })
    }
}
