import XCTest
import UIKit
import CoreText

@MainActor final class Typing77Tests: XCTestCase {
    private func width(_ text: String) -> CGFloat {
        let value = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 17)])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(value), nil, nil, nil))
    }
    private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 15
        while !predicate(), CACurrentMediaTime() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(predicate())
    }
    func testPointerTargetsAreIndependentOfEventRateAndReverseImmediately() {
        let distance = width("345678")
        var single = ProxyTrackpad(before: "12345678", after: "")
        XCTAssertEqual(single.offset(translation: CGPoint(x: -distance, y: 0), now: 0.01), -6)
        XCTAssertEqual(single.offset(translation: .zero, now: 0.02), 6)
        var sampled = ProxyTrackpad(before: "12345678", after: "")
        for step in 1...60 {
            _ = sampled.offset(translation: CGPoint(x: -distance * CGFloat(step) / 60, y: 0), now: Double(step))
        }
        XCTAssertEqual(sampled.displacement, -6, "Speed and sampling must not accumulate a different pointer target")
        XCTAssertEqual(sampled.offset(translation: .zero, now: 61), 6)
        _ = sampled.offset(translation: CGPoint(x: -1000, y: 0), now: 62)
        XCTAssertGreaterThan(sampled.offset(translation: CGPoint(x: -1000 + width("1"), y: 0), now: 63), 0)
        XCTAssertEqual(sampled.offset(translation: CGPoint(x: .nan, y: 0), now: 64), 0)
        var proportional = ProxyTrackpad(before: "WiWi", after: "")
        XCTAssertEqual(proportional.offset(translation: CGPoint(x: -width("Wi"), y: 0)), -2)
        print("POINTER_TARGETS oneJump=6 eventRateIndependent=true reversalImmediate=true proportionalGlyphs=true")
    }
    func testRemoteControllerUsesOneJumpAndNoContextReadsDuringMovement() async throws {
        let proxy = Typing77Proxy(), controller = Typing77Controller()
        proxy.textView.text = "12345678"; proxy.textView.selectedRange = NSRange(location: 8, length: 0)
        controller.proxy = proxy; controller.loadViewIfNeeded()
        controller.textDidChange(nil)
        controller.beginTrackpad(); proxy.reads = 0
        controller.trackCursor(translation: CGPoint(x: -width("345678"), y: 0))
        XCTAssertEqual(proxy.moves, [-6]); XCTAssertEqual(proxy.textView.selectedRange.location, 2)
        controller.trackCursor(translation: .zero)
        XCTAssertEqual(proxy.moves, [-6, 6]); XCTAssertEqual(proxy.reads, 0)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(proxy.reads, 0, "A stationary finger must not trigger blocking idle context reads")
        controller.endTrackpad()
        XCTAssertEqual(proxy.reads, 0, "Finger-up must not block on proxy IPC before the next key")
        XCTAssertEqual(proxy.textView.text, "12345678"); XCTAssertEqual(controller.contextBefore, "12345678")
        let text = "A👨‍👩‍👧‍👦é中"
        proxy.textView.text = text; proxy.textView.selectedRange = NSRange(location: text.utf16.count, length: 0)
        controller.viewWillAppear(false); controller.beginTrackpad(); proxy.moves = []; proxy.reads = 0
        controller.trackCursor(translation: CGPoint(x: width("A") - width(text), y: 0))
        XCTAssertEqual(proxy.textView.selectedRange.location, 1)
        XCTAssertEqual(proxy.moves, [1 - text.utf16.count]); XCTAssertEqual(proxy.reads, 0)
        controller.endTrackpad(); controller.viewWillDisappear(false)
        print("CARET_REAL_UIKIT jumpWrites=1 dragProxyReads=0 emojiGraphemesIntact=true textUnchanged=true")
    }
    func testSpaceGestureForwardsMovesBeforeAnyDisplayTickAndNeverInsertsSpace() throws {
        var pulses = 0, translations: [CGPoint] = [], spaces = 0
        let key = KeyButton(key: KeyboardKey("空格", .space), vibration: KeyboardVibration { _ in pulses += 1 })
        var settings = KeyboardSettings(); settings.vibrationEnabled = false; key.apply(settings)
        let gesture = Typing77LongPress(), selector = NSSelectorFromString("cursorGesture:")
        key.onCursor = { translations.append($0) }; key.onAction = { _ in spaces += 1 }
        gesture.phase = .began; gesture.point = CGPoint(x: 100, y: 100)
        key.perform(selector, with: gesture)
        gesture.phase = .changed; gesture.point.x = 50; key.perform(selector, with: gesture)
        XCTAssertEqual(translations, [CGPoint(x: -50, y: 0)], "No display/run-loop callback should be required")
        gesture.point.x = 90; key.perform(selector, with: gesture)
        XCTAssertEqual(translations.last, CGPoint(x: -10, y: 0))
        gesture.phase = .ended; key.perform(selector, with: gesture)
        key.sendActions(for: .touchUpInside)
        XCTAssertEqual(spaces, 0); XCTAssertEqual(pulses, 1)
        print("SPACE_GESTURE immediateChangedDelivery=true independentEntryHaptic=true releaseSpaces=0")
    }
    func testFastKeyFeedbackIsVisibleAtContactAndTextIsNotDelayed() async throws {
        let controller = UIViewController(), window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        window.rootViewController = controller; window.makeKeyAndVisible()
        let key = KeyButton(key: KeyboardKey("A", .text("a")), vibration: KeyboardVibration { _ in })
        key.frame = CGRect(x: 20, y: 20, width: 40, height: 50); controller.view.addSubview(key); key.layoutIfNeeded()
        let plate = try XCTUnwrap(key.subviews.first { $0.accessibilityIdentifier == "key.face" })
        var text = ""; key.onAction = { _ in text += "a" }
        for _ in 0..<30 {
            key.sendActions(for: .touchDown)
            XCTAssertLessThan(plate.transform.a, 1, "Current contact must be visible synchronously")
            key.sendActions(for: .touchUpInside)
            XCTAssertLessThan(plate.transform.a, 1, "A fast release must not erase the contact before a single frame")
        }
        XCTAssertEqual(text, String(repeating: "a", count: 30))
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(plate.transform, .identity)
        window.isHidden = true
        print("FAST_KEY_CONTACT contacts=30 immediatePress=true orderedText=true minimumVisibleMs=45")
    }


    func testBlurPreparationDoesNotBlockTheTypingThread() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 420, height: 48)).image { _ in
            ("今天我们一起去吃饭 你好 世界" as NSString).draw(at: CGPoint(x: 8, y: 8), withAttributes: [.font: UIFont.systemFont(ofSize: 19)])
        }
        let started = CACurrentMediaTime()
        for _ in 0..<30 { let effect = CandidateInkMotion(image: image); effect.run(appearing: true); effect.finish() }
        let elapsed = (CACurrentMediaTime() - started) * 1000
        XCTAssertLessThan(elapsed, 50, "Blur convolution must not run in each key's main-thread callback")
        print("INK_PREPARATION_MAIN_MS \(elapsed) transitions=30 blurWorkOnBackground=true")
    }
    func testRapidRealUIKitTypingKeepsLatestSpellingWithAllFuzzyEnabled() async throws {
        let proxy = Typing77Proxy(), controller = Typing77Controller(); controller.proxy = proxy; controller.loadViewIfNeeded()
        let surface = try XCTUnwrap(views(controller.view).compactMap { $0 as? KeyboardSurface }.first)
        let model = surface.model
        model.settings.language = .chinese; model.settings.fuzzyPairs = Set(InputPreferenceKeys.fuzzyPairs)
        model.settings.learnChoices = false; model.settings.automaticClipboard = false; model.settings.vibrationEnabled = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        var keyTimes: [Double] = []
        for (spelling, expected) in [("nihao", "你好"), ("zhongguo", "中国")] {
            let before = proxy.textView.text ?? ""
            for letter in spelling {
                let key = try XCTUnwrap(views(surface).compactMap { $0 as? KeyButton }.first { $0.key.action == .text(String(letter)) })
                let started = CACurrentMediaTime(); key.sendActions(for: .touchDown); key.sendActions(for: .touchUpInside)
                keyTimes.append((CACurrentMediaTime() - started) * 1000)
            }
            XCTAssertEqual(model.composition.raw, spelling)
            try await waitFor { model.candidatesAreCurrent && model.candidates.first?.text == expected }
            let candidate = try XCTUnwrap(model.candidates.first)
            model.chooseDisplayed(candidate, context: model.candidateContext)
            try await waitFor { proxy.textView.text == before + expected }
        }
        XCTAssertTrue(model.composition.isEmpty)
        print("RAPID_REAL_UIKIT noDroppedLetters=true fullFuzzy=true keyCallbackMs=\(keyTimes)")
    }
}

