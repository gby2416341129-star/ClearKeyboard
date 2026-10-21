import XCTest
import SwiftUI
import UIKit
@testable import ClearKeyboard

@MainActor final class UnifiedRepairTests: XCTestCase {
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "The latest result did not arrive")
    }
    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    private func controller(language: InputLanguage = .chinese) -> TypingLabController {
        var settings = KeyboardSettings(); settings.language = language
        settings.automaticClipboard = false; settings.autoCapitalization = false
        let value = TypingLabController(settings: settings); value.loadViewIfNeeded()
        value.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600); value.view.layoutIfNeeded()
        return value
    }
    func testIndependentAppearanceSettingsRoundTripAndMigrateWithoutResettingOldValues() throws {
        var old = KeyboardSettings(); old.accent = .jade; old.glassOpacity = 0.77; old.keyHeight = 56
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        for field in ["backgroundGlassStrength", "keyGlassStrength", "backgroundColorHex", "keyColorHex", "candidateColorHex"] { json.removeValue(forKey: field) }
        var restored = try JSONDecoder().decode(KeyboardSettings.self, from: JSONSerialization.data(withJSONObject: json))
        restored.sanitize()
        XCTAssertEqual(restored.accent, .jade); XCTAssertEqual(restored.keyHeight, 56)
        XCTAssertEqual(restored.resolvedBackgroundGlassStrength, 0.77)
        restored.backgroundGlassStrength = 0.12; restored.keyGlassStrength = 0.94
        restored.backgroundColorHex = "#123"; restored.keyColorHex = "#ABCDEF"; restored.candidateColorHex = "#B87DF0"
        restored.sanitize()
        let result = try JSONDecoder().decode(KeyboardSettings.self, from: JSONEncoder().encode(restored))
        XCTAssertEqual(result.backgroundColorHex, "#112233"); XCTAssertEqual(result.keyColorHex, "#ABCDEF")
        XCTAssertEqual(result.candidateColorHex, "#B87DF0")
        XCTAssertEqual(result.resolvedBackgroundGlassStrength, 0.12); XCTAssertEqual(result.resolvedKeyGlassStrength, 0.94)
        XCTAssertEqual(result, restored)
        restored.backgroundGlassStrength = .infinity; restored.keyGlassStrength = -1; restored.sanitize()
        XCTAssertNil(restored.backgroundGlassStrength); XCTAssertEqual(restored.resolvedKeyGlassStrength, 0)
        print("APPEARANCE_MIGRATION independentControls=5 legacySettingsPreserved=true finiteRanges=true")
    }
    func testPunctuationLegendsMatchInsertedCharactersInBothLanguages() {
        for language in [InputLanguage.chinese, .english] {
            for page in [KeyboardPage.numbers, .symbols] {
                let keys = KeyboardLayout.rows(page: page, language: language).flatMap(\.keys)
                for key in keys { if case .text(let text) = key.action { XCTAssertEqual(key.label, text) } }
                for text in language == .chinese ? ["。", "，", "？", "！", "、"] : [".", ",", "?", "!", "'"] {
                    XCTAssertTrue(keys.contains { $0.label == text })
                }
            }
        }
    }
    func testOneConfirmationImmediatelyPromotesLearnedInitialsButNotUnrelatedWords() throws {
        for (text, reading) in [("苟博渊", "gou bo yuan"), ("老子去你妈的", "lao zi qu ni ma de"),
                                ("今天在干什么", "jin tian zai gan shen me"), ("明天早上见", "ming tian zao shang jian")] {
            let raw = reading.replacingOccurrences(of: " ", with: "")
            let initials = String(reading.split(separator: " ").compactMap(\.first))
            var memory = PersonalLexicon(); memory.record(Candidate(text: text, reading: reading, consumed: raw.count), for: raw)
            let restored = try JSONDecoder().decode(PersonalLexicon.self, from: JSONEncoder().encode(memory))
            let base = [Candidate(text: "原首选", consumed: initials.count)]
            XCTAssertEqual(PersonalLexicon.merging(restored.candidates(for: initials), into: base, limit: 8).first?.text, text)
            XCTAssertTrue(restored.candidates(for: initials + "x").isEmpty)
            XCTAssertEqual(restored.candidates(for: raw).first?.score, 1, "Full spellings retain gradual learning")
        }
        var memory = PersonalLexicon()
        let previous = Candidate(text: "高博雅", reading: "gao bo ya", consumed: 8)
        for _ in 0..<5 { memory.record(previous, for: "gaoboya", now: Date(timeIntervalSince1970: 1)) }
        let name = Candidate(text: "苟博渊", reading: "gou bo yuan", consumed: 9)
        memory.record(name, for: "gouboyuan", now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(memory.candidates(for: "gby").first?.text, name.text, "A newly confirmed initials mapping must not be buried by an older frequent phrase")
        memory.record(Candidate(text: name.text, reading: name.reading, consumed: 3), for: "gby", now: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(memory.candidates(for: "gby").first?.score, 4, "Selecting the learned alias must not downgrade its next recall")
    }
    func testFirstHighlightFitsTheKeyboardCornerAtEveryCandidateSize() throws {
        let shell = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 390, height: 276), cornerRadius: 28)
        for size in CandidateTextSize.allCases {
            let button = CandidateButton(frame: CGRect(x: 12, y: 0, width: 150, height: 44))
            button.configure(Candidate(text: "车", consumed: 3), first: true, accent: .systemBlue, font: .systemFont(ofSize: CGFloat(size.points)))
            button.layoutIfNeeded()
            let plate = try XCTUnwrap(button.subviews.first).frame.offsetBy(dx: 12, dy: 0)
            XCTAssertTrue(shell.contains(CGPoint(x: plate.minX, y: plate.minY)), size.title)
            XCTAssertTrue(shell.contains(CGPoint(x: plate.minX, y: plate.maxY)), size.title)
        }
    }
    func testEnglishSpaceCommitsTheVisibleCompletionAndPredictionWithRealTextStorage() async throws {
        let value = controller(language: .english), model = try XCTUnwrap(value.model)
        views(value.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "clipboard.recent.close" }?.sendActions(for: .touchUpInside)
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for letter in "hell" { model.handle(.text(String(letter))) }
        try await waitFor { model.candidatesAreCurrent && !model.candidates.isEmpty }
        let completion = try XCTUnwrap(model.candidates.first)
        XCTAssertTrue(completion.text.lowercased().hasPrefix("hell"))
        model.handle(.space)
        XCTAssertEqual(value.textView.text, completion.text + " ")
        try await waitFor { model.candidatesAreCurrent }
        if let prediction = model.candidates.first {
            let before = value.textView.text ?? ""
            model.handle(.space)
            XCTAssertEqual(value.textView.text, before + prediction.text + " ")
        }
        model.settings.predictions = false; model.refreshCandidates()
        try await waitFor { model.candidatesAreCurrent && model.candidates.isEmpty }
        let before = value.textView.text ?? ""; model.handle(.space)
        XCTAssertEqual(value.textView.text, before + " ")
        print("ENGLISH_SPACE_UIKIT prefixReplacedOnce=true visibleChoiceCommitted=true noCandidateNormalSpace=true")
    }
    func testCharacterModeSelectsAWholeNameAndNextInitialsAreImmediateFirstChoice() async throws {
        let value = controller(), model = try XCTUnwrap(value.model)
        model.settings.predictions = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for letter in "gouboyuan" { model.handle(.text(String(letter))) }
        let toggle = try XCTUnwrap(views(value.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "candidate.characterMode" })
        toggle.sendActions(for: .touchUpInside)
        XCTAssertTrue(model.characterSelectionMode)
        for (text, consumed) in [("苟", 3), ("博", 2), ("渊", 4)] {
            try await waitFor { model.candidatesAreCurrent && model.candidates.contains { $0.text == text } }
            XCTAssertTrue(model.candidates.allSatisfy { $0.text.count == 1 }, "Character browsing must not be buried below phrases")
            let candidate = try XCTUnwrap(model.candidates.first { $0.text == text })
            XCTAssertEqual(candidate.consumed, consumed)
            model.chooseDisplayed(candidate, context: model.candidateContext)
        }
        XCTAssertEqual(value.textView.text, "苟博渊"); XCTAssertTrue(model.composition.isEmpty)
        for letter in "gby" { model.handle(.text(String(letter))) }
        XCTAssertTrue(model.candidatesAreCurrent)
        XCTAssertEqual(model.candidates.first?.text, "苟博渊", "Learned initials must be available during the key, before worker completion")
        model.handle(.space)
        XCTAssertEqual(value.textView.text, "苟博渊苟博渊")
        print("CHARACTER_PICKER_UIKIT characters=3 unrelatedPhraseRows=0 initialsImmediateFirst=true duplicatedPinyin=0")
    }
    func testCharacterBrowsingKeepsAlternativeSyllableBoundariesAndExplicitSeparators() throws {
        let engine = try InputEngine.bundled()
        let ambiguous = engine.characterCandidates("xian")
        XCTAssertTrue(ambiguous.contains { $0.text == "先" && $0.consumed == 4 })
        XCTAssertTrue(ambiguous.contains { $0.text == "西" && $0.consumed == 2 })
        let separated = engine.characterCandidates("xi'an")
        XCTAssertTrue(separated.contains { $0.text == "西" && $0.consumed == 2 })
        XCTAssertTrue(separated.allSatisfy { $0.consumed <= 2 })
        XCTAssertTrue(engine.characterCandidates("xian", cancelled: { true }).isEmpty)
    }
    func testSwitchingFromBrowsedPhrasesToCharactersReplacesTheRowAndResetsItsOffset() async throws {
        let ribbon = CandidateScrollView()
        ribbon.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        let words = KeyboardModel.CandidateContext(raw: "gouboyuan", before: "gouboyuan", after: "",
                                                   document: "field", language: .chinese)
        let phrases = (0..<24).map { Candidate(text: "旧词组\($0)", consumed: 9) }
        ribbon.update(phrases, context: words, arithmetic: false, accent: .systemBlue)
        try await waitFor { ribbon.accessibilityValue == "offset:0;count:24" }
        ribbon.layoutIfNeeded(); ribbon.contentOffset.x = 180
        ribbon.scrollViewWillBeginDragging(ribbon)
        var characters = words; characters.characters = true
        XCTAssertNotEqual(words, characters)
        ribbon.inputChanged()
        ribbon.update([Candidate(text: "苟", reading: "gou", consumed: 3)], context: characters,
                      arithmetic: false, accent: .systemBlue)
        try await waitFor { ribbon.accessibilityValue == "offset:0;count:1" }
        ribbon.layoutIfNeeded()
        let shown = views(ribbon).compactMap { $0 as? UIButton }.filter { !$0.isHidden }
        XCTAssertEqual(shown.map(\.accessibilityIdentifier), ["candidate.苟"])
        var selectedContext: KeyboardModel.CandidateContext?
        ribbon.onSelect = { _, context, _ in selectedContext = context }
        shown.first?.sendActions(for: .touchUpInside)
        XCTAssertEqual(selectedContext, characters)
    }
    func testUnchangedInkKeepsItsFadeThroughALayoutRefresh() throws {
        let button = CandidateButton(frame: CGRect(x: 0, y: 0, width: 200, height: 44))
        let font = UIFont.systemFont(ofSize: 19), word = Candidate(text: "新候选", consumed: 4)
        button.configure(Candidate(text: "旧候选", consumed: 4), first: true, accent: .systemBlue, font: font)
        button.configure(word, first: true, accent: .systemBlue, font: font, animate: true)
        let label = try XCTUnwrap(views(button).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "candidate.currentInk" })
        let initial = try XCTUnwrap(label.layer.animation(forKey: "candidateText") as? CABasicAnimation)
        button.setNeedsLayout(); button.layoutIfNeeded()
        button.configure(word, first: true, accent: .systemBlue, font: font)
        let after = try XCTUnwrap(label.layer.animation(forKey: "candidateText") as? CABasicAnimation)
        XCTAssertEqual(initial.beginTime, after.beginTime); XCTAssertEqual(label.text, word.text)
        XCTAssertEqual(after.duration, 0.14, accuracy: 0.0001)
    }
    func testPreviewUsesRealKeyViewsAndAppliesIndependentColorsWithoutAnEngine() throws {
        let preview = KeyboardAppearancePreview(frame: CGRect(x: 0, y: 0, width: 350, height: 250))
        var settings = KeyboardSettings(); settings.backgroundGlassStrength = 0.1; settings.keyGlassStrength = 0.9
        settings.backgroundColorHex = "#B3C3EE"; settings.keyColorHex = "#303955"; settings.candidateColorHex = "#C185FF"
        preview.apply(settings); preview.layoutIfNeeded()
        let keys = views(preview).compactMap { $0 as? KeyButton }
        XCTAssertGreaterThan(keys.count, 30)
        XCTAssertEqual(keys.first?.transform, .identity)
        XCTAssertTrue(preview.accessibilityValue?.contains("background:0.1;keys:0.9") == true)
        let color = try XCTUnwrap(KeyboardSettings.color(hex: settings.candidateColorHex))
        let candidateInk = views(preview).compactMap { $0 as? UILabel }.filter { $0.accessibilityIdentifier == "candidate.currentInk" }
        XCTAssertEqual(candidateInk.count, 2)
        XCTAssertTrue(candidateInk.allSatisfy { $0.textColor.isEqual(color) })
        settings.candidateTextSize = .extraLarge; preview.apply(settings); preview.layoutIfNeeded()
        XCTAssertTrue(candidateInk.allSatisfy { $0.font.pointSize == 25 })
    }
    func testRecentClipboardCanPasteAndOpenHistoryWithoutReplacingTypedPinyin() async throws {
        let value = controller(), model = try XCTUnwrap(value.model)
        let url = SharedStorage.clipboardURL(allowShared: model.document?.fullAccess == true)
        let original = try? Data(contentsOf: url)
        defer {
            model.suspend()
            if let original { try? original.write(to: url, options: .atomic) }
            else { try? FileManager.default.removeItem(at: url) }
        }
        let text = "剪贴板测试内容 \(UUID().uuidString.prefix(6))"
        ClipboardStore(url: url).add(text)
        model.clipboardCapture.onCapture?()
        value.view.setNeedsLayout(); value.view.layoutIfNeeded()
        let paste = try XCTUnwrap(views(value.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "clipboard.recent.paste" })
        XCTAssertEqual(paste.accessibilityLabel, "粘贴：" + text)
        XCTAssertFalse(paste.superview?.isHidden ?? true)
        paste.sendActions(for: .touchUpInside)
        XCTAssertEqual(value.textView.text, text)
        XCTAssertTrue(paste.superview?.isHidden ?? false)
        model.clipboardCapture.onCapture?()
        for letter in "nihao" { model.handle(.text(String(letter))) }
        XCTAssertTrue(paste.superview?.isHidden ?? false, "A clipboard tip must not cover live pinyin candidates")
        XCTAssertEqual(model.composition.raw, "nihao")
        model.clearInput(); model.clipboardCapture.onCapture?()
        let history = try XCTUnwrap(views(value.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "clipboard.recent.history" })
        history.sendActions(for: .touchUpInside)
        value.view.setNeedsLayout(); value.view.layoutIfNeeded()
        let panel = try XCTUnwrap(views(value.view).compactMap { $0 as? ClipboardPanel }.first)
        panel.setNeedsLayout(); panel.layoutIfNeeded()
        let table = try XCTUnwrap(views(panel).compactMap { $0 as? UITableView }.first)
        table.layoutIfNeeded()
        XCTAssertGreaterThan(table.numberOfRows(inSection: 0), 0)
        XCTAssertTrue(views(panel).compactMap { $0 as? UIButton }.contains { button in
            button.menu?.children.contains { $0.title == "复制" } == true
        }, "History rows need a copy action as well as tap-to-paste")
        let before = value.textView.text ?? ""
        panel.tableView(table, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(value.textView.text, before + text)
        print("CLIPBOARD_RECENT_UIKIT textPaste=true history=true copyMenu=true compositionProtected=true")
    }
}
