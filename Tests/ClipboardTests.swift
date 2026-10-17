import XCTest
@testable import ClearCore

final class ClipboardTests: XCTestCase {
    private var root: URL!
    private var store: ClipboardStore!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = ClipboardStore(url: root.appendingPathComponent("clipboard.json"))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    func testOnlyTwentyItemsRetained() {
        for value in 0..<30 { store.add("clip \(value)") }
        XCTAssertEqual(store.clips.count, 20)
        XCTAssertEqual(store.clips.first?.text, "clip 29")
    }
    func testDeduplicationAndPersistence() {
        store.add("hello"); store.add("hello")
        XCTAssertEqual(store.clips.count, 1)
        XCTAssertEqual(ClipboardStore(url: root.appendingPathComponent("clipboard.json")).clips, store.clips)
    }
    func testExpiryPreservesPinnedItems() {
        let old = Date(timeIntervalSince1970: 1_000)
        store.add("keep", now: old); store.togglePin(store.clips[0].id)
        store.add("expire", now: old); store.prune(lifetime: 60, now: old.addingTimeInterval(61))
        XCTAssertEqual(store.clips.map(\.text), ["keep"])
    }
    func testTextBoundAndBlankInput() {
        store.add("  \n"); XCTAssertTrue(store.clips.isEmpty)
        store.add(String(repeating: "中", count: 2_100)); XCTAssertEqual(store.clips[0].text.count, 2_000)
    }
    func testPinLimitAndClear() {
        for value in 0..<12 { store.add("\(value)"); store.togglePin(store.clips[0].id) }
        XCTAssertEqual(store.clips.filter(\.pinned).count, 10)
        store.clear(); XCTAssertTrue(store.clips.isEmpty)
    }
}
