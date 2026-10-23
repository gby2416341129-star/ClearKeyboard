import XCTest
import CoreGraphics
@testable import ClearCore

final class StateTests: XCTestCase {
    func testCandidateTextSizeRoundTripsAndOldSettingsUseStandard() throws {
        let old = try JSONEncoder().encode(KeyboardSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        object.removeValue(forKey: "candidateTextSize")
        let decoded = try JSONDecoder().decode(KeyboardSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.resolvedCandidateTextSize, .standard)
        for size in CandidateTextSize.allCases {
            var settings = decoded; settings.candidateTextSize = size
            let restored = try JSONDecoder().decode(KeyboardSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(restored.resolvedCandidateTextSize, size)
        }
        XCTAssertEqual(CandidateTextSize.allCases.map(\.points), [16, 19, 22, 25])
    }
    func testZeroSizeKeyGeometryIsFinite() {
        for size in [CGSize.zero, CGSize(width: 1, height: 1), CGSize(width: 5, height: 7), CGSize(width: 39, height: 56)] {
            let result = KeyboardGeometry.keyPlate(in: CGRect(origin: .zero, size: size))
            XCTAssertFalse(result.isNull); XCTAssertTrue(result.origin.x.isFinite && result.origin.y.isFinite)
            XCTAssertGreaterThanOrEqual(result.width, 0); XCTAssertGreaterThanOrEqual(result.height, 0)
        }
    }
    func testOldSettingsRemainReadableAndOneHandWidthIsBounded() throws {
        let encoded = try JSONEncoder().encode(KeyboardSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "oneHandWidth")
        object.removeValue(forKey: "automaticClipboard")
        let decoded = try JSONDecoder().decode(KeyboardSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.oneHandFraction, 0.78)
        XCTAssertTrue(decoded.capturesClipboard)
        var settings = decoded; settings.oneHandWidth = 10; settings.sanitize(); XCTAssertEqual(settings.oneHandFraction, 0.88)
    }
    func testSystemLetterRows() {
        let rows = KeyboardLayout.rows(page: .letters)
        XCTAssertEqual(rows[0].keys.map(\.label).joined(), "qwertyuiop")
        XCTAssertEqual(rows[1].keys.map(\.label).joined(), "asdfghjkl")
        XCTAssertEqual(rows[1].insetUnits, 0.5)
        XCTAssertEqual(rows[2].keys.first?.action, .shift)
        XCTAssertEqual(rows[2].keys.last?.action, .delete)
    }
    func testSystemNumberAndSymbolRows() {
        XCTAssertEqual(KeyboardLayout.rows(page: .numbers)[0].keys.map(\.label).joined(), "1234567890")
        XCTAssertEqual(KeyboardLayout.rows(page: .symbols)[0].keys.map(\.label), ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="])
    }
    func testAllRowsOccupyTenUnits() {
        for page in [KeyboardPage.letters, .numbers, .symbols] {
            for globe in [false, true] {
                for row in KeyboardLayout.rows(page: page, globe: globe) {
                    XCTAssertEqual(row.keys.reduce(0) { $0 + $1.units } + row.insetUnits * 2, 10, accuracy: 0.0001)
                }
            }
        }
    }
    func testGlobeAndReturnRemainAvailable() {
        let bottom = KeyboardLayout.rows(page: .letters).last!.keys
        XCTAssertTrue(bottom.contains { $0.action == .globe })
        XCTAssertTrue(bottom.contains { $0.action == .language })
        XCTAssertEqual(bottom.last?.action, .enter)
    }
    func testCompositionConsumptionHonorsApostrophes() {
        var buffer = Composition(); buffer.append("ni'hao'ma")
        buffer.consume(5); XCTAssertEqual(buffer.raw, "ma")
        buffer.deleteBackward(); XCTAssertEqual(buffer.raw, "m")
        buffer.clear(); XCTAssertTrue(buffer.isEmpty)
    }
    func testDecoderBoundDoesNotDiscardTheDraft() {
        var buffer = Composition(); XCTAssertTrue(buffer.append(String(repeating: "a", count: Composition.maximumQueryLength)))
        XCTAssertTrue(buffer.append("a")); XCTAssertEqual(buffer.normalized.count, Composition.maximumQueryLength + 1)
        let prefix = Composition.queryPrefix(buffer.raw, normalized: buffer.normalized)
        XCTAssertTrue(buffer.raw.hasPrefix(prefix)); XCTAssertLessThanOrEqual(prefix.count, Composition.maximumQueryLength)
    }
    func testNormalizationAndBoundedFuzzyVariants() {
        XCTAssertEqual(FuzzyPinyin.normalize("LÜ'e 123"), "lve")
        XCTAssertLessThanOrEqual(FuzzyPinyin.variants("zhangshengning", enabled: Set(FuzzyPinyin.availablePairs)).count, 12)
    }
    func testEnglishReplacementWordAndCase() {
        XCTAssertEqual(EnglishContext.word(in: "hello, wor"), "wor")
        XCTAssertEqual(EnglishContext.word(in: "don't"), "don't")
        XCTAssertEqual(EnglishContext.word(in: "hello 👨‍👩‍👧‍👦"), "")
        XCTAssertEqual(EnglishContext.applyingCase("hello", like: "HEL"), "HELLO")
        XCTAssertEqual(EnglishContext.applyingCase("hello", like: "Hel"), "Hello")
    }
    func testSettingsSanitize() {
        var settings = KeyboardSettings(); settings.keyHeight = 100; settings.keyGlassStrength = -2
        settings.toolbar = [.clipboard, .clipboard]; settings.fuzzyPairs = ["unknown", "z/zh"]
        settings.sanitize()
        XCTAssertEqual(settings.keyHeight, 58); XCTAssertEqual(settings.keyGlassStrength, 0)
        XCTAssertEqual(settings.toolbar, [.language, .clipboard]); XCTAssertEqual(settings.fuzzyPairs, ["z/zh"])
    }
    func testToolbarKeepsEverySelectedShortcutAndOnlyRemovesDuplicates() throws {
        var settings = KeyboardSettings()
        settings.toolbar = [.appearance, .clipboard, .emoji, .oneHand, .appearance, .language, .clipboard]
        settings.sanitize()
        let expected: [ToolbarTool] = [.language, .appearance, .clipboard, .emoji, .oneHand]
        XCTAssertEqual(settings.toolbar, expected, "A full toolbar must not silently discard its fourth shortcut")
        settings.sanitize(); XCTAssertEqual(settings.toolbar, expected)
        let suite = "clear.toolbar.all." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults); store.save(settings)
        XCTAssertEqual(store.load().toolbar, expected)
    }
    func testCorruptSettingsFallBack() {
        let suite = "clear.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid".utf8), forKey: SettingsStore.key)
        XCTAssertEqual(SettingsStore(defaults: defaults).load(), KeyboardSettings())
    }
    func testAnyRGBColorAndShorthand() {
        XCTAssertEqual(RGBColor(hex: "#f3a")?.hex, "#FF33AA")
        XCTAssertEqual(RGBColor(hex: "#000000")?.hex, "#000000")
        XCTAssertEqual(RGBColor(hex: " FFFFFF ")?.hex, "#FFFFFF")
        XCTAssertEqual(RGBColor(red: 0.1, green: 0.2, blue: 0.3).hex, "#1A334D")
    }
    func testInvalidHexDoesNotBecomeAColor() {
        for value in ["", "#12345", "#GGFF00", "#00000000"] { XCTAssertNil(RGBColor(hex: value)) }
        var settings = KeyboardSettings(); settings.customAccentHex = "invalid"; settings.sanitize()
        XCTAssertNil(settings.customAccentHex)
    }
    func testClipboardLifetimeSettings() {
        var settings = KeyboardSettings(); settings.clipboardLifetimeHours = 168; settings.sanitize()
        XCTAssertEqual(settings.clipboardLifetimeHours, 168)
        settings.clipboardLifetimeHours = 0; settings.automaticClipboard = false; settings.sanitize()
        XCTAssertEqual(settings.clipboardLifetimeHours, 0); XCTAssertFalse(settings.capturesClipboard)
        settings.clipboardLifetimeHours = .nan; settings.sanitize()
        XCTAssertEqual(settings.clipboardLifetimeHours, 168)
    }
    func testFourRowsFitCompressedHostHeight() {
        for height: CGFloat in [0, 48, 180, 216, 240, 280, 500] {
            let row = KeyboardGeometry.rowHeight(availableHeight: height)
            XCTAssertGreaterThanOrEqual(row, 0)
            XCTAssertLessThanOrEqual(48 + row * 4, max(48, height))
            XCTAssertLessThanOrEqual(row, 56)
        }
    }
}
