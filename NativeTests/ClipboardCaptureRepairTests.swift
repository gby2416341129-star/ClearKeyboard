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
    func testSystemPasteStoresURLOnlyProviderAsText() async throws {
        let suite = "clear.clipboard.url-provider." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("clipboard.json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let capture = ClipboardCapture(defaults: defaults, makeStore: { ClipboardStore(url: url) },
            changeCount: { 0 }, hasStrings: { false }, readText: { XCTFail("System paste must use the supplied provider"); return nil })
        let control = ClipboardPasteButton(capture: capture)
        let receiver = try XCTUnwrap(control.subviews.first { $0.pasteConfiguration != nil })
        let link = try XCTUnwrap(URL(string: "https://example.com/copied?value=123"))
        receiver.paste(itemProviders: [NSItemProvider(object: link as NSURL)])
        try await waitFor { ClipboardStore(url: url).clips.first?.text == link.absoluteString }
        XCTAssertNil(ClipboardStore(url: url).clips.first?.attachment)
    }
    func testMultipleProvidersPreferReadableArticleOverItsWebArchive() async throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("clipboard.json")
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let capture = ClipboardCapture(defaults: defaults, makeStore: { ClipboardStore(url: url) }, changeCount: { 0 }, hasStrings: { false }, readText: { nil })
        let article = NSItemProvider(object: "完整正文" as NSString)
        article.registerDataRepresentation(forTypeIdentifier: "com.apple.webarchive", visibility: .all) { completion in completion(Data([1,2,3]), nil); return nil }
        ClipboardItemLoader.load([article, NSItemProvider(object: "第二项" as NSString)], revision: nil, into: capture)
        try await waitFor { ClipboardStore(url: url).clips.count == 2 }
        let values = ClipboardStore(url: url).clips
        XCTAssertEqual(Set(values.map(\.text)), ["完整正文", "第二项"]); XCTAssertTrue(values.allSatisfy { $0.attachment == nil })
    }
    func testSystemPastePreservesEncodedJPEGWithoutPNGExpansion() async throws {
        let suite = "clear.clipboard.image-provider." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("clipboard.json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.7))
        let capture = ClipboardCapture(defaults: defaults, makeStore: { ClipboardStore(url: url) },
            changeCount: { 0 }, hasStrings: { false }, readText: { XCTFail("System paste must use the supplied provider"); return nil })
        let control = ClipboardPasteButton(capture: capture)
        let receiver = try XCTUnwrap(control.subviews.first { $0.pasteConfiguration != nil })
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: "public.jpeg", visibility: .all) { completion in
            completion(data, nil); return nil
        }
        receiver.paste(itemProviders: [provider])
        try await waitFor { ClipboardStore(url: url).clips.first?.attachment != nil }
        let store = ClipboardStore(url: url), clip = try XCTUnwrap(store.clips.first)
        XCTAssertEqual(clip.attachment?.typeIdentifier, "public.jpeg")
        XCTAssertEqual(store.attachmentData(for: clip), data, "Preserve the original encoded payload and its size")
    }
}
