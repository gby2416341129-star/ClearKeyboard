import XCTest
import UIKit

@MainActor final class RemoteProxyPerformanceTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants($0) } }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Current candidates did not arrive")
    }
    func testRealControllerKeyPathDoesNotSynchronouslyReadRemoteContext() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 276); controller.view.layoutIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        proxy.reads = 0; proxy.contextReads = 0; proxy.readDelay = 0.008
        let start = ProcessInfo.processInfo.systemUptime
        for character in "nichifankm" { model.handle(.text(String(character))) }
        let keyMs = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        XCTAssertEqual(proxy.reads, 0, "Typing must not poll the remote proxy for every marked-text update or render")
        try await waitFor { model.candidatesAreCurrent && model.candidates.first?.text == "你吃饭了吗" }
        XCTAssertEqual(proxy.reads, 0)
        let candidateMs = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        print("REMOTE_PROXY_INPUT keys=10 synchronousContextReads=\(proxy.reads) keyMs=\(keyMs) candidateMs=\(candidateMs)")
        XCTAssertLessThan(keyMs, 150); XCTAssertLessThan(candidateMs, 400)
        let candidate = try XCTUnwrap(model.candidates.first)
        model.chooseDisplayed(candidate, context: model.candidateContext)
        XCTAssertEqual(proxy.reads, 1, "A tap validates document identity without blocking on remote text fields")
        XCTAssertEqual(proxy.contextReads, 0)
        XCTAssertEqual(proxy.before, "你吃饭了吗")
    }
    func testDelayedOwnHostNotificationsDoNotDiscardCandidates() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "nihao" { model.handle(.text(String(character))) }
        proxy.visibleBefore = "n"; controller.textDidChange(nil)
        XCTAssertEqual(model.composition.raw, "nihao")
        proxy.visibleBefore = nil; controller.textDidChange(nil)
        try await waitFor { model.candidatesAreCurrent }
        XCTAssertEqual(model.candidates.first?.text, "你好")
        proxy.before = "另一个输入框"; proxy.markedLength = 0; controller.textDidChange(nil)
        try await waitFor { model.composition.isEmpty }
        XCTAssertEqual(controller.contextBefore, "另一个输入框")
    }
    func testOwnNotificationBurstPerformsOneDeferredContextRead() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        proxy.reads = 0; proxy.contextReads = 0; proxy.readDelay = 0.008
        let start = ProcessInfo.processInfo.systemUptime
        for character in "nichifankm" { model.handle(.text(String(character))); controller.textDidChange(nil) }
        XCTAssertEqual(proxy.reads, 0, "Even document identity reads must be outside a key's notification callback")
        XCTAssertEqual(proxy.contextReads, 0, "Own notifications must not synchronously poll text during rapid typing")
        XCTAssertLessThan((ProcessInfo.processInfo.systemUptime - start) * 1_000, 250)
        try await waitFor { model.candidatesAreCurrent && proxy.contextReads > 0 }
        XCTAssertEqual(proxy.contextReads, 3, "A burst needs only one before/after/selection reconciliation")
        XCTAssertEqual(model.composition.raw, "nichifankm")
        print("REMOTE_HOST_NOTIFICATIONS keys=10 synchronousContextReads=0 deferredContextReads=\(proxy.contextReads)")
    }
    func testCandidateButtonCommitsWithoutSpaceWhenHostOmitsMarkedText() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        proxy.omitsMarkedText = true; controller.proxy = proxy; controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 276); controller.view.layoutIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "shaod" { model.handle(.text(String(character))) }
        controller.textDidChange(nil)
        try await waitFor { model.candidatesAreCurrent && model.candidates.first?.text == "稍等" }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(model.composition.raw, "shaod", "Reading candidates must not expire an uncommitted spelling")
        for view in descendants(controller.view) { view.setNeedsLayout(); view.layoutIfNeeded() }
        let button = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "candidate.稍等" })
        XCTAssertTrue(button.isUserInteractionEnabled)
        proxy.contextReads = 0; proxy.contextReadDelay = 0.15
        let start = ProcessInfo.processInfo.systemUptime
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(proxy.before, "稍等"); XCTAssertTrue(model.composition.isEmpty)
        XCTAssertEqual(proxy.contextReads, 0, "A finger choice must not read slow marked-text context")
        XCTAssertLessThan((ProcessInfo.processInfo.systemUptime - start) * 1_000, 150)
        print("CANDIDATE_NO_SPACE hostOmitsMarked=true pauseMs=1200 contextReadsOnTap=0 committed=passed")
    }
    func testReversingCandidateInteractionNeverRunsPendingHostReads() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first)
        let model = surface.model
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "shi" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent }
        let ribbon = try XCTUnwrap(descendants(surface).compactMap { $0 as? CandidateScrollView }.first)
        proxy.contextReads = 0; controller.textDidChange(nil)
        for _ in 0..<4 {
            ribbon.scrollViewWillBeginDragging(ribbon)
            try await Task.sleep(nanoseconds: 110_000_000)
            ribbon.scrollViewDidEndDragging(ribbon, willDecelerate: true)
        }
        ribbon.scrollViewWillBeginDragging(ribbon)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(proxy.contextReads, 0, "Host reads must stay deferred across direction reversals")
        ribbon.scrollViewDidEndDragging(ribbon, willDecelerate: false)
        try await waitFor { proxy.contextReads > 0 }
        XCTAssertEqual(proxy.contextReads, 3)
        print("CANDIDATE_REVERSALS turns=4 contextReadsDuringContact=0 idleReconciliation=passed")
    }
    func testCandidateCannotCommitToANewDocument() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "nihao" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent }
        let candidate = try XCTUnwrap(model.candidates.first), context = model.candidateContext
        proxy.identity = UUID(); proxy.before = "另一输入框"; proxy.markedLength = 0
        model.chooseDisplayed(candidate, context: context)
        XCTAssertEqual(proxy.before, "另一输入框")
    }
    func testVisiblePrefixCanBeTappedWhileMoreSpellingIsPending() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "ni" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent }
        let candidate = try XCTUnwrap(model.candidates.first { $0.text == "你" }), context = model.candidateContext
        for character in "hao" { model.handle(.text(String(character))) }
        model.chooseDisplayed(candidate, context: context)
        XCTAssertEqual(proxy.before, "你hao")
        XCTAssertEqual(model.composition.raw, "hao", "A visible prefix choice must retain the later spelling")
    }
    func testPrefixChoiceDoesNotCrossAnExternalCursorEdit() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "ni" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent }
        let candidate = try XCTUnwrap(model.candidates.first { $0.text == "你" }), context = model.candidateContext
        model.clearComposition(); controller.insert("另一位置")
        for character in "nihao" { model.handle(.text(String(character))) }
        model.chooseDisplayed(candidate, context: context)
        XCTAssertEqual(proxy.before, "另一位置nihao")
    }
    func testVisibleCompletionConsumesLaterLettersWithinItsReading() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "nih" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent }
        let candidate = try XCTUnwrap(model.candidates.first { $0.text == "你好" }), context = model.candidateContext
        for character in "aoma" { model.handle(.text(String(character))) }
        model.chooseDisplayed(candidate, context: context)
        XCTAssertEqual(proxy.before, "你好ma", "Completed hao belongs to 你好; only the following word stays marked")
        XCTAssertEqual(model.composition.raw, "ma")
    }
    func testCandidateStripPinsResultsUntilTheSpellingChanges() async throws {
        let ribbon = CandidateScrollView()
        ribbon.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        let context = KeyboardModel.CandidateContext(raw: "shi", before: "shi", after: "", document: "field", language: .chinese)
        let old = (0..<24).map { Candidate(text: "候选\($0)", consumed: 3) }
        ribbon.update(old, context: context, arithmetic: false, accent: .systemTeal); ribbon.layoutIfNeeded()
        let controls = descendants(ribbon).compactMap { $0 as? UIButton }
        let frames = controls.map(\.frame)
        let contentSize = ribbon.contentSize
        XCTAssertEqual(controls.count, old.count)
        ribbon.scrollViewWillBeginDragging(ribbon)
        // Exercise snapshot retention and geometry only. Delegate calls and
        // offsets cannot validate native finger recognition or device latency.
        for offset: CGFloat in [70, 130, 40, 95, 20, 70] {
            ribbon.contentOffset.x = offset; ribbon.layoutIfNeeded()
            XCTAssertEqual(controls.map(\.frame), frames)
            XCTAssertEqual(ribbon.contentSize, contentSize)
        }
        ribbon.update([Candidate(text: "新的结果", consumed: 3)], context: context, arithmetic: false, accent: .systemTeal)
        ribbon.scrollViewDidEndDragging(ribbon, willDecelerate: false)
        await Task.yield()
        XCTAssertEqual(descendants(ribbon).compactMap { $0 as? UIButton }, controls)
        XCTAssertEqual(ribbon.contentOffset.x, 70, accuracy: 0.1)
        var selection: String?
        ribbon.onSelect = { candidate, _, _ in selection = candidate.text }
        controls[1].sendActions(for: .touchUpInside)
        XCTAssertEqual(selection, "候选1", "A late result must not change the visible tap target")
        let nextContext = KeyboardModel.CandidateContext(raw: "shij", before: "shij", after: "", document: "field", language: .chinese)
        ribbon.update([Candidate(text: "时间", consumed: 4)], context: nextContext, arithmetic: false, accent: .systemTeal)
        ribbon.layoutIfNeeded()
        let updated = descendants(ribbon).compactMap { $0 as? UIButton }
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.first?.accessibilityIdentifier, "candidate.时间")
        XCTAssertEqual(ribbon.contentOffset.x, 0, accuracy: 0.1)
        XCTAssertLessThanOrEqual(ribbon.contentSize.height, ribbon.bounds.height)
    }
    func testCandidateStripReceivesTouchesAcrossWordsGapsAndUnusedSpace() throws {
        let ribbon = CandidateScrollView()
        ribbon.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        let context = KeyboardModel.CandidateContext(raw: "shi", before: "shi", after: "", document: "field", language: .chinese)
        let candidates = (0..<24).map { Candidate(text: "候选\($0)", consumed: 3) }
        ribbon.update(candidates, context: context, arithmetic: false, accent: .systemTeal)
        ribbon.layoutIfNeeded()
        for width: CGFloat in [320, 240] {
            ribbon.frame.size.width = width; ribbon.layoutIfNeeded()
            for offset: CGFloat in [0, 95, 20, 130] {
                ribbon.contentOffset.x = offset; ribbon.layoutIfNeeded()
                for x in stride(from: CGFloat(1), to: width, by: 3) {
                    for y: CGFloat in [1, 22, 43] {
                        let point = CGPoint(x: ribbon.bounds.minX + x, y: y)
                        XCTAssertTrue(ribbon.hitTest(point, with: nil) === ribbon,
                                      "Every visible point must reach the row at offset \(offset), point \(point)")
                    }
                }
            }
        }
        let next = KeyboardModel.CandidateContext(raw: "shij", before: "shij", after: "", document: "field", language: .chinese)
        ribbon.update([Candidate(text: "时", consumed: 4)], context: next, arithmetic: false, accent: .systemTeal)
        ribbon.layoutIfNeeded()
        XCTAssertTrue(ribbon.hitTest(CGPoint(x: 1, y: 22), with: nil) === ribbon)
        XCTAssertTrue(ribbon.hitTest(CGPoint(x: 230, y: 22), with: nil) === ribbon,
                      "Unused space after a short row must also accept a drag")
        XCTAssertNil(ribbon.hitTest(CGPoint(x: -1, y: 22), with: nil))
        XCTAssertNil(ribbon.hitTest(CGPoint(x: 120, y: 45), with: nil))
    }
    func testCandidateRowTapsExcludeGapsAndKeepAccessibilityActivation() throws {
        let ribbon = CandidateScrollView()
        ribbon.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        let context = KeyboardModel.CandidateContext(raw: "shi", before: "shi", after: "", document: "field", language: .chinese)
        ribbon.update((0..<24).map { Candidate(text: "候选\($0)", consumed: 3) },
                      context: context, arithmetic: false, accent: .systemTeal)
        ribbon.layoutIfNeeded()
        let controls = descendants(ribbon).compactMap { $0 as? UIButton }
        let word = controls[2]
        var selected: [String] = []
        ribbon.onSelect = { candidate, snapshot, arithmetic in
            selected.append(candidate.text)
            XCTAssertEqual(snapshot, context); XCTAssertFalse(arithmetic)
        }
        for offset: CGFloat in [0, 95] {
            ribbon.contentOffset.x = offset; ribbon.layoutIfNeeded()
            ribbon.selectCandidate(at: word.convert(CGPoint(x: word.bounds.midX, y: 22), to: ribbon))
            XCTAssertEqual(selected.last, "候选2")
            let count = selected.count
            ribbon.selectCandidate(at: word.convert(CGPoint(x: word.bounds.maxX - 6, y: 22), to: ribbon))
            XCTAssertEqual(selected.count, count, "A light tap in a 12-point gap must not select a word")
        }
        XCTAssertEqual(selected, ["候选2", "候选2"])
        XCTAssertEqual(ribbon.accessibilityElements?.count, controls.count)
        XCTAssertTrue(word.accessibilityActivate())
        XCTAssertEqual(selected, ["候选2", "候选2", "候选2"])
    }
    func testPacedKeysDoNotReadTheHostInTheirFrames() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        host.addChild(controller); host.view.addSubview(controller.view)
        NSLayoutConstraint.activate([controller.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.view.bottomAnchor)])
        controller.didMove(toParent: host)
        host.view.layoutIfNeeded(); controller.view.layoutIfNeeded()
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first)
        let model = surface.model
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        let frames = KeyboardFrameProbe()
        defer { frames.stop(); window.isHidden = true; model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        try await Task.sleep(nanoseconds: 100_000_000)
        frames.start()
        let buttons = descendants(surface).compactMap { $0 as? KeyButton }
        for view in descendants(surface) { view.layoutIfNeeded() }
        let originalFrames = buttons.map(\.frame), originalHeight = surface.desiredHeight
        proxy.reads = 0; proxy.contextReads = 0; proxy.readDelay = 0.012
        var costs: [Double] = []
        for character in "nichifankmnihao" {
            let button = try XCTUnwrap(buttons.first { $0.key.action == .text(String(character)) })
            let start = ProcessInfo.processInfo.systemUptime
            button.sendActions(for: .touchDown); button.sendActions(for: .touchUpInside)
            controller.textDidChange(nil); controller.selectionDidChange(nil)
            costs.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            // Separate run-loop turns: a tight for-loop misses per-frame host work.
            try await Task.sleep(nanoseconds: 45_000_000)
        }
        XCTAssertEqual(proxy.reads, 0, "Continuous keys and acknowledgements must not poll the proxy")
        XCTAssertEqual(buttons.map(\.frame), originalFrames)
        XCTAssertEqual(surface.desiredHeight, originalHeight)
        let sorted = costs.sorted()
        print("PACED_KEY_FRAMES keys=\(costs.count) hostReads=\(proxy.reads) p95Ms=\(sorted[Int(Double(sorted.count - 1) * 0.95)]) maxMs=\(sorted.last!)")
        let gaps = frames.gaps.sorted()
        XCTAssertGreaterThan(gaps.count, 5, "The real window must keep drawing during the paced input")
        if !gaps.isEmpty {
            print("SIMULATOR_DISPLAY_FRAMES samples=\(gaps.count) p95Ms=\(gaps[Int(Double(gaps.count - 1) * 0.95)] * 1_000) maxMs=\(gaps.last! * 1_000)")
        }
        try await waitFor { proxy.contextReads > 0 }
        XCTAssertEqual(proxy.contextReads, 3, "Read the final host snapshot once after the typing burst")
    }
    func testHoldingAKeyDefersAnAlreadyScheduledHostRead() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        proxy.contextReads = 0; controller.textDidChange(nil)
        controller.keyInteractionChanged(true)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(proxy.contextReads, 0)
        controller.keyInteractionChanged(false)
        try await waitFor { proxy.contextReads > 0 }
        XCTAssertEqual(proxy.contextReads, 3)
    }
    func testSlowWordLookupNeverRunsOnTheKeyThreadOrOverwritesNewerResults() async throws {
        let document = WordLookupDocument()
        let lookup = expectation(description: "Delayed word worker finishes")
        var settings = KeyboardSettings(); settings.automaticClipboard = false; settings.learnChoices = false
        let model = KeyboardModel(document: document, settings: settings) { engine, raw, preferred in
            XCTAssertFalse(Thread.isMainThread, "A mapped-file lookup must not run inside a touch event")
            if raw == "nihao" {
                Thread.sleep(forTimeInterval: 0.15)
                lookup.fulfill()
                return [Candidate(text: "过期的快速结果", consumed: 5)]
            }
            return engine.immediateCandidates(raw, preferred: preferred)
        }
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        let start = ProcessInfo.processInfo.systemUptime
        for character in "nihao" { model.handle(.text(String(character))) }
        XCTAssertEqual(document.before, "nihao", "Typed spelling reaches the editor before lookup completes")
        XCTAssertLessThan((ProcessInfo.processInfo.systemUptime - start) * 1_000, 50)
        try await waitFor { model.candidates.first?.text == "你好" && model.candidatesAreCurrent }
        await fulfillment(of: [lookup], timeout: 2)
        // Allow the worker's main-queue delivery to run after its expectation.
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.candidates.first?.text, "你好", "Late fast results cannot replace a settled sentence")
    }
}

