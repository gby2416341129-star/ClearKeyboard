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
    func testTwoHundredItemsRetained() {
        for value in 0..<210 { store.add("clip \(value)") }
        XCTAssertEqual(store.clips.count, 200)
        XCTAssertEqual(store.clips.first?.text, "clip 209")
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
    func testSevenDaysAndPermanentRetention() {
        let start = Date(timeIntervalSince1970: 1_000)
        let week: TimeInterval = 7 * 24 * 3600
        store.add("old", now: start)
        store.add("recent", now: start.addingTimeInterval(60))
        store.prune(lifetime: week, now: start.addingTimeInterval(week + 1))
        XCTAssertEqual(store.clips.map(\.text), ["recent"])
        store.prune(lifetime: 0, now: start.addingTimeInterval(100 * week))
        XCTAssertEqual(store.clips.map(\.text), ["recent"])
        XCTAssertEqual(ClipboardStore(url: root.appendingPathComponent("clipboard.json")).clips, store.clips)
    }
}
