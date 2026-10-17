import XCTest
@testable import ClearCore

final class StateTests: XCTestCase {
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
        XCTAssertEqual(bottom.last?.action, .enter)
    }
    func testCompositionConsumptionHonorsApostrophes() {
        var buffer = Composition(); buffer.append("ni'hao'ma")
        buffer.consume(5); XCTAssertEqual(buffer.raw, "ma")
        buffer.deleteBackward(); XCTAssertEqual(buffer.raw, "m")
        buffer.clear(); XCTAssertTrue(buffer.isEmpty)
    }
    func testCompositionBoundIsEnforced() {
        var buffer = Composition(); XCTAssertTrue(buffer.append(String(repeating: "a", count: 64)))
        XCTAssertFalse(buffer.append("a")); XCTAssertEqual(buffer.normalized.count, 64)
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
        var settings = KeyboardSettings(); settings.keyHeight = 100; settings.glassOpacity = -2
        settings.toolbar = [.clipboard, .clipboard]; settings.fuzzyPairs = ["unknown", "z/zh"]
        settings.sanitize()
        XCTAssertEqual(settings.keyHeight, 58); XCTAssertEqual(settings.glassOpacity, 0.15)
        XCTAssertEqual(settings.toolbar, [.language, .clipboard]); XCTAssertEqual(settings.fuzzyPairs, ["z/zh"])
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
}
