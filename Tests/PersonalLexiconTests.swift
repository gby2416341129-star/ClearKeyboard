import XCTest
@testable import ClearCore

final class PersonalLexiconTests: XCTestCase {
    func testRecentNeighbourCorrectionsStayBoundedAndDoNotReplaceExactChoices() {
        let now = Date(timeIntervalSince1970: 1_000)
        var memory = PersonalLexicon()
        memory.record(Candidate(text: "我吃了的", reading: "wo chi le de", consumed: 9), for: "wochielde", now: now)
        XCTAssertEqual(memory.recentCorrections(for: "wochiekdr", now: now).first?.text, "我吃了的")
        XCTAssertTrue(memory.candidates(for: "wochiekdr").isEmpty)
        XCTAssertTrue(memory.recentCorrections(for: "wochielde", now: now).isEmpty)
        XCTAssertTrue(memory.recentCorrections(for: "wochiekdr", now: now.addingTimeInterval(121)).isEmpty)
        XCTAssertTrue(memory.recentCorrections(for: "nochiekdr", now: now).isEmpty)
        XCTAssertTrue(memory.recentCorrections(for: "wochiezdr", now: now).isEmpty)
    }
    func testSingleExplicitChoiceIsAvailableWithoutPinningAndRepeatedChoicesPromoteIt() throws {
        let engine = try InputEngine.bundled()
        let before = engine.candidates("ganghuam")
        let film = try XCTUnwrap(before.first { $0.text == "钢化膜" })
        var memory = PersonalLexicon(); memory.record(film, for: "ganghuam")
        let restored = try JSONDecoder().decode(PersonalLexicon.self, from: JSONEncoder().encode(memory))
        let result = engine.candidates("ganghuam", preferred: restored.candidates(for: "ganghuam"))
        XCTAssertTrue(result.prefix(4).contains { $0.text == "钢化膜" })
        XCTAssertEqual(result.filter { $0.text == "钢化膜" }.count, 1)
        XCTAssertTrue(restored.candidates(for: "ganghua").isEmpty)
        XCTAssertEqual(engine.candidates("ganghua", preferred: restored.candidates(for: "ganghua")), engine.candidates("ganghua"))
        let base = [Candidate(text: "默认词", consumed: 8), Candidate(text: "另一词", consumed: 8), Candidate(text: "第三词", consumed: 8)]
        XCTAssertEqual(PersonalLexicon.merging(restored.candidates(for: "ganghuam"), into: base, limit: 8).first?.text, "默认词")
        memory.record(film, for: "ganghuam"); memory.record(film, for: "ganghuam")
        XCTAssertEqual(PersonalLexicon.merging(memory.candidates(for: "ganghuam"), into: base, limit: 8).first?.text, "钢化膜")
    }
    func testConfirmedChoicesKeepActualConsumptionAndUseCounts() throws {
        var memory = PersonalLexicon()
        let first = Candidate(text: "钢化膜", reading: "gang hua mo", consumed: 8)
        let second = Candidate(text: "尴尬画面", consumed: 8)
        memory.record(first, for: "ganghuam"); memory.record(second, for: "ganghuam")
        XCTAssertEqual(memory.candidates(for: "GANGHUAM").first?.text, second.text)
        memory.record(first, for: "ganghuam")
        XCTAssertEqual(memory.candidates(for: "ganghuam").first, Candidate(text: first.text, reading: first.reading, consumed: 8, score: 2))
        XCTAssertTrue(memory.candidates(for: "ganghuamo").isEmpty)
        memory.record(Candidate(text: "你吃饭了", consumed: 9), for: "nichifanlema")
        XCTAssertEqual(memory.candidates(for: "nichifanlema").first?.consumed, 9)
    }
    func testLearningUpgradeRunsOnceAndCanBeDisabled() {
        var settings = KeyboardSettings(); settings.learnChoices = false; settings.selectionLearningVersion = nil
        settings.sanitize(); XCTAssertTrue(settings.learnChoices)
        settings.learnChoices = false; settings.sanitize(); XCTAssertFalse(settings.learnChoices)
        var fresh = KeyboardSettings(); fresh.learnChoices = false; fresh.sanitize(); XCTAssertFalse(fresh.learnChoices)
    }
    func testPreviewAndExpandedQueriesHaveTheSameFirstCandidate() throws {
        let engine = try InputEngine.bundled()
        for input in ["nichifankm", "nichifnalemeilaopo", "wodeiphone", "ganghuam"] {
            let preview = engine.candidates(input, limit: 6)
            let expanded = engine.candidates(input)
            XCTAssertEqual(preview.first?.text, expanded.first?.text, input)
            XCTAssertEqual(preview.first?.consumed, expanded.first?.consumed, input)
        }
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
