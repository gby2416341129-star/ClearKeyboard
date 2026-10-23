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
        var old = KeyboardSettings(); old.accent = .jade; old.keyHeight = 56
        old.language = .english; old.learnChoices = false; old.keyColorHex = "#ABCDEF"
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        // Existing installations may still have the retired settings on disk.
        json["backgroundColorHex"] = "#0057FF"; json["backgroundGlassStrength"] = 0.94; json["glassOpacity"] = 0.77
        var restored = try JSONDecoder().decode(KeyboardSettings.self, from: JSONSerialization.data(withJSONObject: json))
        restored.sanitize()
        XCTAssertEqual(restored, old, "Retired background settings must have no effect or reset input preferences")
        restored.keyGlassStrength = 0.94; restored.candidateColorHex = "#B87DF0"
        let encoded = try JSONEncoder().encode(restored)
        let result = try JSONDecoder().decode(KeyboardSettings.self, from: encoded)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["backgroundColorHex", "backgroundGlassStrength", "glassOpacity"] { XCTAssertNil(saved[key]) }
        XCTAssertEqual(result, restored); XCTAssertEqual(result.resolvedKeyGlassStrength, 0.94)
        restored.keyGlassStrength = -1; restored.sanitize(); XCTAssertEqual(restored.resolvedKeyGlassStrength, 0)
    }
    func testPunctuationLegendsMatchInsertedCharactersInBothLanguages() {
        for language in [InputLanguage.chinese, .english] {
            for page in [KeyboardPage.numbers, .symbols] {
                let keys = KeyboardLayout.rows(page: page, language: language).flatMap(\.keys)
                for key in keys { if case .text(let text) = key.action { XCTAssertEqual(key.label, text) } }
                for text in language == .chinese ? ["。", "，", "？", "！", "、"] : [".", ",", "?", "!", "'"] {
                    XCTAssertTrue(keys.contains { $0.label == text })
                }
                XCTAssertTrue(keys.contains { $0.label == "." && $0.action == .text(".") }, "Decimals must remain typeable in either language")
                if language == .chinese {
                    XCTAssertTrue(keys.contains { $0.label == (page == .numbers ? "“" : "”") })
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
    func testDecimalPointAndChineseFullStopRemainDistinctWhenTypingNumbers() throws {
        let value = controller(), model = try XCTUnwrap(value.model)
        defer { model.suspend() }
        model.handle(.page(.numbers))
        for text in ["3", ".", "5"] { model.handle(.text(text)) }
        XCTAssertEqual(value.textView.text, "3.5")
        XCTAssertEqual(model.page, .numbers, "A decimal point must keep the number keys available")
        model.handle(.text("。"))
        XCTAssertEqual(value.textView.text, "3.5。")
        XCTAssertEqual(model.page, .letters)
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
        for letter in "hel" { model.handle(.text(String(letter))) }
        try await waitFor { model.candidatesAreCurrent && !model.candidates.isEmpty }
        let completion = try XCTUnwrap(model.candidates.first)
        XCTAssertTrue(completion.text.lowercased().hasPrefix("hel"))
        XCTAssertGreaterThan(completion.text.count, 3, "An incomplete prefix must still complete on Space")
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
    func testEnglishSpacePreservesCompleteWordsAndTheirExactCapitalization() async throws {
        let value = controller(language: .english), model = try XCTUnwrap(value.model)
        defer { model.suspend() }
        model.settings.predictions = false
        try await waitFor { model.engineState == "离线就绪" }
        let words = ["what", "What", "WHAT", "who", "how", "there", "can", "do", "it", "you", "we", "hello", "a", "I", "can't"]
        for word in words {
            value.textView.text = ""; value.textView.selectedRange = NSRange(location: 0, length: 0)
            model.cursorChanged()
            for letter in word { model.handle(.text(String(letter))) }
            try await waitFor { model.candidatesAreCurrent && !model.candidates.isEmpty }
            XCTAssertEqual(model.candidates.first?.text, word, "Space must keep the valid word \(word)")
            model.handle(.space)
            XCTAssertEqual(value.textView.text, word + " ", "A contraction or longer word must require an explicit choice")
            XCTAssertEqual(value.textView.selectedRange, NSRange(location: word.utf16.count + 1, length: 0))
            XCTAssertNil(value.textView.markedTextRange)
        }
        // A quick Space before the latest worker reply must also leave the
        // literal intact; a late prefix completion may not rewrite the host.
        value.textView.text = ""; value.textView.selectedRange = NSRange(location: 0, length: 0)
        model.cursorChanged()
        for letter in "what" { model.handle(.text(String(letter))) }
        model.handle(.space)
        try await waitFor { model.candidatesAreCurrent }
        XCTAssertEqual(value.textView.text, "what ")
        print("ENGLISH_LITERAL_SPACE_UIKIT validWords=\(words.count) originalCasePreserved=true rapidSpacePreserved=true forcedExpansion=false")
    }
    func testEnglishContractionRemainsSelectableWithoutTakingOverSpace() async throws {
        let value = controller(language: .english), model = try XCTUnwrap(value.model)
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for (word, expected) in [("what", "what's "), ("What", "What's "), ("WHAT", "WHAT'S ")] {
            value.textView.text = ""; value.textView.selectedRange = NSRange(location: 0, length: 0)
            model.cursorChanged()
            for letter in word { model.handle(.text(String(letter))) }
            try await waitFor { model.candidatesAreCurrent && model.candidates.contains { $0.text.lowercased() == "what's" } }
            XCTAssertEqual(model.candidates.first?.text, word)
            let contraction = try XCTUnwrap(model.candidates.first { $0.text.lowercased() == "what's" })
            model.chooseDisplayed(contraction, context: model.candidateContext)
            XCTAssertEqual(value.textView.text, expected, "An explicit contraction tap replaces the word once and keeps its case")
            XCTAssertNil(value.textView.markedTextRange)
        }
        // Confirming an unchanged whole word must still refresh the next-word
        // predictions, rather than leaving the completed word in the strip.
        value.textView.text = ""; value.textView.selectedRange = NSRange(location: 0, length: 0)
        model.cursorChanged()
        for letter in "thank" { model.handle(.text(String(letter))) }
        try await waitFor { model.candidatesAreCurrent && model.candidates.first?.text == "thank" }
        model.handle(.space)
        try await waitFor { model.candidatesAreCurrent && model.candidates.first?.text == "you" }
        model.handle(.space)
        XCTAssertEqual(value.textView.text, "thank you ")
        print("ENGLISH_EXPLICIT_COMPLETION_UIKIT contractionCaseVariants=3 nextWordPredictionPreserved=true")
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
        XCTAssertGreaterThan(after.duration, 0); XCTAssertLessThanOrEqual(after.duration, 0.18)
    }
    func testPreviewUsesRealKeyViewsAndAppliesIndependentColorsWithoutAnEngine() throws {
        let preview = KeyboardAppearancePreview(frame: CGRect(x: 0, y: 0, width: 350, height: 250))
        var settings = KeyboardSettings(); settings.keyGlassStrength = 0.9
        settings.keyColorHex = "#303955"; settings.candidateColorHex = "#C185FF"
        preview.apply(settings); preview.layoutIfNeeded()
        let keys = views(preview).compactMap { $0 as? KeyButton }
        XCTAssertGreaterThan(keys.count, 30)
        XCTAssertEqual(keys.first?.transform, .identity)
        XCTAssertTrue(preview.accessibilityValue?.contains("keys:0.9") == true)
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
        let phrasesURL = url.deletingLastPathComponent().appendingPathComponent("common-phrases.json")
        let original = try? Data(contentsOf: url)
        let originalPhrases = try? Data(contentsOf: phrasesURL)
        defer {
            model.suspend()
            if let original { try? original.write(to: url, options: .atomic) }
            else { try? FileManager.default.removeItem(at: url) }
            if let originalPhrases { try? originalPhrases.write(to: phrasesURL, options: .atomic) }
            else { try? FileManager.default.removeItem(at: phrasesURL) }
        }
        let text = "剪贴板测试内容 \(UUID().uuidString.prefix(6))"
        let phrase = "稍后回复你 \(UUID().uuidString.prefix(6))"
        ClipboardStore(url: url).add(text)
        ClipboardStore(url: phrasesURL).add(phrase)
        model.clipboardCapture.onCapture?()
        value.view.setNeedsLayout(); value.view.layoutIfNeeded()
        XCTAssertFalse(views(value.view).contains { $0 is ClipboardPanel }, "A recent copy must not replace the alphabet with an automatically opened history panel")
        let paste = try XCTUnwrap(views(value.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "clipboard.recent.paste" })
        XCTAssertEqual(paste.accessibilityLabel, "粘贴：" + text)
        XCTAssertFalse(paste.superview?.isHidden ?? true)
        paste.sendActions(for: .touchUpInside)
        XCTAssertEqual(value.textView.text, text)
        XCTAssertTrue(paste.superview?.isHidden ?? false)
        model.clipboardCapture.onCapture?()
        model.handle(.page(.numbers)); model.handle(.text("3"))
        XCTAssertTrue(paste.superview?.isHidden ?? false, "Starting numeric input must release the header too")
        model.clearInput(); model.handle(.page(.letters)); model.clipboardCapture.onCapture?()
        for letter in "nihao" { model.handle(.text(String(letter))) }
        XCTAssertTrue(paste.superview?.isHidden ?? false, "A clipboard tip must not cover live pinyin candidates")
        XCTAssertEqual(model.composition.raw, "nihao")
        model.clearInput()
        XCTAssertTrue(paste.superview?.isHidden ?? false, "An old clipboard tip must not return after typing or clearing")
        model.clipboardCapture.onCapture?()
        let history = try XCTUnwrap(views(value.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "clipboard.recent.history" })
        history.sendActions(for: .touchUpInside)
        value.view.setNeedsLayout(); value.view.layoutIfNeeded()
        let panel = try XCTUnwrap(views(value.view).compactMap { $0 as? ClipboardPanel }.first)
        panel.setNeedsLayout(); panel.layoutIfNeeded()
        let tabs = try XCTUnwrap(views(panel).compactMap { $0 as? UISegmentedControl }.first)
        XCTAssertEqual(tabs.selectedSegmentIndex, 0, "Opening history must already select Clipboard without another tab tap")
        let table = try XCTUnwrap(views(panel).compactMap { $0 as? UITableView }.first)
        table.layoutIfNeeded()
        XCTAssertFalse(table.isHidden)
        XCTAssertGreaterThan(table.bounds.height, 0)
        XCTAssertGreaterThan(table.numberOfRows(inSection: 0), 0)
        let firstClip = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 0)))
        XCTAssertTrue(views(firstClip).compactMap { $0 as? UILabel }.contains { $0.text == text },
                      "Persisted clipboard content must be visible before sending a tab event")
        XCTAssertTrue(views(panel).compactMap { $0 as? UIButton }.contains { button in
            button.menu?.children.contains { $0.title == "复制" } == true
        }, "History rows need a copy action as well as tap-to-paste")
        let before = value.textView.text ?? ""
        tabs.selectedSegmentIndex = 1; tabs.sendActions(for: .valueChanged)
        panel.reloadFromDisk(); panel.layoutIfNeeded(); table.layoutIfNeeded()
        XCTAssertEqual(tabs.selectedSegmentIndex, 1, "A disk refresh must not interrupt an explicitly selected Common Phrases tab")
        let firstPhrase = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 0)))
        XCTAssertTrue(views(firstPhrase).compactMap { $0 as? UILabel }.contains { $0.text == phrase })
        panel.tableView(table, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(value.textView.text, before + phrase)

        let clipboard = try XCTUnwrap(views(value.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "toolbar.clipboard" })
        clipboard.sendActions(for: .touchUpInside)
        value.view.setNeedsLayout(); value.view.layoutIfNeeded()
        let reopened = try XCTUnwrap(views(value.view).compactMap { $0 as? ClipboardPanel }.first)
        XCTAssertFalse(reopened === panel)
        reopened.layoutIfNeeded()
        let reopenedTabs = try XCTUnwrap(views(reopened).compactMap { $0 as? UISegmentedControl }.first)
        XCTAssertEqual(reopenedTabs.selectedSegmentIndex, 0, "Every new panel opening must start on Clipboard after using Common Phrases")
        let reopenedTable = try XCTUnwrap(views(reopened).compactMap { $0 as? UITableView }.first)
        reopenedTable.layoutIfNeeded()
        let reopenedClip = try XCTUnwrap(reopenedTable.cellForRow(at: IndexPath(row: 0, section: 0)))
        XCTAssertTrue(views(reopenedClip).compactMap { $0 as? UILabel }.contains { $0.text == text })
        reopened.tableView(reopenedTable, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(value.textView.text, before + phrase + text)
        print("CLIPBOARD_RECENT_UIKIT textPaste=true history=true clipboardDefault=true commonPhrases=true reopenClipboard=true copyMenu=true compositionProtected=true")
    }
    func testCompactAppearanceOwnsAndRemovesItsHostingController() throws {
        let value = controller(), model = try XCTUnwrap(value.model)
        defer { model.suspend() }
        let surface = try XCTUnwrap(views(value.view).compactMap { $0 as? KeyboardSurface }.first)
        views(surface).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "clipboard.recent.close" }?.sendActions(for: .touchUpInside)
        for _ in 0..<3 {
            let button = try XCTUnwrap(views(surface).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "toolbar.appearance" })
            button.sendActions(for: .touchUpInside)
            let host = try XCTUnwrap(value.children.compactMap { $0 as? UIHostingController<KeyboardAppearancePanel> }.first)
            XCTAssertTrue(host.view.superview === surface)
            surface.closePanel()
            XCTAssertTrue(value.children.isEmpty, "Closing a panel must release its child controller")
        }
    }
    func testCustomKeyTintAndInkStayVisibleAtZeroGlassStrength() throws {
        let button = KeyButton(key: KeyboardKey("A"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        let root = UIViewController(); window.rootViewController = root
        window.overrideUserInterfaceStyle = .dark; window.makeKeyAndVisible()
        root.view.addSubview(button); button.frame = CGRect(x: 10, y: 10, width: 40, height: 56)
        root.view.layoutIfNeeded()
        defer { window.isHidden = true }
        let label = try XCTUnwrap(views(button).compactMap { $0 as? CenteredKeyLabel }.first)
        var settings = KeyboardSettings(); settings.glass = .clear; settings.keyGlassStrength = 0
        settings.keyColorHex = "#FFFFFF"; button.apply(settings)
        let dark = UITraitCollection(userInterfaceStyle: .dark), light = UITraitCollection(userInterfaceStyle: .light)
        XCTAssertEqual(label.textColor.resolvedColor(with: dark), .black)
        let face = try XCTUnwrap(views(button).first { $0.accessibilityIdentifier == "key.face" })
        XCTAssertGreaterThan(face.backgroundColor?.cgColor.alpha ?? 0, 0.70)
        settings.glass = .solid; button.apply(settings)
        XCTAssertEqual(label.textColor.resolvedColor(with: dark), .black)
        settings.keyColorHex = nil; button.apply(settings)
        XCTAssertEqual(label.textColor.resolvedColor(with: dark), .white)
        window.overrideUserInterfaceStyle = .light; settings.glass = .clear; settings.keyColorHex = "#101010"; button.apply(settings)
        XCTAssertEqual(label.textColor.resolvedColor(with: light), .white)
    }
    func testGlassStrengthChangesRenderedPixelsWithoutPersistentAnimations() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let root = UIViewController(); window.rootViewController = root
        window.overrideUserInterfaceStyle = .dark; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for index in 0..<32 {
            let stripe = UIView(frame: CGRect(x: CGFloat(index) * 10, y: 0, width: 10, height: 240))
            stripe.backgroundColor = index.isMultiple(of: 2) ? .white : .black
            root.view.addSubview(stripe)
        }
        var settings = KeyboardSettings(); settings.glass = .clear
        func snapshot() -> Data {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(bounds: window.bounds, format: format).pngData { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
        }
        let keys = KeyGlassMaterial(effect: nil); keys.frame = window.bounds; root.view.addSubview(keys)
        keys.setFaces([CGRect(x: 20, y: 20, width: 280, height: 200)])
        settings.keyGlassStrength = 0; keys.apply(settings)
        try await Task.sleep(nanoseconds: 50_000_000)
        let noKeys = snapshot()
        settings.keyGlassStrength = 1; keys.apply(settings)
        try await Task.sleep(nanoseconds: 50_000_000)
        let fullKeys = snapshot()
        if !UIAccessibility.isReduceTransparencyEnabled && !ProcessInfo.processInfo.isLowPowerModeEnabled {
            XCTAssertNotEqual(noKeys, fullKeys, "Key strength must change the visible material")
        }
        for view in views(keys) {
            XCTAssertTrue(view.layer.animationKeys()?.isEmpty ?? true, "Material intensity must settle instead of leaving a paused animation active")
        }
        XCTAssertEqual(keys.alpha, 1)
        print("GLASS_RENDERED_STRENGTH keyPixelsChanged=\(noKeys != fullKeys) persistentAnimations=false")
    }
    func testKeyMaterialLeavesTheOuterSheetAndKeyGapsUnpainted() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), root = UIViewController()
        window.rootViewController = root; window.overrideUserInterfaceStyle = .dark; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for index in 0..<40 {
            let stripe = UIView(frame: CGRect(x: CGFloat(index) * 10, y: 0, width: 10, height: 320))
            stripe.backgroundColor = index.isMultiple(of: 2) ? .white : .black; root.view.addSubview(stripe)
        }
        let material = KeyGlassMaterial(effect: nil)
        material.frame = CGRect(x: 8, y: 44, width: 304, height: 224); root.view.addSubview(material)
        material.setFaces([CGRect(x: 8, y: 8, width: 80, height: 40), CGRect(x: 104, y: 8, width: 80, height: 40)])
        var settings = KeyboardSettings(); settings.keyGlassStrength = 0; material.apply(settings)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        func snapshot() throws -> CGImage {
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            return try XCTUnwrap(image.cgImage)
        }
        func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> Data {
            let data = try XCTUnwrap(image.dataProvider?.data) as Data
            let count = image.bitsPerPixel / 8, offset = y * image.bytesPerRow + x * count
            return data.subdata(in: offset..<offset+count)
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        let before = try snapshot()
        settings.keyGlassStrength = 1; material.apply(settings)
        try await Task.sleep(nanoseconds: 60_000_000)
        let after = try snapshot()
        for (x,y) in [(9,44),(8,45),(311,45),(9,267),(160,267),(108,72)] {
            XCTAssertEqual(try pixel(before,x,y), try pixel(after,x,y), "Material painted the outer rectangle or a gap at \(x),\(y)")
        }
        if #available(iOS 26.0, *) {
            XCTAssertFalse(material.effect is UIGlassEffect, "Disconnected key faces must not outline a single refractive sheet")
        }
    }
}
