import XCTest
import UIKit
@testable import ClearKeyboard

@MainActor final class ClipboardCaptureRepairTests: XCTestCase {
    private func waitFor(_ predicate: () -> Bool) async throws {
        let limit = Date().addingTimeInterval(2)
        while !predicate(), Date() < limit { try await Task.sleep(nanoseconds: 15_000_000) }
        XCTAssertTrue(predicate())
    }
    func testRemoteCopyWithoutNotificationIsSavedOnceAndStopsWhenHidden() async throws {
        let suite = "clear.clipboard.repair." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("clipboard.json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var revision = 1, reads = 0, payload = "first copy"
        let capture = ClipboardCapture(defaults: defaults, makeStore: { ClipboardStore(url: url) }, changeCount: { revision }, hasStrings: { true }, readText: { reads += 1; return payload }, revisionCheckInterval: 0.03)
        var settings = KeyboardSettings(); settings.automaticClipboard = true
        capture.activate(settings: settings, allowed: true)
        defer { capture.stop() }
        XCTAssertEqual(reads, 1)
        revision = 2; payload = "https://example.com/copied-without-a-notification"
        try await waitFor { ClipboardStore(url: url).clips.first?.text == payload }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(reads, 2, "Metadata checks must not repeatedly read a payload")
        capture.stop(); revision = 3; payload = "copied while hidden"
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(reads, 2)
        capture.activate(settings: settings, allowed: true)
        XCTAssertEqual(ClipboardStore(url: url).clips.map(\.text), [payload, "https://example.com/copied-without-a-notification", "first copy"])
    }
    func testExplicitSaveWorksWithAutomaticCaptureOffAndRetriesTheSameRevision() throws {
        let suite = "clear.clipboard.manual." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("clipboard.json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var payload: String? = nil, reads = 0, callbacks = 0
        let capture = ClipboardCapture(defaults: defaults, makeStore: { ClipboardStore(url: url) }, changeCount: { 9 }, hasStrings: { true }, readText: { reads += 1; return payload })
        capture.onCapture = { callbacks += 1 }
        var settings = KeyboardSettings(); settings.automaticClipboard = false
        capture.activate(settings: settings, allowed: true)
        XCTAssertEqual(reads, 0)
        XCTAssertFalse(capture.captureManually())
        payload = "permission now allows this same copy"
        XCTAssertTrue(capture.captureManually())
        XCTAssertEqual(ClipboardStore(url: url).clips.first?.text, payload)
        XCTAssertEqual(callbacks, 1)
    }
    func testStorageFailureDoesNotReportSuccessfulCollection() throws {
        let suite = "clear.clipboard.write-failure." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: blocker)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: blocker) }
        let capture = ClipboardCapture(defaults: defaults, makeStore: { ClipboardStore(url: blocker.appendingPathComponent("clipboard.json")) }, changeCount: { 1 }, hasStrings: { true }, readText: { "must reach disk" })
        var callbacks = 0; capture.onCapture = { callbacks += 1 }
        XCTAssertFalse(capture.captureManually())
        capture.acceptText("system paste must reach disk too")
        XCTAssertEqual(callbacks, 0)
    }
}
