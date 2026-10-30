import XCTest
@testable import ClearCore

final class PersonalLexiconTests: XCTestCase {



    func testLearningUpgradeRunsOnceAndCanBeDisabled() {
        var settings = KeyboardSettings(); settings.learnChoices = false; settings.selectionLearningVersion = nil
        settings.sanitize(); XCTAssertTrue(settings.learnChoices)
        settings.learnChoices = false; settings.sanitize(); XCTAssertFalse(settings.learnChoices)
        var fresh = KeyboardSettings(); fresh.learnChoices = false; fresh.sanitize(); XCTAssertFalse(fresh.learnChoices)
    }

    func testSelectionPreservesSpacesNumbersAndEmojiGraphemes() {
        let text = "朱鸿毅 编程 16 次课 👨‍👩‍👧‍👦 2800"
        let tokens = ClipboardSelection.tokens(text)
        XCTAssertEqual(tokens.map(\.text), ["朱", "鸿", "毅", "编", "程", "16", "次", "课", "👨‍👩‍👧‍👦", "2800"])
        XCTAssertEqual(ClipboardSelection.text(text, tokens: tokens, from: 5, through: 9), "16 次课 👨‍👩‍👧‍👦 2800")
        XCTAssertEqual(ClipboardSelection.text(text, tokens: tokens, from: 9, through: 5), "16 次课 👨‍👩‍👧‍👦 2800")
        XCTAssertEqual(ClipboardSelection.text(text, tokens: tokens, from: -1, through: 3), "")
        XCTAssertEqual(ClipboardSelection.tokens("100.106.124.45").map(\.text), ["100.106.124.45"])
    }
}
