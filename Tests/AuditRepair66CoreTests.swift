import XCTest
@testable import ClearCore

final class AuditRepair66CoreTests: XCTestCase {
    func testStaleStoresMergeMutationsAndDoNotResurrectDeletedClips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("clipboard.json")
        let a = ClipboardStore(url: url), b = ClipboardStore(url: url)
        XCTAssertTrue(a.add("first")); XCTAssertTrue(b.add("second"))
        XCTAssertEqual(Set(ClipboardStore(url: url).clips.map(\.text)), ["first", "second"])
        let id = try XCTUnwrap(a.clips.first?.id)
        XCTAssertTrue(b.delete(id)); XCTAssertTrue(a.add("third"))
        XCTAssertEqual(Set(ClipboardStore(url: url).clips.map(\.text)), ["second", "third"])
    }
    func testFailedPersistenceDoesNotClaimSuccessOrChangeMemory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0]).write(to: root)
        let store = ClipboardStore(url: root.appendingPathComponent("clipboard.json"))
        XCTAssertFalse(store.add("unsaved")); XCTAssertTrue(store.clips.isEmpty); XCTAssertNotNil(store.lastError)
    }
    func testPinnedRecopyHasANewEventAndKeepsPin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardStore(url: root.appendingPathComponent("clipboard.json"))
        store.add("same"); let old = try XCTUnwrap(store.clips.first)
        store.togglePin(old.id); store.add("same")
        XCTAssertNotEqual(store.clips.first?.id, old.id); XCTAssertEqual(store.clips.first?.pinned, true)
    }
    func testLegacyMergePreservesBothDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = ClipboardStore(url: root.appendingPathComponent("old/clipboard.json"))
        let current = ClipboardStore(url: root.appendingPathComponent("new/clipboard.json"))
        old.add("legacy"); current.add("shared"); XCTAssertTrue(current.mergeLegacy(from: root.appendingPathComponent("old/clipboard.json")))
        XCTAssertEqual(Set(current.clips.map(\.text)), ["legacy", "shared"])
    }
    func testResetEpochCannotBeResurrectedByAnOldWriter() throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let old = defaults.string(forKey: "clear.learned.epoch")
        LearningStore.save(LearningMemory(learned: ["old": 7]), defaults: defaults, epoch: old)
        LearningStore.clear(defaults)
        LearningStore.save(LearningMemory(learned: ["late": 9]), defaults: defaults, epoch: old)
        XCTAssertTrue(LearningStore.load(defaults, epoch: defaults.string(forKey: "clear.learned.epoch")).learned.isEmpty)
    }
    func testArithmeticDoesNotFuseSeparatedNumbers() {
        XCTAssertNil(InlineArithmetic.result(in: "1 2+3")); XCTAssertNil(InlineArithmetic.result(in: "1. 2+3"))
        XCTAssertEqual(InlineArithmetic.result(in: "1 + 2")?.value, "3")
    }
    func testBoundedAttachmentRejectsOversizeBeforeLoadingPayload() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: UInt64(ClipboardStore.attachmentLimit + 1)); try handle.close()
        XCTAssertThrowsError(try ClipboardStore.boundedAttachment(at: file))
    }
}