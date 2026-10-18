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
        let candidate = try XCTUnwrap(model.candidates.first { $0.text == "你" }), context = model.candidateContext
        model.clearComposition(); controller.insert("另一位置")
        for character in "nihao" { model.handle(.text(String(character))) }
        model.chooseDisplayed(candidate, context: context)
        XCTAssertEqual(proxy.before, "另一位置nihao")
    }
    func testCandidateCollectionPinsResultsThroughMomentumAndReversals() async throws {
        let ribbon = CandidateScrollView()
        ribbon.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        let context = KeyboardModel.CandidateContext(raw: "shi", before: "shi", after: "", document: "field", language: .chinese)
        let old = (0..<40).map { Candidate(text: "候选\($0)", consumed: 3) }
        var transitions: [Bool] = []
        ribbon.onInteractionChanged = { transitions.append($0) }
        ribbon.update(old, context: context, arithmetic: false, accent: .systemTeal); ribbon.layoutIfNeeded()
        XCTAssertLessThan(ribbon.visibleCells.count, old.count, "Only visible cells should be created")
        ribbon.scrollViewWillBeginDragging(ribbon)
        ribbon.contentOffset.x = 70
        ribbon.scrollViewDidEndDragging(ribbon, willDecelerate: true)
        ribbon.update([Candidate(text: "新的结果", consumed: 3)], context: context, arithmetic: false, accent: .systemTeal)
        await Task.yield()
        XCTAssertTrue(ribbon.holdsCandidateUpdates)
        XCTAssertEqual(ribbon.numberOfItems(inSection: 0), 40)
        ribbon.scrollViewWillBeginDragging(ribbon)
        ribbon.scrollViewDidEndDragging(ribbon, willDecelerate: false)
        try await waitFor { !ribbon.holdsCandidateUpdates && ribbon.numberOfItems(inSection: 0) == 1 }
        XCTAssertEqual(transitions, [true, false], "One continuous interaction must not repeatedly start host refreshes")
    }
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