@MainActor private final class Typing77Controller: KeyboardViewController {
    var proxy: UITextDocumentProxy!
    override var textDocumentProxy: UITextDocumentProxy { proxy ?? super.textDocumentProxy }
}
@MainActor private final class Typing77LongPress: UILongPressGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    var point = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
    override func location(in view: UIView?) -> CGPoint { point }
}
@MainActor private final class Typing77Proxy: NSObject, UITextDocumentProxy {
    let textView = UITextView(), documentIdentifier = UUID()
    var reads = 0, moves: [Int] = []
    override init() {
        super.init(); textView.inputView = UIView(frame: .zero)
        textView.autocorrectionType = .no; textView.spellCheckingType = .no
    }
    var documentContextBeforeInput: String? { reads += 1; return (textView.text as NSString).substring(to: textView.selectedRange.location) }
    var documentContextAfterInput: String? { reads += 1; return (textView.text as NSString).substring(from: NSMaxRange(textView.selectedRange)) }
    var selectedText: String? { reads += 1; return textView.selectedTextRange.flatMap { textView.text(in: $0) } }
    var documentInputMode: UITextInputMode? { nil }; var hasText: Bool { textView.hasText }
    func insertText(_ text: String) { textView.insertText(text) }
    func deleteBackward() { textView.deleteBackward() }
    func setMarkedText(_ text: String, selectedRange: NSRange) { textView.setMarkedText(text, selectedRange: selectedRange) }
    func unmarkText() { textView.unmarkText() }
    func adjustTextPosition(byCharacterOffset offset: Int) {
        moves.append(offset)
        guard let selection = textView.selectedTextRange, let position = textView.position(from: selection.end, offset: offset) else { return }
        textView.selectedTextRange = textView.textRange(from: position, to: position)
    }
}