@MainActor private final class KeyboardFrameProbe: NSObject {
    private var link: CADisplayLink?
    private var previous: CFTimeInterval?
    private(set) var gaps: [Double] = []
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        let rate = Float(UIScreen.main.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common); self.link = link
    }
    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let previous { gaps.append(now - previous) }; previous = now
    }
    func stop() { link?.invalidate(); link = nil }
}

@MainActor private final class WordLookupDocument: KeyboardDocument {
    var before = "", marked = ""
    var contextBefore: String { before }; var contextAfter: String { "" }
    let documentIdentity = UUID().uuidString
    var selectedText: String { "" }; var enterTitle: String { "换行" }
    var needsGlobe: Bool { false }; var fullAccess: Bool { false }
    var prefersEnglish: Bool { false }; var capitalization: UITextAutocapitalizationType { .none }
    func insert(_ text: String) { before += text }
    func setMarkedText(_ text: String) { before = String(before.dropLast(marked.count)) + text; marked = text }
    func unmarkText() { marked = "" }
    func deleteBackward() { if !before.isEmpty { before.removeLast() } }
    func moveCursor(_ offset: Int) {}; func beginTrackpad() {}; func trackCursor(translation: CGPoint) {}
    func endTrackpad() {}; func nextKeyboard() {}
    func clearInput() -> DeletedInput? { nil }; func restoreInput(_ value: DeletedInput) -> Bool { false }
}

