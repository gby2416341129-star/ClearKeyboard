import XCTest
import UIKit

@MainActor final class AuditRepair66Tests: XCTestCase {
    func testIndependentSettingsChangesMergeInEitherOrder() throws {
        var base = KeyboardSettings(), a = base, b = base
        a.keyColorHex = "#112233"; b.vibrationIntensity = 0.87
        let first = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: base, includeInputPreferences: true), updatedAt: Date(timeIntervalSince1970: 1))
        let color = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: a, includeInputPreferences: true), updatedAt: Date(timeIntervalSince1970: 2), changedFields: ["keyColorHex"])
        let haptic = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: b, includeInputPreferences: true), updatedAt: Date(timeIntervalSince1970: 3), changedFields: ["vibrationIntensity"])
        for records in [[first, color, haptic], [haptic, first, color]] {
            let merged = try XCTUnwrap(AppearanceEnvelope.reconciling(records))
            XCTAssertEqual(merged.snapshot.keyColorHex, "#112233"); XCTAssertEqual(merged.snapshot.vibrationIntensity, 0.87)
        }
        a.keyColorHex = nil
        let reset = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: a, includeInputPreferences: true), updatedAt: Date(timeIntervalSince1970: 4), changedFields: ["keyColorHex"])
        let merged = try XCTUnwrap(AppearanceEnvelope.reconciling([first, color, haptic, reset]))
        XCTAssertNil(merged.snapshot.keyColorHex); XCTAssertEqual(merged.snapshot.vibrationIntensity, 0.87)
    }
    func testInvalidSettingsFieldIsRejected() {
        let bad = AppearanceEnvelope(snapshot: AppearanceSnapshot(settings: KeyboardSettings()), changedFields: ["unknown"])
        if case .success = AppearanceSyncClient.encode(bad) { XCTFail("Unknown field must not be persisted") }
    }
    func testLongArticleShapingCancelsAnObsoleteResult() {
        let preview = ClipboardInlinePreview(frame: CGRect(x: 0, y: 0, width: 220, height: 40))
        preview.show(String(repeating: "very long article 中文😀 ", count: 20000)); preview.show("新内容")
        let until = Date().addingTimeInterval(1)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        preview.layoutIfNeeded(); XCTAssertEqual(preview.text, "新内容"); XCTAssertTrue(preview.isReady)
        XCTAssertLessThanOrEqual(preview.contentSize.width, 220)
    }
    func testCapturedRevisionStaysSuppressedAcrossReactivation() throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = ClipboardObservation(defaults: defaults, owner: .keyboard)
        first.didCapture(changeCount: 72)
        let second = ClipboardObservation(defaults: defaults, owner: .keyboard)
        XCTAssertFalse(second.shouldRead(changeCount: 72, hasContent: true))
        XCTAssertTrue(second.shouldRead(changeCount: 73, hasContent: true))
    }
}