import XCTest
@testable import ClearCore

final class HostTextStateTests: XCTestCase {
    private func remote(_ before: String, after: String = "", selected: String = "", document: String = "A") -> HostTextSnapshot {
        HostTextSnapshot(before: before, after: after, selected: selected, document: document)
    }
    func testMarkedTypingAndPartialCommitUseTheLocalLedger() {
        var state = HostTextState(remote("前文"))
        for spelling in ["n", "ni", "nih", "niha", "nihao"] { state.setMarked(spelling, now: 10) }
        XCTAssertEqual(state.snapshot.before, "前文nihao")
        state.setMarked("你", now: 10); state.unmark(); state.setMarked("hao", now: 10)
        XCTAssertEqual(state.snapshot.before, "前文你hao")
        state.setMarked("好", now: 10); state.unmark()
        XCTAssertEqual(state.snapshot.before, "前文你好")
    }
    func testDelayedOwnNotificationsDoNotRewindOrClearCurrentSpelling() {
        var state = HostTextState(remote("前文"))
        state.setMarked("n", now: 10); state.setMarked("ni", now: 10.01)
        XCTAssertEqual(state.reconcile(remote("前文"), now: 10.02), .ownEdit)
        XCTAssertEqual(state.reconcile(remote("前文n"), now: 10.03), .ownEdit)
        XCTAssertEqual(state.snapshot.before, "前文ni")
        XCTAssertEqual(state.reconcile(remote("前文ni"), now: 10.04), .ownEdit)
        XCTAssertEqual(state.reconcile(remote("前文"), now: 10.05), .externalEdit)
    }
    func testHostContextTruncationKeepsTheActiveComposition() {
        let before = String(repeating: "历史内容", count: 30)
        var state = HostTextState(remote(before)); state.setMarked("nichifanlema", now: 10)
        XCTAssertEqual(state.reconcile(remote(String(state.snapshot.before.suffix(50))), now: 10.01), .ownEdit)
        state.setMarked("你吃饭了吗", now: 10.02)
        XCTAssertEqual(state.snapshot.before, before + "你吃饭了吗")
    }
    func testExternalSelectionAndDocumentChangesRemainDetectable() {
        var state = HostTextState(remote("abc")); state.setMarked("ni", now: 10)
        XCTAssertEqual(state.reconcile(remote("a", after: "c", selected: "b"), now: 10.01), .externalEdit)
        XCTAssertEqual(state.snapshot.selected, "b")
        state.insert("新", now: 10.02); XCTAssertEqual(state.snapshot.before, "a新")
        XCTAssertEqual(state.reconcile(remote("other", document: "B"), now: 10.03), .externalEdit)
        XCTAssertFalse(state.accepts(remote("a新"), actual: remote("other", document: "B"), now: 10.04))
    }
    func testCommitAllowsPendingOwnAcknowledgementButRejectsStaleOrForeignText() {
        var state = HostTextState(remote("")); state.setMarked("nihao", now: 10)
        let expected = state.snapshot
        XCTAssertTrue(state.accepts(expected, actual: remote(""), now: 10.02))
        XCTAssertTrue(state.accepts(expected, actual: remote(""), now: 12), "An active marked range does not expire while the user reads candidates")
        state.unmark()
        XCTAssertFalse(state.accepts(expected, actual: remote(""), now: 12))
        XCTAssertFalse(state.accepts(expected, actual: remote("different"), now: 10.03))
        XCTAssertFalse(state.accepts(expected, actual: remote("nihao", document: "B"), now: 10.03))
    }
    func testCursorAndDeletionPreserveGraphemes() {
        var state = HostTextState(remote("A👨‍👩‍👧‍👦B", after: "C"))
        state.moveCursor(-2); XCTAssertEqual(state.snapshot.before, "A"); XCTAssertEqual(state.snapshot.after, "👨‍👩‍👧‍👦BC")
        state.moveCursor(1); state.deleteBackward()
        XCTAssertEqual(state.snapshot.before, "A"); XCTAssertEqual(state.snapshot.after, "BC")
    }
    func testHostMayExcludeTheActiveMarkedRangeFromItsContext() {
        var state = HostTextState(remote("前文", after: "后文")); state.setMarked("nihao", now: 10)
        XCTAssertEqual(state.reconcile(remote("前文", after: "后文"), now: 20), .ownEdit)
        XCTAssertEqual(state.snapshot.before, "前文nihao")
        XCTAssertTrue(state.hasMarkedText)
        XCTAssertFalse(state.accepts(state.snapshot, actual: remote("前文", after: "other"), now: 21))
        XCTAssertEqual(state.reconcile(remote("前", after: "文后文"), now: 22), .externalEdit)
    }
}