@MainActor private final class ProxyKeyboardController: KeyboardViewController {
    var proxy: DelayedDocumentProxy?
    override var textDocumentProxy: UITextDocumentProxy { if let proxy { return proxy }; return super.textDocumentProxy }
}

@MainActor private final class DelayedDocumentProxy: NSObject, UITextDocumentProxy {
    var before = "", after = "", selected = ""
    var visibleBefore: String?
    var markedLength = 0
    var reads = 0
    var contextReads = 0
    var readDelay: TimeInterval = 0
    var contextReadDelay: TimeInterval?
    var omitsMarkedText = false
    var identity = UUID()
    private func read(context: Bool = true) {
        reads += 1; if context { contextReads += 1 }
        let delay = context ? (contextReadDelay ?? readDelay) : readDelay
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    }
    var documentContextBeforeInput: String? { read(); return visibleBefore ?? (omitsMarkedText ? String(before.dropLast(min(markedLength, before.count))) : before) }
    var documentContextAfterInput: String? { read(); return after }
    var selectedText: String? { read(); return selected.isEmpty ? nil : selected }
    var documentIdentifier: UUID { read(context: false); return identity }
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { !before.isEmpty || !after.isEmpty }
    func insertText(_ text: String) { before += text; selected = ""; markedLength = 0 }
    func deleteBackward() { if !before.isEmpty { before.removeLast() }; markedLength = 0 }
    func setMarkedText(_ text: String, selectedRange: NSRange) {
        before = String(before.dropLast(min(markedLength, before.count))) + text; markedLength = text.count
    }
    func unmarkText() { markedLength = 0 }
    func adjustTextPosition(byCharacterOffset offset: Int) {
        let text = before + after, index = max(0, min(text.count, before.count + offset))
        before = String(text.prefix(index)); after = String(text.dropFirst(index)); markedLength = 0
    }
}

