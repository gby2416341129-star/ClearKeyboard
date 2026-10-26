import XCTest
import UIKit
import SwiftUI

@MainActor final class Repair67Tests: XCTestCase {
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTFail("The current spelling did not produce its expected candidate")
    }
    private func window(_ controller: UIViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = controller; window.makeKeyAndVisible()
        controller.loadViewIfNeeded(); controller.view.frame = window.bounds; controller.view.layoutIfNeeded()
        return window
    }
    func testRepeatedInitialismPartialSelectionsKeepEveryKeyAndCorrectRemainder() async throws {
        var settings = KeyboardSettings(); settings.automaticClipboard = false
        let controller = TypingLabController(settings: settings)
        let host = try window(controller)
        let model = try XCTUnwrap(controller.model)
        defer { model.suspend(); host.isHidden = true }
        try await waitFor { model.engineState == "离线就绪" }
        var expected = ""
        for round in 0..<32 {
            var typed = ""
            for letter in "bbmmcfl" {
                model.handle(.text(String(letter))); typed.append(letter)
                XCTAssertEqual(model.composition.raw, typed, "Dropped input at round \(round)")
            }
            try await waitFor { model.candidatesAreCurrent && model.candidates.contains { $0.text == "爸爸妈妈" && $0.consumed == 4 } }
            let first = try XCTUnwrap(model.candidates.first { $0.text == "爸爸妈妈" && $0.consumed == 4 })
            model.chooseDisplayed(first, context: model.candidateContext)
            XCTAssertEqual(model.composition.raw, "cfl", "Partial selection consumed the next word at round \(round)")
            try await waitFor { model.candidatesAreCurrent && model.candidates.contains { $0.text == "吃饭了" } }
            let last = try XCTUnwrap(model.candidates.first { $0.text == "吃饭了" })
            model.chooseDisplayed(last, context: model.candidateContext)
            XCTAssertTrue(model.composition.isEmpty)
            expected += "爸爸妈妈吃饭了"
            XCTAssertEqual(controller.textView.text, expected, "Host text lost or duplicated at round \(round)")
            model.handle(.enter); expected += "\n"
            // Exercise another query between repetitions rather than warming
            // only the single reported spelling's cache.
            for letter in "nihao" { model.handle(.text(String(letter))) }
            try await waitFor { model.candidatesAreCurrent && model.candidates.contains { $0.text == "你好" } }
            model.choose(try XCTUnwrap(model.candidates.first { $0.text == "你好" }))
            model.handle(.enter); expected += "你好\n"
            XCTAssertEqual(controller.textView.text, expected)
        }
    }
    func testOneHandPreferenceSyncDoesNotEnableTheLiveLayout() throws {
        var base = KeyboardSettings(); base.hand = .full
        var app = base; app.preferredHand = .left
        let applied = AppearanceSnapshot(settings: app, includeInputPreferences: true).applying(to: base)
        XCTAssertEqual(applied.hand, .full); XCTAssertEqual(applied.resolvedPreferredHand, .left)
        let decoded = try JSONDecoder().decode(KeyboardSettings.self, from: JSONEncoder().encode(applied))
        XCTAssertEqual(decoded.hand, .full); XCTAssertEqual(decoded.preferredHand, .left)
    }
    func testShortToolbarHasGapHitSurfaceAndFadesDuringBounce() throws {
        let controller = UIViewController(), host = try window(controller)
        defer { host.isHidden = true }
        let scroll = ToolbarScrollView(frame: CGRect(x: 20, y: 100, width: 300, height: 38))
        scroll.backgroundColor = UIColor(white: 0.5, alpha: 0.01)
        scroll.expectedContentWidth = 130; controller.view.addSubview(scroll); scroll.layoutIfNeeded()
        XCTAssertTrue(scroll.hitTest(CGPoint(x: 220, y: 19), with: nil) === scroll)
        for x: CGFloat in [-16, 16] {
            scroll.contentOffset.x = x; scroll.layoutIfNeeded()
            let mask = try XCTUnwrap(scroll.layer.mask as? CAGradientLayer)
            let colors = try XCTUnwrap(mask.colors as? [CGColor])
            XCTAssertLessThan(x < 0 ? colors.last!.alpha : colors.first!.alpha, 0.01)
        }
    }
    func testClipboardLongPreviewUsesViewportFadeAndKeepsItsTailReachable() throws {
        let preview = ClipboardInlinePreview(frame: CGRect(x: 0, y: 0, width: 220, height: 34))
        preview.show(String(repeating: "复制内容长文章 ", count: 120)); preview.layoutIfNeeded()
        XCTAssertNotNil(preview.layer.mask as? CAGradientLayer)
        preview.contentOffset.x = preview.contentSize.width - preview.bounds.width; preview.layoutIfNeeded()
        XCTAssertGreaterThan(preview.visibleStringRange.location, 500)
    }
    private final class Pan: UIPanGestureRecognizer {
        var phase: UIGestureRecognizer.State = .possible
        var distance: CGFloat = 0
        override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
        override func translation(in view: UIView?) -> CGPoint { CGPoint(x: 0, y: distance) }
    }
    func testDeleteDownwardUndoSurvivesCancelledControlContact() throws {
        let controller = TypingLabController(settings: KeyboardSettings()), host = try window(controller)
        defer { controller.model.suspend(); host.isHidden = true }
        controller.model.insertLiteral("原文👨‍👩‍👧‍👦123")
        controller.model.clearInput(); XCTAssertTrue(controller.model.canUndoClearInput)
        let button = KeyButton(key: KeyboardKey("删除", action: .delete))
        var received: Bool?
        button.onDeleteSwipe = { clear in received = clear; if !clear { _ = controller.model.undoClearInput() } }
        let gesture = Pan(); gesture.phase = .began; gesture.distance = 32
        button.perform(NSSelectorFromString("deletionGesture:"), with: gesture)
        button.sendActions(for: .touchCancel)
        gesture.phase = .ended
        button.perform(NSSelectorFromString("deletionGesture:"), with: gesture)
        XCTAssertEqual(received, false); XCTAssertEqual(controller.textView.text, "原文👨‍👩‍👧‍👦123")
    }
}
