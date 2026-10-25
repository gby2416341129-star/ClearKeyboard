import XCTest
import UIKit
import SwiftUI

@MainActor final class RemoteProxyPerformanceTests: XCTestCase {
    func testSegmentedNamesLearnWholeSpellingAndInitialsWithRealUIKitTextStorage() async throws {
        let suite = "clear.names.runtime." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let proxy = UIKitDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        var settings = KeyboardSettings(); settings.language = .chinese
        settings.learnChoices = true; settings.automaticClipboard = false; settings.predictions = false
        let model = KeyboardModel(document: controller, settings: settings, defaults: defaults)
        defer { model.suspend(); defaults.removePersistentDomain(forName: suite) }
        try await waitFor { model.engineState == "离线就绪" }
        for (raw, name, parts, initials) in [
            ("gouboyuan", "苟博渊", [("苟", 3), ("博", 2), ("渊", 4)], "gby"),
            ("chenyuhan", "陈宇涵", [("陈", 4), ("宇", 2), ("涵", 3)], "cyh"),
            ("liuxinyue", "刘欣悦", [("刘", 3), ("欣", 3), ("悦", 3)], "lxy")
        ] {
            model.handle(.enter)
            let anchor = proxy.textView.text ?? ""
            for letter in raw { model.handle(.text(String(letter))) }
            var confirmed = ""
            for (text, consumed) in parts {
                let candidate = try await selectable(text, consumed: consumed, model: model)
                var remainder = model.composition; remainder.consume(consumed)
                model.chooseDisplayed(candidate, context: model.candidateContext)
                confirmed += text
                try await waitFor { proxy.textView.text == anchor + confirmed + remainder.raw }
                XCTAssertEqual(model.composition.raw, remainder.raw)
                XCTAssertEqual(controller.contextBefore, anchor + confirmed + remainder.raw)
            }
            XCTAssertEqual(proxy.textView.text, anchor + name); XCTAssertNil(proxy.textView.markedTextRange)
            for letter in initials { model.handle(.text(String(letter))) }
            try await waitFor { model.candidatesAreCurrent && model.candidates.prefix(4).contains { $0.text == name } }
            let recalled = try XCTUnwrap(model.candidates.first { $0.text == name })
            XCTAssertEqual(recalled.consumed, initials.count, "An initials alias must consume its own source, not the original full spelling")
            model.chooseDisplayed(recalled, context: model.candidateContext)
            XCTAssertEqual(proxy.textView.text, anchor + name + name)
            XCTAssertTrue(model.composition.isEmpty)
        }
        model.flushLearning()
        let restored = LearningStore.load(defaults, epoch: defaults.string(forKey: "clear.learned.epoch")).personal
        XCTAssertTrue(restored.candidates(for: "gby").contains { $0.text == "苟博渊" && $0.consumed == 3 })
        XCTAssertTrue(restored.candidates(for: "gouboyuan").contains { $0.text == "苟博渊" && $0.consumed == 9 })
        print("NAME_LEARNING_UIKIT names=3 segmentedSelections=9 fullSpellingAndInitials=true lostWords=0 duplicatedPinyin=0")
    }
    private func selectable(_ text: String, consumed: Int, model: KeyboardModel) async throws -> Candidate {
        try await waitFor { model.candidatesAreCurrent }
        for _ in 0..<10 {
            if let value = model.candidates.first(where: { $0.text == text && $0.consumed == consumed }) { return value }
            let count = model.candidates.count
            guard model.hasMoreCandidates else { break }
            model.loadMoreCandidates(context: model.candidateContext)
            try await waitFor { model.candidates.count > count || !model.hasMoreCandidates }
        }
        return try XCTUnwrap(model.candidates.first { $0.text == text && $0.consumed == consumed }, "Missing selectable character \(text) for \(model.composition.raw)")
    }
    func testNumericRecallNeedsTwoCompletedRunsAndInsertsOnlySuffixInRealUIKit() async throws {
        let suite = "clear.numbers.runtime." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let proxy = UIKitDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        var settings = KeyboardSettings(); settings.language = .chinese
        settings.learnChoices = true; settings.automaticClipboard = false; settings.predictions = false
        let model = KeyboardModel(document: controller, settings: settings, defaults: defaults)
        defer { model.suspend(); defaults.removePersistentDomain(forName: suite) }
        model.handle(.page(.numbers))
        let surface = KeyboardSurface(model: model)
        surface.frame = CGRect(x: 0, y: 0, width: 390, height: 276); surface.layoutIfNeeded()
        for letter in "19981108" { model.handle(.text(String(letter))) }
        model.handle(.enter)
        for letter in "1998" { model.handle(.text(String(letter))) }
        XCTAssertFalse(model.candidates.contains { $0.text == "1108" }, "One completed run must not activate recall")
        for _ in 0..<4 { model.handle(.delete) }
        for letter in "19981108" { model.handle(.text(String(letter))) }
        model.handle(.enter)
        let anchor = proxy.textView.text ?? ""
        let started = ProcessInfo.processInfo.systemUptime
        for letter in "1998" { model.handle(.text(String(letter))) }
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        XCTAssertTrue(model.candidatesAreCurrent)
        let suffix = try XCTUnwrap(model.candidates.first { $0.text == "1108" })
        XCTAssertEqual(suffix.consumed, 0); XCTAssertEqual(suffix.reading, "19981108")
        XCTAssertEqual(proxy.textView.text, anchor + "1998", "Suggestions must never insert without a choice")
        let context = model.candidateContext, insertions = proxy.insertedTexts.count
        try await waitFor { self.descendants(surface).contains { $0 is CandidateButton && $0.accessibilityIdentifier == "candidate.1108" && !$0.isHidden } }
        let suffixButton = try XCTUnwrap(descendants(surface).compactMap { $0 as? CandidateButton }.first { $0.accessibilityIdentifier == "candidate.1108" && !$0.isHidden })
        XCTAssertTrue(suffixButton.accessibilityActivate(), "The visible number row must perform the same validated selection as touch")
        XCTAssertEqual(proxy.textView.text, anchor + "19981108")
        XCTAssertEqual(proxy.insertedTexts.count, insertions + 1); XCTAssertEqual(proxy.insertedTexts.last, "1108")
        model.chooseDisplayed(suffix, context: context)
        XCTAssertEqual(proxy.textView.text, anchor + "19981108", "A repeated tap on the old prefix must not append twice")
        model.handle(.enter); model.flushLearning()
        let restored = LearningStore.load(defaults, epoch: defaults.string(forKey: "clear.learned.epoch")).numbers
        XCTAssertEqual(restored.candidates(for: "1998").first?.text, "1108")
        model.settings.language = .english
        for letter in "1998" { model.handle(.text(String(letter))) }
        model.chooseDisplayed(try XCTUnwrap(model.candidates.first { $0.text == "1108" }), context: model.candidateContext)
        XCTAssertTrue(controller.contextBefore.hasSuffix("19981108"), "English mode must not add a completion space to a numeric suffix")
        XCTAssertLessThan(elapsed, 100, "Numeric recall must not wait for the sentence decoder")
        print("NUMERIC_RECALL_UIKIT completedThreshold=2 suffixOnly=true automaticInsertions=0 staleTapIgnored=true keyAndRecallMs=\(elapsed)")
    }
    func testNumericRecallSurvivesReloadAndRespectsDisableAndClear() async throws {
        let suite = "clear.numbers.settings." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let document = WordLookupDocument()
        var settings = KeyboardSettings(); settings.language = .chinese; settings.learnChoices = true
        settings.automaticClipboard = false; settings.predictions = false
        let model = KeyboardModel(document: document, settings: settings, defaults: defaults)
        defer { model.suspend(); defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<2 { model.insertLiteral("001234567890"); model.handle(.enter) }
        model.flushLearning()
        let reloaded = KeyboardModel(document: document, settings: settings, defaults: defaults)
        defer { reloaded.suspend() }
        reloaded.insertLiteral("0012")
        XCTAssertEqual(reloaded.candidates.first?.text, "34567890")
        let stale = reloaded.candidates.first, context = reloaded.candidateContext
        reloaded.handle(.delete)
        if let stale { reloaded.chooseDisplayed(stale, context: context) }
        XCTAssertTrue(document.before.hasSuffix("001"))
        let disabledCandidate = reloaded.candidates.first, disabledContext = reloaded.candidateContext, beforeDisabled = document.before
        reloaded.settings.learnChoices = false
        if let disabledCandidate { reloaded.chooseDisplayed(disabledCandidate, context: disabledContext) }
        XCTAssertEqual(document.before, beforeDisabled, "Disabling recall invalidates an old visible numeric suggestion even before the next draw")
        reloaded.refreshCandidates()
        XCTAssertFalse(reloaded.candidates.contains { $0.text == "34567890" })
        reloaded.settings.learnChoices = true
        reloaded.handle(.enter)
        let prefs = Preferences(store: SettingsStore(defaults: defaults)); prefs.clearLearning()
        reloaded.flushLearning(); reloaded.reloadSettings()
        reloaded.insertLiteral("0012")
        XCTAssertFalse(reloaded.candidates.contains { $0.text == "34567890" })
        XCTAssertNil(defaults.data(forKey: "clear.numbers.v1"))
        XCTAssertNil(defaults.data(forKey: "clear.choices.v2"))
        print("NUMERIC_RECALL_LIFECYCLE leadingZeroes=true persistence=true deletionInvalidatesOldTap=true disable=true clear=true")
    }
    func testLongLifestyleArticlesNeverCommitBeforeAChoiceOrLoseTheirRemainder() async throws {
        var keys = 0
        for article in LifestyleTypingFixtures.articles {
            let proxy = UIKitDocumentProxy(), controller = ProxyKeyboardController()
            controller.proxy = proxy; controller.loadViewIfNeeded()
            let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
            model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
            defer { model.suspend() }
            try await waitFor { model.engineState == "离线就绪" }
            for letter in article.raw { model.handle(.text(String(letter))); keys += 1 }
            XCTAssertGreaterThan(article.raw.count, 1_500)
            XCTAssertEqual(model.composition.raw, article.raw, "A decoder window cannot automatically confirm or split an article")
            XCTAssertTrue(proxy.insertedTexts.isEmpty, "Typing alone must never commit Chinese or literal pinyin")
            try await waitFor { proxy.textView.text == article.raw }
            try await waitFor { model.candidatesAreCurrent && model.candidates.contains { $0.text.contains { !$0.isASCII } && $0.consumed > 0 } }
            let candidate = try XCTUnwrap(model.candidates.first { $0.text.contains { !$0.isASCII } && $0.consumed > 0 })
            XCTAssertLessThan(candidate.consumed, article.raw.count)
            var remainder = model.composition; remainder.consume(candidate.consumed)
            model.chooseDisplayed(candidate, context: model.candidateContext)
            try await waitFor { proxy.textView.text == candidate.text + remainder.raw }
            XCTAssertEqual(model.composition.raw, remainder.raw)
            model.finishCompositionAsTyped()
            XCTAssertEqual(proxy.textView.text, candidate.text + remainder.raw)
            XCTAssertNil(proxy.textView.markedTextRange)
            XCTAssertTrue(model.composition.isEmpty)
            // Enter may confirm the already visible marked pinyin by unmarking
            // it. Verify text conservation and one Chinese insertion, without
            // requiring a second insertion of that literal text.
            XCTAssertEqual(proxy.insertedTexts.filter { $0.contains { !$0.isASCII } }, [candidate.text])
            // Also exercise one atomic Chinese replacement with a complete,
            // naturally punctuated article, independently of decoder quality.
            controller.setMarkedText(article.raw)
            controller.commitMarkedText(article.text)
            XCTAssertEqual(proxy.textView.text, candidate.text + remainder.raw + article.text)
            await Task.yield()
            XCTAssertEqual(proxy.textView.text, candidate.text + remainder.raw + article.text)
        }
        print("LONGFORM_UIKIT articles=4 typedLetters=\(keys) automaticCommits=0 lostRemainders=0 actualUITextView=true")
    }
    func testRapidTypingAfterAnExternalClearKeepsTheNewComposition() async throws {
        let proxy = UIKitDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "nihao" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent && model.candidates.contains { $0.text == "你好" } }
        model.chooseDisplayed(try XCTUnwrap(model.candidates.first { $0.text == "你好" }), context: model.candidateContext)
        proxy.textView.text = ""; proxy.textView.selectedRange = NSRange(location: 0, length: 0)
        controller.textDidChange(nil)
        for character in "zaigansha" { model.handle(.text(String(character))) }
        try await waitFor { proxy.textView.text == "zaigansha" }
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(controller.contextBefore, "zaigansha")
        XCTAssertEqual(model.composition.raw, "zaigansha", "A changed committed prefix must not turn new pinyin into literal text")
        try await waitFor { model.candidatesAreCurrent && model.candidates.contains { $0.text == "在干啥" } }
        model.chooseDisplayed(try XCTUnwrap(model.candidates.first { $0.text == "在干啥" }), context: model.candidateContext)
        XCTAssertEqual(proxy.textView.text, "在干啥")
        XCTAssertTrue(model.composition.isEmpty)
        print("RAPID_CLEAR_AND_RETYPE actualUITextView=true newSpellingRetained=true clearedChineseNotRestored=true")
    }
    func testDetachedViewDeliversLatestFrameTaskAndCancellation() async throws {
        let view = UIView(), frame = DisplayFrameTask()
        XCTAssertNil(view.window)
        var delivered: [Int] = []
        frame.schedule(in: view, maximumFramesPerSecond: 120) { delivered.append(1) }
        frame.schedule(in: view, maximumFramesPerSecond: 120) { delivered.append(2) }
        XCTAssertTrue(delivered.isEmpty)
        try await waitFor { delivered == [2] }
        frame.schedule(in: view, maximumFramesPerSecond: 120) { delivered.append(3) }
        frame.cancel()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(delivered, [2])
        print("DETACHED_FRAME_TASK latestOnly=true cancelledWorkRejected=true")
    }
    func testAmbiguousCommittedAcknowledgementIsRecheckedUntilItSettles() throws {
        let empty = HostTextSnapshot(before: "", document: "field")
        var state = HostTextState(empty)
        state.insert("办公", now: 1)
        XCTAssertEqual(state.reconcile(empty, now: 1.1), .ownEdit)
        XCTAssertTrue(state.shouldRecheck(empty, now: 1.1))
        XCTAssertEqual(state.reconcile(empty, now: 2.2), .externalEdit)
        XCTAssertEqual(state.snapshot.before, "")
        XCTAssertFalse(state.shouldRecheck(empty, now: 2.2))
        state.setMarked("nihao", now: 3)
        XCTAssertEqual(state.reconcile(empty, now: 3.1), .ownEdit)
        XCTAssertFalse(state.shouldRecheck(empty, now: 3.1), "An omitted active marked range must not cause perpetual polling")
        let changed = HostTextSnapshot(before: "另一段nihao", document: "field")
        XCTAssertEqual(state.reconcile(changed, now: 3.2), .compositionContextChanged)
        XCTAssertEqual(state.snapshot.before, changed.before); XCTAssertTrue(state.hasMarkedText)
        print("COMMITTED_ACK_RECHECK externalClearAdopted=true markedBoundaryDoesNotPoll=true")
    }
    func testKeysArrivingInsideAHostCommitAreAppliedOnceInOrder() async throws {
        let proxy = UIKitDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        let trials: [([KeyAction], String, String)] = [
            ([.enter], "你好\n", ""), ([.space], "你好 ", ""), ([.delete], "你", ""),
            ([.text("a")], "你好a", "a"), ([.enter, .text("h"), .text("d")], "你好\nhd", "hd")
        ]
        for (actions, expected, remaining) in trials {
            model.clearComposition(); proxy.textView.text = ""; proxy.textView.selectedRange = NSRange(location: 0, length: 0)
            controller.textDidChange(nil)
            try await waitFor { controller.contextBefore.isEmpty }
            for character in "nihao" { model.handle(.text(String(character))) }
            try await waitFor { model.candidatesAreCurrent && model.candidates.contains { $0.text == "你好" } }
            let candidate = try XCTUnwrap(model.candidates.first { $0.text == "你好" })
            proxy.afterInsert = {
                proxy.afterInsert = nil
                for action in actions { model.handle(action) }
            }
            model.chooseDisplayed(candidate, context: model.candidateContext)
            try await waitFor { proxy.textView.text == expected }
            XCTAssertEqual(controller.contextBefore, expected)
            XCTAssertEqual(model.composition.raw, remaining)
            await Task.yield()
            XCTAssertEqual(proxy.textView.text, expected)
        }
        print("HOST_COMMIT_REENTRANCY actualUITextView=true scenarios=5 droppedKeys=0 duplicateKeys=0 ordering=preserved")
    }
    func testRealUIKitEditingConservesEveryChosenWordAndUntouchedContext() async throws {
        let proxy = UIKitDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        let drafts = ["bangongji", "zaigansha", "wogeimam", "busuanchadla", "chongzhika", "jintianxiayu",
            "qingbangwokankan", "womenmingtianzaijiudianjian", String(repeating: "nichifanlema", count: 9)]
        var choices = 0, edits = 0
        for (index, raw) in drafts.enumerated() {
            let prefix = "前文🙂\(index)：", suffix = "｜后文🙂"
            proxy.textView.text = prefix + suffix
            proxy.textView.selectedRange = NSRange(location: prefix.utf16.count, length: 0)
            controller.textDidChange(nil)
            try await waitFor { controller.contextBefore == prefix && controller.contextAfter == suffix }
            for character in raw { model.handle(.text(String(character))); edits += 1 }
            // Backspace and retype the last character before any pending
            // spelling frame is guaranteed to have reached the host.
            model.handle(.delete); model.handle(.text(String(try XCTUnwrap(raw.last)))); edits += 2
            var confirmed = "", steps = 0
            while !model.composition.isEmpty {
                try await waitFor { model.candidatesAreCurrent && model.candidates.contains { $0.text != model.composition.raw && $0.consumed > 0 } }
                let available = model.candidates.filter { $0.text != model.composition.raw && $0.consumed > 0 }
                let candidate = try XCTUnwrap((index % 2 == 0 ? available.first { $0.consumed < model.composition.normalized.count } : nil) ?? available.first)
                var remainder = model.composition; remainder.consume(candidate.consumed)
                confirmed += candidate.text
                model.chooseDisplayed(candidate, context: model.candidateContext)
                try await waitFor { proxy.textView.text == prefix + confirmed + remainder.raw + suffix }
                XCTAssertEqual(model.composition, remainder)
                XCTAssertEqual(controller.contextBefore, prefix + confirmed + remainder.raw)
                XCTAssertEqual(controller.contextAfter, suffix)
                if remainder.isEmpty { XCTAssertNil(proxy.textView.markedTextRange) }
                else {
                    let marked = try XCTUnwrap(proxy.textView.markedTextRange)
                    XCTAssertEqual(proxy.textView.text(in: marked), remainder.raw)
                }
                choices += 1; steps += 1
                XCTAssertLessThanOrEqual(steps, raw.count, "Every choice must consume some spelling")
                if steps > raw.count { break }
            }
            XCTAssertEqual(proxy.textView.text, prefix + confirmed + suffix)
            XCTAssertEqual(proxy.insertedTexts.suffix(steps).joined(), confirmed)
        }
        print("EDIT_TEXT_CONSERVATION actualUITextView=true drafts=\(drafts.count) keyEdits=\(edits) choices=\(choices) lostWords=0 duplicatedPinyin=0 contextPreserved=true")
    }
    func testCandidateCommitReplacesRealUIKitMarkedRangeInOneInsertion() async throws {
        let proxy = UIKitDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        for (raw, chinese) in [("bangongji", "办公机"), (String(repeating: "nichifanlema", count: 12), String(repeating: "你吃饭了吗", count: 12))] {
            proxy.textView.text = "前文🙂"; proxy.textView.selectedRange = NSRange(location: "前文🙂".utf16.count, length: 0)
            controller.textDidChange(nil)
            try await waitFor { controller.contextBefore == "前文🙂" }
            // Neither a queued, as-yet-unwritten spelling nor an older host
            // spelling may be flushed after its Chinese choice is committed.
            controller.setMarkedText(String(raw.prefix(1)))
            try await waitFor { proxy.textView.markedTextRange != nil }
            controller.setMarkedText(raw)
            let writes = proxy.markedWrites.count, inserts = proxy.insertedTexts.count
            controller.commitMarkedText(chinese)
            XCTAssertEqual(proxy.textView.text, "前文🙂" + chinese)
            XCTAssertEqual(controller.contextBefore, "前文🙂" + chinese)
            XCTAssertNil(proxy.textView.markedTextRange)
            XCTAssertTrue(proxy.markedWrites.dropFirst(writes).allSatisfy(\.isEmpty),
                "Commit may clear the keyboard's existing mark, but must not send an obsolete pinyin frame")
            XCTAssertEqual(proxy.insertedTexts.count, inserts + 1)
            await Task.yield()
            XCTAssertEqual(proxy.textView.text, "前文🙂" + chinese)
        }
        print("ATOMIC_CANDIDATE_COMMIT actualUITextView=true longAndPendingSpelling=true insertionsPerChoice=1")
    }
    func testPartialOfficeChoiceAndRemainingMachineUseRealUIKitReplacement() async throws {
        let proxy = UIKitDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "bangongji" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent }
        if !model.candidates.contains(where: { $0.text == "办公" }) {
            model.loadMoreCandidates(context: model.candidateContext)
            try await waitFor { model.candidates.contains { $0.text == "办公" } }
        }
        let office = try XCTUnwrap(model.candidates.first { $0.text == "办公" })
        XCTAssertEqual(office.consumed, 7)
        let unmarks = proxy.unmarkWrites
        model.chooseDisplayed(office, context: model.candidateContext)
        try await waitFor { proxy.textView.text == "办公ji" && model.candidatesAreCurrent }
        XCTAssertEqual(model.composition.raw, "ji")
        let marked = try XCTUnwrap(proxy.textView.markedTextRange)
        XCTAssertEqual(proxy.textView.text(in: marked), "ji", "The committed Chinese must be outside the new marked range")
        if !model.candidates.contains(where: { $0.text == "机" }) {
            model.loadMoreCandidates(context: model.candidateContext)
            try await waitFor { model.candidates.contains { $0.text == "机" } }
        }
        let machine = try XCTUnwrap(model.candidates.first { $0.text == "机" })
        model.chooseDisplayed(machine, context: model.candidateContext)
        XCTAssertEqual(proxy.textView.text, "办公机")
        XCTAssertEqual(controller.contextBefore, "办公机")
        XCTAssertTrue(model.composition.isEmpty); XCTAssertNil(proxy.textView.markedTextRange)
        XCTAssertEqual(proxy.insertedTexts.suffix(2), ["办公", "机"])
        XCTAssertEqual(proxy.unmarkWrites, unmarks, "Candidate selection must not stage Chinese through unmark/re-mark")
        await Task.yield()
        XCTAssertEqual(proxy.textView.text, "办公机", "A pending spelling cannot reappear as ji机")
        print("PARTIAL_CANDIDATE_COMMIT actualUITextView=true sourceCandidates=true officeRetained=true rawJiReplaced=true")
    }
    func testPartialConversionPreservesItsDraftAcrossDelayedAcknowledgements() {
        let initial = HostTextSnapshot(before: "前文🙂", after: "｜后文", document: "partial-field")
        var state = HostTextState(initial)
        state.setMarked("jintiannichifanlema", now: 1)
        let spellingAcknowledgement = state.snapshot
        state.commitMarked("今天你", remaining: "chifanlema", now: 1.1)
        let remainder = state.snapshot
        XCTAssertEqual(remainder.before, "前文🙂今天你chifanlema")
        XCTAssertTrue(state.hasMarkedText)
        XCTAssertEqual(state.reconcile(spellingAcknowledgement, now: 3), .ownEdit,
            "A pre-conversion acknowledgement must remain owned while the remainder is being converted")
        XCTAssertEqual(state.snapshot, remainder)
        XCTAssertEqual(state.reconcile(remainder, now: 3.1), .ownEdit)
        var selectionChange = remainder; selectionChange.selected = "后文"
        XCTAssertEqual(state.reconcile(selectionChange, now: 3.2), .externalEdit,
            "Retaining conversion acknowledgements must not suppress a real external selection")
        XCTAssertFalse(state.hasMarkedText)
        XCTAssertEqual(state.reconcile(spellingAcknowledgement, now: 3.3), .externalEdit,
            "The old conversion chain must be discarded after an external edit")
    }
    func testPartialConversionOldWholeDraftCallbackCannotUnmarkRemainderAfterOneSecond() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "jintiannichifanlema" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent && proxy.before == "jintiannichifanlema" }
        model.chooseDisplayed(Candidate(text: "今天你", reading: "jintianni", consumed: 9), context: model.candidateContext)
        try await waitFor { proxy.before == "今天你chifanlema" && model.candidatesAreCurrent }
        let unmarks = proxy.unmarkWrites
        try await Task.sleep(nanoseconds: 1_100_000_000)
        proxy.visibleBefore = "jintiannichifanlema"
        let reads = proxy.contextReads
        controller.selectionDidChange(nil); controller.textDidChange(nil)
        try await waitFor { proxy.contextReads > reads }
        XCTAssertEqual(model.composition.raw, "chifanlema")
        XCTAssertEqual(controller.contextBefore, "今天你chifanlema")
        XCTAssertEqual(proxy.markedLength, 10); XCTAssertEqual(proxy.unmarkWrites, unmarks)
        XCTAssertTrue(model.candidatesAreCurrent); XCTAssertFalse(model.candidates.isEmpty)
        proxy.visibleBefore = nil
        model.chooseDisplayed(Candidate(text: "吃饭了吗", reading: "chifanlema", consumed: 10), context: model.candidateContext)
        XCTAssertEqual(proxy.before, "今天你吃饭了吗"); XCTAssertTrue(model.composition.isEmpty)
        print("PARTIAL_OLD_ACK_REGRESSION delayedWholeDraftSeconds=1.1 remainderRetained=true protocolFixtureOnly=true")
    }
    func testPartialConversionWithRealUITextFieldSurvivesIdleAndSelectionCallbacks() async throws {
        let field = UITextField(frame: CGRect(x: 20, y: 100, width: 330, height: 48))
        field.borderStyle = .roundedRect; field.text = "前文🙂｜后文"
        field.inputView = UIView(frame: .zero); field.autocorrectionType = .no; field.spellCheckingType = .no
        let host = UIViewController(); host.loadViewIfNeeded(); host.view.addSubview(field)
        let window = try makeHostWindow(host)
        defer { field.resignFirstResponder(); window.isHidden = true }
        XCTAssertTrue(field.becomeFirstResponder())
        let position = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: "前文🙂".utf16.count))
        field.selectedTextRange = field.textRange(from: position, to: position)
        try await assertPartialConversionSurvivesIdle(in: UIKitFieldDocumentProxy(field), name: "UITextField")
    }
    func testPartialConversionWithRealUITextViewSurvivesIdleAndSelectionCallbacks() async throws {
        let textView = UITextView(frame: CGRect(x: 20, y: 100, width: 330, height: 140))
        textView.text = "前文🙂｜后文"; textView.inputView = UIView(frame: .zero)
        textView.autocorrectionType = .no; textView.spellCheckingType = .no
        let host = UIViewController(); host.loadViewIfNeeded(); host.view.addSubview(textView)
        let window = try makeHostWindow(host)
        defer { textView.resignFirstResponder(); window.isHidden = true }
        XCTAssertTrue(textView.becomeFirstResponder())
        textView.selectedRange = NSRange(location: "前文🙂".utf16.count, length: 0)
        try await assertPartialConversionSurvivesIdle(in: UIKitFieldDocumentProxy(textView), name: "UITextView")
    }
    func testPartialConversionInTheAppsActualSwiftUIAppearanceFieldSurvivesIdle() async throws {
        let suite = "clear.partial.app-field." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = Preferences(store: SettingsStore(defaults: defaults))
        let host = UIHostingController(rootView: AppAppearanceDetail(item: .keyColor).environmentObject(preferences))
        let window = try makeHostWindow(host)
        defer { window.endEditing(true); window.isHidden = true; defaults.removePersistentDomain(forName: suite) }
        // SwiftUI may attach appearance.hex to its accessibility wrapper rather
        // than the underlying UIKit field. This production page has one field.
        try await waitFor { self.descendants(host.view).contains { $0 is UITextField } }
        let fields = descendants(host.view).compactMap { $0 as? UITextField }
        XCTAssertEqual(fields.count, 1, "The production appearance page must expose exactly its HEX text field")
        let field = try XCTUnwrap(fields.first)
        // Exercise the production SwiftUI field and its binding/delegate. Do not
        // replace its delegate with a simplified test editor or TypingLab.
        field.inputView = UIView(frame: .zero)
        field.text = "前文🙂｜后文"; field.sendActions(for: .editingChanged)
        XCTAssertTrue(field.becomeFirstResponder())
        let position = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: "前文🙂".utf16.count))
        field.selectedTextRange = field.textRange(from: position, to: position)
        try await assertPartialConversionSurvivesIdle(in: UIKitFieldDocumentProxy(field), name: "AppAppearanceDetail.SwiftUI.TextField")
        XCTAssertEqual(field.text, "前文🙂今天你吃饭了吗｜后文")
    }
    private func makeHostWindow(_ host: UIViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        host.loadViewIfNeeded(); host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        return window
    }
    private func assertPartialConversionSurvivesIdle(in proxy: UIKitFieldDocumentProxy, name: String) async throws {
        proxy.hidesContext = true
        let controller = ProxyKeyboardController(); controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false
        model.settings.automaticClipboard = false; model.settings.predictions = false
        model.settings.localPinyinComposition = nil
        defer { proxy.onMutation = nil; model.suspend() }
        // UIKit owns text and marked ranges. These injected notifications test
        // delayed acknowledgement order, not a real extension/remote connection.
        proxy.onMutation = { [weak controller] in
            // Search-like editors can first reveal context inside the native
            // clear-mark/Chinese insertion acknowledgement, before idle reads.
            if proxy.markedWrites.last == "" { proxy.hidesContext = false }
            controller?.textDidChange(nil); controller?.selectionDidChange(nil)
        }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "jintiannichifanlema" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent && proxy.markedText == "jintiannichifanlema" }
        XCTAssertFalse(controller.usesLocalPinyinComposition, "Missing context must not activate compatibility in a native field")
        // Isolate conversion transport from dictionary coverage/ranking; the
        // public displayed-choice path still validates the live field/context.
        let prefix = Candidate(text: "今天你", reading: "jintianni", consumed: 9)
        model.chooseDisplayed(prefix, context: model.candidateContext)
        try await waitFor { proxy.text == "前文🙂今天你chifanlema｜后文" && proxy.markedText == "chifanlema" && model.candidatesAreCurrent }
        proxy.hidesContext = false
        controller.selectionDidChange(nil); controller.textDidChange(nil)
        try await Task.sleep(nanoseconds: 450_000_000)
        let unmarks = proxy.unmarkWrites
        for delay in [40_000_000, 410_000_000, 800_000_000] as [UInt64] {
            try await Task.sleep(nanoseconds: delay)
            controller.selectionDidChange(nil); controller.textDidChange(nil)
        }
        // Cross both the controller's 350ms idle read and the old one-second
        // acknowledgement lease before selecting the remainder.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(model.composition.raw, "chifanlema", name)
        XCTAssertEqual(proxy.markedText, "chifanlema", name)
        XCTAssertEqual(proxy.text, "前文🙂今天你chifanlema｜后文", name)
        XCTAssertEqual(controller.contextBefore, "前文🙂今天你chifanlema", name)
        XCTAssertEqual(controller.contextAfter, "｜后文", name)
        XCTAssertEqual(proxy.unmarkWrites, unmarks, "Idle callbacks must not commit the remaining pinyin in \(name)")
        XCTAssertTrue(model.candidatesAreCurrent); XCTAssertFalse(model.candidates.isEmpty)
        let meal = Candidate(text: "吃饭", reading: "chifan", consumed: 6)
        model.chooseDisplayed(meal, context: model.candidateContext)
        try await waitFor { proxy.markedText == "lema" && model.candidatesAreCurrent }
        model.chooseDisplayed(Candidate(text: "了吗", reading: "lema", consumed: 4), context: model.candidateContext)
        try await waitFor { proxy.text == "前文🙂今天你吃饭了吗｜后文" }
        XCTAssertTrue(model.composition.isEmpty); XCTAssertNil(proxy.input.markedTextRange)
        XCTAssertEqual(proxy.insertedTexts, ["今天你", "吃饭", "了吗"])
        XCTAssertEqual(proxy.deleteWrites, 0, "Conversion must never delete unrelated host text")
        print("PARTIAL_CONVERSION_UIKIT host=\(name) actualStorage=true injectedCallbackOrder=true idleSeconds=1.65 literalRemainders=0 deleteRepairs=0 remoteProcessVerified=false")
    }
    func testBufferedMarkedHostClearsOnlyItsDraftBeforeChineseInsertion() async throws {
        for hidesContext in [false, true] {
            let proxy = BufferedMarkedDocumentProxy(), controller = ProxyKeyboardController()
            proxy.hidesContext = hidesContext
            controller.proxy = proxy; controller.loadViewIfNeeded()
            if hidesContext { proxy.onMutation = { [weak controller] in controller?.selectionDidChange(nil); controller?.textDidChange(nil) } }
            let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
            model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
            model.settings.localPinyinComposition = hidesContext
            defer { model.settings.localPinyinComposition = nil; model.suspend() }
            try await waitFor { model.engineState == "离线就绪" }
            for character in "nihao" { model.handle(.text(String(character))) }
            try await waitFor { model.candidatesAreCurrent && (hidesContext || proxy.marked == "nihao") }
            XCTAssertEqual(proxy.committed, "前文🙂", "This adapter buffers marked text without displaying it in its committed editor")
            model.chooseDisplayed(Candidate(text: "你好", reading: "nihao", consumed: 5), context: model.candidateContext)
            try await waitFor { proxy.committed == "前文🙂你好" }
            XCTAssertEqual(proxy.insertedTexts, ["你好"])
            XCTAssertTrue(proxy.marked.isEmpty); XCTAssertEqual(proxy.unmarkWrites, 0); XCTAssertEqual(proxy.deleteWrites, 0)
            if hidesContext {
                XCTAssertEqual(proxy.events, ["insert:你好"], "Unreadable editors must never receive provisional spelling or an unmark")
                XCTAssertTrue(controller.usesLocalPinyinComposition)
            } else {
                XCTAssertTrue(proxy.events.suffix(2).elementsEqual(["mark:", "insert:你好"]),
                    "Readable buffered editors require the owned mark to be cleared before insert")
            }
            print("BUFFERED_MARKED_PROTOCOL fixtureOnly=true hidesContext=\(hidesContext) unrelatedDeletes=0 realRemoteHostVerified=false")
        }
    }
    func testUnclearableMarkedProtocolReproducesOldClearThenInsertDuplication() {
        // A deliberately less cooperative adapter than the build53 fixture.
        // This proves why clear-before-insert alone is not a sufficient fix;
        // it does not claim to be the actual remote-desktop application.
        let proxy = UnclearableMarkedDocumentProxy()
        proxy.setMarkedText("nichifanlema", selectedRange: NSRange(location: 12, length: 0))
        proxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        proxy.insertText("你吃饭了吗")
        XCTAssertEqual(proxy.committed, "前文🙂nichifanlema你吃饭了吗")
    }
    func testUnreadableHostKeepsSpellingLocalAndInsertsOnlyChosenChinese() async throws {
        let proxy = UnclearableMarkedDocumentProxy()
        let (controller, model) = try await unclearableHost(proxy)
        defer { model.settings.localPinyinComposition = nil; model.suspend() }
        proxy.contextReads = 0
        for character in "nichifanlema" { model.handle(.text(String(character))) }
        XCTAssertEqual(proxy.contextReads, 0, "Local composition must not add synchronous proxy reads per key")
        try await waitFor { model.candidatesAreCurrent }
        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertEqual(proxy.committed, "前文🙂"); XCTAssertTrue(proxy.provisional.isEmpty)
        XCTAssertTrue(proxy.markedWrites.isEmpty); XCTAssertTrue(proxy.insertedTexts.isEmpty)
        XCTAssertTrue(controller.usesLocalPinyinComposition)
        XCTAssertEqual(model.composition.raw, "nichifanlema")
        model.chooseDisplayed(Candidate(text: "你吃饭了吗", reading: "nichifanlema", consumed: 12), context: model.candidateContext)
        XCTAssertEqual(proxy.committed, "前文🙂你吃饭了吗")
        XCTAssertEqual(proxy.insertedTexts, ["你吃饭了吗"])
        XCTAssertTrue(proxy.markedWrites.isEmpty); XCTAssertEqual(proxy.unmarkWrites, 0); XCTAssertEqual(proxy.deleteWrites, 0)
        XCTAssertTrue(model.composition.isEmpty)
        print("LOCAL_PINYIN_PROTOCOL unreadableContexts=true provisionalHostWrites=0 chineseInsertions=1 fixtureOnly=true realRemoteHostVerified=false")
    }
    func testUnreadablePartialConversionsSurviveDelayedOwnSelectionAcknowledgement() async throws {
        let proxy = UnclearableMarkedDocumentProxy()
        let (controller, model) = try await unclearableHost(proxy)
        defer { model.settings.localPinyinComposition = nil; model.suspend() }
        proxy.onMutation = { [weak controller] in controller?.selectionDidChange(nil); controller?.textDidChange(nil) }
        for character in "jintiannichifanlema" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent }
        model.chooseDisplayed(Candidate(text: "今天你", reading: "jintianni", consumed: 9), context: model.candidateContext)
        XCTAssertEqual(proxy.committed, "前文🙂今天你"); XCTAssertEqual(model.composition.raw, "chifanlema")
        try await Task.sleep(nanoseconds: 1_100_000_000)
        controller.selectionDidChange(nil); controller.textDidChange(nil)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(model.composition.raw, "chifanlema", "A delayed own insertion acknowledgement must not commit or discard the local remainder")
        try await waitFor { model.candidatesAreCurrent }
        model.chooseDisplayed(Candidate(text: "吃饭", reading: "chifan", consumed: 6), context: model.candidateContext)
        try await waitFor { model.candidatesAreCurrent }
        XCTAssertEqual(model.composition.raw, "lema")
        model.chooseDisplayed(Candidate(text: "了吗", reading: "lema", consumed: 4), context: model.candidateContext)
        XCTAssertEqual(proxy.committed, "前文🙂今天你吃饭了吗")
        XCTAssertEqual(proxy.insertedTexts, ["今天你", "吃饭", "了吗"])
        XCTAssertTrue(proxy.markedWrites.isEmpty); XCTAssertEqual(proxy.unmarkWrites, 0); XCTAssertEqual(proxy.deleteWrites, 0)
    }
    func testUnreadableSpacePunctuationRawCommitCancellationAndEnglishStayOrdered() async throws {
        let proxy = UnclearableMarkedDocumentProxy()
        let (controller, model) = try await unclearableHost(proxy)
        defer { model.settings.localPinyinComposition = nil; model.suspend(); _ = controller }
        for character in "nihao" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent && model.candidates.first?.text == "你好" }
        model.handle(.space)
        XCTAssertEqual(proxy.committed, "前文🙂你好")
        for character in "zaigansha" { model.handle(.text(String(character))) }
        model.finishCompositionAsTyped()
        XCTAssertEqual(proxy.committed, "前文🙂你好zaigansha", "Explicit raw confirmation inserts the local spelling exactly once")
        for character in "nihao" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent && model.candidates.first?.text == "你好" }
        model.handle(.text(","))
        XCTAssertEqual(proxy.committed, "前文🙂你好zaigansha你好，")
        let anchor = proxy.committed
        for character in "abc" { model.handle(.text(String(character))) }
        model.clearComposition()
        XCTAssertEqual(proxy.committed, anchor)
        for character in "abc" { model.handle(.text(String(character))) }
        for _ in 0..<3 { model.handle(.delete) }
        XCTAssertEqual(proxy.committed, anchor); XCTAssertEqual(proxy.deleteWrites, 0)
        model.settings.language = .english
        for character in "what" { model.handle(.text(String(character))) }
        XCTAssertEqual(proxy.committed, anchor + "what", "English letters remain direct input on unreadable hosts")
        model.handle(.space)
        XCTAssertEqual(proxy.committed, anchor + "what ")
        XCTAssertTrue(proxy.markedWrites.isEmpty); XCTAssertEqual(proxy.unmarkWrites, 0)
    }
    func testUnreadableNewFieldAndNonemptySelectionRejectOldChineseWithoutHostMutation() async throws {
        for switchesDocument in [false, true] {
            let proxy = UnclearableMarkedDocumentProxy()
            let (controller, model) = try await unclearableHost(proxy)
            defer { model.settings.localPinyinComposition = nil; model.suspend() }
            for character in "nihao" { model.handle(.text(String(character))) }
            try await waitFor { model.candidatesAreCurrent }
            let context = model.candidateContext
            if switchesDocument { proxy.identity = UUID(); proxy.committed = "新字段原文🙂" }
            else { proxy.selection = "前文" }
            let anchor = proxy.committed
            controller.selectionDidChange(nil)
            model.chooseDisplayed(Candidate(text: "你好", reading: "nihao", consumed: 5), context: context)
            try await Task.sleep(nanoseconds: 450_000_000)
            XCTAssertEqual(proxy.committed, anchor)
            XCTAssertEqual(proxy.selection, switchesDocument ? "" : "前文")
            XCTAssertTrue(proxy.insertedTexts.isEmpty); XCTAssertTrue(proxy.markedWrites.isEmpty)
            XCTAssertEqual(proxy.deleteWrites, 0); XCTAssertEqual(proxy.unmarkWrites, 0)
            XCTAssertTrue(model.composition.isEmpty)
        }
    }
    func testLocalDraftStaysLocalWhenRealContextBecomesReadable() async throws {
        let proxy = UnclearableMarkedDocumentProxy()
        let (controller, model) = try await unclearableHost(proxy)
        defer { model.settings.localPinyinComposition = nil; model.suspend() }
        for character in "ni" { model.handle(.text(String(character))) }
        proxy.hidesContext = false; controller.textDidChange(nil)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(model.composition.raw, "ni"); XCTAssertTrue(controller.usesLocalPinyinComposition)
        XCTAssertEqual(controller.contextBefore, "前文🙂ni", "Newly readable real context is the boundary of the still-local draft")
        for character in "hao" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent }
        model.chooseDisplayed(Candidate(text: "你好", reading: "nihao", consumed: 5), context: model.candidateContext)
        XCTAssertEqual(proxy.committed, "前文🙂你好"); XCTAssertTrue(proxy.markedWrites.isEmpty)
        XCTAssertTrue(controller.usesLocalPinyinComposition, "Explicit compatibility stays enabled until the user turns it off")
    }
    func testNativeDraftSurvivesTransientNilContextWithoutLosingChineseCandidates() async throws {
        let field = UITextField(frame: CGRect(x: 20, y: 100, width: 330, height: 48))
        field.text = "前文🙂"; field.inputView = UIView(frame: .zero)
        let host = UIViewController(); host.loadViewIfNeeded(); host.view.addSubview(field)
        let window = try makeHostWindow(host)
        defer { field.resignFirstResponder(); window.isHidden = true }
        XCTAssertTrue(field.becomeFirstResponder())
        let end = field.endOfDocument; field.selectedTextRange = field.textRange(from: end, to: end)
        let proxy = UIKitFieldDocumentProxy(field), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false
        model.settings.automaticClipboard = false; model.settings.localPinyinComposition = nil
        defer { model.settings.localPinyinComposition = nil; model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "nihao" { model.handle(.text(String(character))) }
        try await waitFor { proxy.markedText == "nihao" && model.candidatesAreCurrent }
        proxy.hidesContext = true; controller.textDidChange(nil)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(model.composition.raw, "nihao"); XCTAssertEqual(proxy.markedText, "nihao")
        XCTAssertFalse(controller.usesLocalPinyinComposition)
        XCTAssertFalse(model.candidates.isEmpty); XCTAssertEqual(proxy.unmarkWrites, 0)
        proxy.onMutation = { [weak controller] in controller?.selectionDidChange(nil); controller?.textDidChange(nil) }
        model.handle(.space)
        XCTAssertEqual(proxy.text, "前文🙂你好"); XCTAssertTrue(model.composition.isEmpty)
        for character in "nihao" { model.handle(.text(String(character))) }
        try await waitFor { proxy.markedText == "nihao" && model.candidatesAreCurrent }
        proxy.hidesContext = false; controller.selectionDidChange(nil)
        model.chooseDisplayed(Candidate(text: "你好", reading: "nihao", consumed: 5), context: model.candidateContext)
        XCTAssertEqual(proxy.text, "前文🙂你好你好", "Revealing native context on a choice must not require a second tap")
        XCTAssertEqual(proxy.insertedTexts, ["你好", "你好"]); XCTAssertEqual(proxy.unmarkWrites, 0)
    }
    func testLocalPartialInsertionCanRevealReadableContextWithoutFlushingItsRemainder() async throws {
        let proxy = UnclearableMarkedDocumentProxy()
        let (controller, model) = try await unclearableHost(proxy)
        defer { proxy.onMutation = nil; model.settings.localPinyinComposition = nil; model.suspend() }
        for character in "jintiannichifanlema" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent }
        proxy.onMutation = { [weak controller] in
            proxy.hidesContext = false
            controller?.selectionDidChange(nil); controller?.textDidChange(nil)
        }
        model.chooseDisplayed(Candidate(text: "今天你", reading: "jintianni", consumed: 9), context: model.candidateContext)
        XCTAssertEqual(proxy.committed, "前文🙂今天你")
        XCTAssertEqual(model.composition.raw, "chifanlema")
        XCTAssertEqual(controller.contextBefore, "前文🙂今天你chifanlema")
        XCTAssertTrue(controller.usesLocalPinyinComposition)
        try await waitFor { model.candidatesAreCurrent }
        model.chooseDisplayed(Candidate(text: "吃饭了吗", reading: "chifanlema", consumed: 10), context: model.candidateContext)
        XCTAssertEqual(proxy.committed, "前文🙂今天你吃饭了吗")
        XCTAssertTrue(proxy.markedWrites.isEmpty); XCTAssertEqual(proxy.unmarkWrites, 0)
    }
    func testForcedLocalCompositionProtectsReadableHostIgnoringEmptyMarks() async throws {
        let proxy = UnclearableMarkedDocumentProxy(); proxy.hidesContext = false
        let (controller, model) = try await unclearableHost(proxy, compatibility: false)
        defer { model.settings.localPinyinComposition = nil; model.suspend() }
        XCTAssertFalse(controller.usesLocalPinyinComposition)
        model.settings.localPinyinComposition = true
        XCTAssertTrue(controller.usesLocalPinyinComposition)
        for character in "nihao" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent }
        model.chooseDisplayed(Candidate(text: "你好", reading: "nihao", consumed: 5), context: model.candidateContext)
        XCTAssertEqual(proxy.committed, "前文🙂你好")
        XCTAssertTrue(proxy.markedWrites.isEmpty); XCTAssertEqual(proxy.unmarkWrites, 0); XCTAssertEqual(proxy.deleteWrites, 0)
        model.settings.localPinyinComposition = false
        XCTAssertFalse(controller.usesLocalPinyinComposition)
    }
    func testDismissingUnreadableKeyboardDoesNotCommitUnconfirmedLocalSpelling() async throws {
        let proxy = UnclearableMarkedDocumentProxy()
        let (controller, model) = try await unclearableHost(proxy)
        defer { model.settings.localPinyinComposition = nil; model.suspend() }
        for character in "nihao" { model.handle(.text(String(character))) }
        controller.viewWillDisappear(false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(proxy.committed, "前文🙂"); XCTAssertTrue(model.composition.isEmpty)
        XCTAssertTrue(proxy.markedWrites.isEmpty); XCTAssertTrue(proxy.insertedTexts.isEmpty); XCTAssertEqual(proxy.unmarkWrites, 0)
    }
    private func unclearableHost(_ proxy: UnclearableMarkedDocumentProxy, compatibility: Bool = true) async throws -> (ProxyKeyboardController, KeyboardModel) {
        let controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false
        model.settings.automaticClipboard = false; model.settings.predictions = false
        model.settings.localPinyinComposition = compatibility
        try await waitFor { model.engineState == "离线就绪" }
        return (controller, model)
    }
    func testDocumentSwitchInsideEmptyMarkCannotReceiveOldChineseOrRemainder() async throws {
        let proxy = BufferedMarkedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "jintiannichifanlema" { model.handle(.text(String(character))) }
        try await waitFor { proxy.marked == "jintiannichifanlema" && model.candidatesAreCurrent }
        let replacement = "另一个字段原文🙂"
        proxy.onEmptyMarked = {
            proxy.onEmptyMarked = nil
            proxy.identity = UUID(); proxy.committed = replacement; proxy.marked = "newdraft"
            controller.selectionDidChange(nil); controller.textDidChange(nil)
            // A nested key still carries the old local ledger identity until
            // reconciliation. Aborting conversion must discard it as well.
            model.handle(.text("x"))
        }
        model.chooseDisplayed(Candidate(text: "今天你", reading: "jintianni", consumed: 9), context: model.candidateContext)
        XCTAssertEqual(proxy.committed, replacement)
        XCTAssertTrue(proxy.insertedTexts.isEmpty, "A field switch serviced inside clear-mark must abort the old Chinese insertion")
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(proxy.committed, replacement)
        XCTAssertTrue(proxy.insertedTexts.isEmpty); XCTAssertEqual(proxy.marked, "newdraft")
        XCTAssertFalse(proxy.events.contains("mark:chifanlema"), "The old remainder must never be sent to the newly connected field")
        XCTAssertEqual(proxy.unmarkWrites, 0, "The new field owns its own marked range; abort must not unmark it")
        XCTAssertEqual(proxy.deleteWrites, 0)
        XCTAssertTrue(model.composition.isEmpty)
        print("CLEAR_MARK_DOCUMENT_SWITCH protocolFixtureOnly=true chineseInsertions=0 remainderWrites=0 newFieldUnmarks=0")
    }
    func testVisibleCandidateCannotReplaceANewSelectionBeforeIdleReconciliationInRealUITextView() async throws {
        try await assertImmediateExternalSelectionRejectsOldCandidate(NSRange(location: 0, length: 2), name: "selected-prefix")
    }
    func testVisibleCandidateCannotInsertAtAMovedCaretBeforeIdleReconciliationInRealUITextView() async throws {
        try await assertImmediateExternalSelectionRejectsOldCandidate(NSRange(location: 0, length: 0), name: "moved-caret")
    }
    func testSpaceCannotReplaceANewSelectionBeforeIdleReconciliationInRealUITextView() async throws {
        try await assertImmediateExternalSelectionRejectsOldCandidate(NSRange(location: 0, length: 2), name: "space-selected-prefix", space: true)
    }
    private func assertImmediateExternalSelectionRejectsOldCandidate(_ range: NSRange, name: String, space: Bool = false) async throws {
        let proxy = UIKitDocumentProxy(), controller = ProxyKeyboardController()
        proxy.textView.text = "前文🙂｜后文🙂"
        proxy.textView.selectedRange = NSRange(location: "前文🙂".utf16.count, length: 0)
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "nihao" { model.handle(.text(String(character))) }
        try await waitFor { proxy.textView.text == "前文🙂nihao｜后文🙂" && model.candidatesAreCurrent }
        XCTAssertNotNil(proxy.textView.markedTextRange)
        let candidate = try XCTUnwrap(model.candidates.first { $0.text == "你好" }), context = model.candidateContext
        proxy.textView.selectedRange = range
        let preservedText = try XCTUnwrap(proxy.textView.text), preservedSelection = proxy.textView.selectedRange
        let inserts = proxy.insertedTexts.count, deletes = proxy.deleteWrites
        controller.selectionDidChange(nil)
        // Commit in this same turn, before the normal 350ms host read. Explicit
        // candidate activation may retry twice at 16ms; Space uses the separate
        // commitComposition path and must enforce the same selection boundary.
        if space { model.handle(.space) }
        else { model.chooseDisplayed(candidate, context: context) }
        XCTAssertEqual(proxy.textView.text, preservedText)
        XCTAssertEqual(proxy.textView.selectedRange, preservedSelection)
        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertEqual(proxy.insertedTexts.count, inserts, "An old candidate must not insert after either retry: " + name)
        XCTAssertEqual(proxy.deleteWrites, deletes)
        XCTAssertEqual(proxy.textView.text, preservedText)
        XCTAssertEqual(proxy.textView.selectedRange, preservedSelection, "Candidate validation must preserve the user's new selection: " + name)
        // The eventual reconciliation may cancel composition, but it must not
        // change the user's actual caret/selection or any host text either.
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(proxy.insertedTexts.count, inserts); XCTAssertEqual(proxy.deleteWrites, deletes)
        XCTAssertEqual(proxy.textView.text, preservedText)
        XCTAssertEqual(proxy.textView.selectedRange, preservedSelection)
        print("CANDIDATE_SELECTION_SAFETY actualUITextView=true case=\(name) immediateCommit=true retriesChecked=\(space ? 0 : 2) chineseInsertions=0 hostDeletes=0")
    }
    func testMarkedTextBurstSendsLatestSpellingAndCommitFlushesInOrder() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        proxy.markedWrites = []
        for text in ["w", "wo", "wog", "woge", "wogei"] { controller.setMarkedText(text) }
        XCTAssertEqual(controller.contextBefore, "wogei")
        XCTAssertTrue(proxy.markedWrites.isEmpty, "A backlog of keys must not synchronously send obsolete spellings")
        try await waitFor { proxy.before == "wogei" }
        XCTAssertEqual(proxy.markedWrites, ["wogei"])
        controller.setMarkedText("我给妈妈")
        controller.unmarkText()
        controller.insert("。")
        XCTAssertEqual(proxy.before, "我给妈妈。")
        await Task.yield()
        XCTAssertEqual(proxy.before, "我给妈妈。", "A scheduled flush cannot restore the old spelling after commit")
    }
    func testOverlappingKeyReleasesKeepContactOrderAndCancellation() async throws {
        let document = WordLookupDocument()
        var settings = KeyboardSettings(); settings.language = .english
        settings.automaticClipboard = false; settings.predictions = false
        let model = KeyboardModel(document: document, settings: settings)
        let surface = KeyboardSurface(model: model)
        surface.frame = CGRect(x: 0, y: 0, width: 390, height: 276); surface.layoutIfNeeded()
        defer { model.suspend() }
        let keys = descendants(surface).compactMap { $0 as? KeyButton }
        let l = try XCTUnwrap(keys.first { $0.key.action == .text("l") })
        let e = try XCTUnwrap(keys.first { $0.key.action == .text("e") })
        l.sendActions(for: .touchDown); e.sendActions(for: .touchDown)
        e.sendActions(for: .touchUpInside)
        XCTAssertEqual(document.before, "")
        l.sendActions(for: .touchUpInside)
        XCTAssertEqual(document.before, "le")
        l.sendActions(for: .touchDown); e.sendActions(for: .touchDown)
        e.sendActions(for: .touchUpInside); l.sendActions(for: .touchCancel)
        XCTAssertEqual(document.before, "lee")
    }
    func testCandidateFontChangesReflowAndKeepContinuousTouchSurface() async throws {
        let ribbon = CandidateScrollView()
        ribbon.frame = CGRect(x: 0, y: 0, width: 390, height: 44)
        let items = (0..<24).map { Candidate(text: "候选词\($0)", consumed: 2) }
        var widths: [CGFloat] = []
        for size in CandidateTextSize.allCases {
            ribbon.update(items, context: nil, arithmetic: false, accent: .systemTeal, textSize: size)
            try await waitFor {
                guard let first = self.descendants(ribbon).compactMap({ $0 as? CandidateButton }).first(where: { $0.tag == 0 }),
                      let label = self.descendants(first).compactMap({ $0 as? UILabel }).first(where: { $0.text == items[0].text }) else { return false }
                return label.font.pointSize == CGFloat(size.points)
            }
            ribbon.layoutIfNeeded()
            let first = try XCTUnwrap(descendants(ribbon).compactMap { $0 as? UIButton }.first { $0.tag == 0 })
            first.layoutIfNeeded()
            // The strip lazily measures only a viewport-sized prefix. Its
            // total contentSize need not grow monotonically when a larger
            // font means fewer cells fit in that prefix. Compare the same
            // visible cell, while retaining the touch-surface assertion.
            widths.append(first.frame.width)
            XCTAssertGreaterThan(ribbon.contentSize.width, ribbon.bounds.width)
            let label = try XCTUnwrap(descendants(first).compactMap { $0 as? UILabel }.first { $0.text == items[0].text })
            XCTAssertEqual(label.font.pointSize, CGFloat(size.points))
            XCTAssertTrue(ribbon.hitTest(CGPoint(x: first.frame.maxX - 2, y: 22), with: nil) === ribbon)
        }
        XCTAssertTrue(zip(widths, widths.dropFirst()).allSatisfy { $0 < $1 })
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants($0) } }
    func testExplicitClipboardCheckDistinguishesEmptyUnavailableAndOneSuccessfulRead() throws {
        let suite = "clear.clipboard.check." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        var hasContent = false, canRead = false, reads = 0
        let capture = ClipboardCapture(defaults: defaults, makeStore: { ClipboardStore(url: folder.appendingPathComponent("clips.json")) },
            changeCount: { 1 }, hasStrings: { true }, hasContent: { hasContent },
            readText: { reads += 1; return canRead ? "复制的内容" : nil })
        if case .empty = capture.checkAccess() {} else { XCTFail("An empty clipboard must not claim denied permission") }
        XCTAssertEqual(reads, 0)
        hasContent = true
        if case .unavailable = capture.checkAccess() {} else { XCTFail("An unavailable read must not claim persistent Allow") }
        XCTAssertEqual(reads, 1)
        canRead = true
        if case .contentRead = capture.checkAccess() {} else { XCTFail("An explicit retry must read the same copied item") }
        XCTAssertEqual(reads, 2)
        print("CLIPBOARD_EXPLICIT_CHECK emptyNoRead=true unavailableNotMisreported=true explicitRetry=true")
    }
    func testCandidateInkDoesNotRestartWhenResultsArriveUnevenly() throws {
        if UIAccessibility.isReduceMotionEnabled { throw XCTSkip("System Reduce Motion disables candidate fades") }
        let button = CandidateButton()
        button.frame = CGRect(x: 0, y: 0, width: 180, height: 44)
        let font = UIFont.systemFont(ofSize: 19)
        button.configure(Candidate(text: "旧词", consumed: 3), first: true, accent: .systemTeal, font: font)
        button.configure(Candidate(text: "在", consumed: 3), first: true, accent: .systemTeal, font: font, animate: true)
        let label = try XCTUnwrap(descendants(button).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "candidate.currentInk" })
        let initial = try XCTUnwrap(label.layer.animation(forKey: "candidateText") as? CABasicAnimation)
        let initialPosition = try XCTUnwrap(label.layer.animation(forKey: "candidateTextPosition") as? CABasicAnimation)
        XCTAssertEqual(initial.keyPath, "opacity"); XCTAssertGreaterThan(initial.duration, 0); XCTAssertLessThanOrEqual(initial.duration, 0.18)
        XCTAssertGreaterThanOrEqual((initial.fromValue as? NSNumber)?.doubleValue ?? 0, 0.9, "A replacement must stay readable, without a deep opacity pulse")
        XCTAssertEqual(initialPosition.keyPath, "transform.translation.y")
        XCTAssertEqual(initialPosition.beginTime, initial.beginTime)
        XCTAssertLessThanOrEqual((initialPosition.fromValue as? NSNumber)?.doubleValue ?? 100, 2)
        XCTAssertEqual(descendants(button).compactMap { $0 as? UILabel }.count, 1, "Different words must not be overprinted")
        let frame = button.frame
        for text in ["在干", "在干啥", "在干啥", String(repeating: "候选文字", count: 20)] {
            button.configure(Candidate(text: text, consumed: 8), first: true, accent: .systemTeal, font: font, animate: true)
            let current = try XCTUnwrap(label.layer.animation(forKey: "candidateText") as? CABasicAnimation)
            XCTAssertEqual(current.beginTime, initial.beginTime, "A newer result must not restart the visible timing curve")
            XCTAssertEqual(current.duration, initial.duration)
            let position = try XCTUnwrap(label.layer.animation(forKey: "candidateTextPosition") as? CABasicAnimation)
            XCTAssertEqual(position.beginTime, initialPosition.beginTime)
            XCTAssertEqual(label.text, text); XCTAssertEqual(button.frame, frame)
            XCTAssertEqual(descendants(button).compactMap { $0 as? UILabel }.count, 1)
        }
        button.finishTransition()
        XCTAssertNil(label.layer.animation(forKey: "candidateText"))
        XCTAssertEqual(label.layer.opacity, 1)
        XCTAssertNil(label.layer.animation(forKey: "candidateTextPosition"))
        XCTAssertTrue(CATransform3DIsIdentity(label.layer.transform))
        button.configure(Candidate(text: "立即选词", consumed: 8), first: true, accent: .systemTeal, font: font, animate: false)
        XCTAssertEqual(label.text, "立即选词"); XCTAssertNil(label.layer.animation(forKey: "candidateText"))
        print("CANDIDATE_INK_CLOCK replacements=4 restarts=0 textImmediate=true geometryImmediate=true readableSingleLayer=true")
    }

    func testCursorTransportConvertsWholeGraphemesIntoUIKitStorageOffsets() {
        let field = UITextView(); field.text = "A👨‍👩‍👧‍👦e\u{301}BC"
        field.selectedRange = NSRange(location: "A👨‍👩‍👧‍👦e\u{301}".utf16.count, length: 0)
        let proxy = UIKitFieldDocumentProxy(field), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        controller.moveCursor(-1); XCTAssertEqual(proxy.documentContextBeforeInput, "A👨‍👩‍👧‍👦")
        controller.moveCursor(-1); XCTAssertEqual(proxy.documentContextBeforeInput, "A")
        controller.moveCursor(1); XCTAssertEqual(proxy.documentContextBeforeInput, "A👨‍👩‍👧‍👦")
    }
    func testClipboardMarkedSelectionReplacesOnlyItsOwnedRangeInRealUIKit() throws {
        let field = UITextView(); field.text = "原文🙂尾巴"
        field.selectedRange = NSRange(location: "原文🙂".utf16.count, length: 0)
        let proxy = UIKitFieldDocumentProxy(field), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let session = ClipboardTextSession(document: controller)
        for value in ["甲", "甲乙", "乙", "", "丙"] {
            XCTAssertTrue(session.apply(value)); XCTAssertEqual(field.text, "原文🙂" + value + "尾巴")
        }
        session.finish(); XCTAssertEqual(proxy.deleteWrites, 0)
    }
    func testRejectedClipboardSelectionCannotDeleteOriginalText() throws {
        let field = UITextView(); field.text = "原文🙂"; field.selectedRange = NSRange(location: field.text.utf16.count, length: 0)
        let proxy = UIKitFieldDocumentProxy(field); proxy.markedLimit = 1
        let controller = ProxyKeyboardController(); controller.proxy = proxy; controller.loadViewIfNeeded()
        let session = ClipboardTextSession(document: controller)
        XCTAssertFalse(session.apply("甲乙丙")); XCTAssertFalse(session.apply(""))
        XCTAssertTrue(field.text.hasPrefix("原文🙂")); XCTAssertEqual(proxy.deleteWrites, 0)
    }
    func testLongClearAndUndoRestoreTheOriginalSelectionInRealUIKit() async throws {
        let field = UITextView(); let text = String(repeating: "中文😀", count: 1700); field.text = text
        let range = NSRange(location: 12, length: 12); field.selectedRange = range
        let proxy = UIKitFieldDocumentProxy(field), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let value: DeletedInput? = await withCheckedContinuation { continuation in
            controller.clearInput { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(field.text, "")
        XCTAssertTrue(controller.restoreInput(try XCTUnwrap(value)))
        XCTAssertEqual(field.text, text); XCTAssertEqual(field.selectedRange, range)
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Current candidates did not arrive")
    }
    func testRealControllerKeyPathDoesNotSynchronouslyReadRemoteContext() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 276); controller.view.layoutIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        proxy.reads = 0; proxy.contextReads = 0; proxy.readDelay = 0.008
        let start = ProcessInfo.processInfo.systemUptime
        for character in "nichifankm" { model.handle(.text(String(character))) }
        let keyMs = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        XCTAssertEqual(proxy.reads, 0, "Typing must not poll the remote proxy for every marked-text update or render")
        try await waitFor { model.candidatesAreCurrent && model.candidates.first?.text == "你吃饭了吗" }
        XCTAssertEqual(proxy.reads, 0)
        let candidateMs = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        print("REMOTE_PROXY_INPUT keys=10 synchronousContextReads=\(proxy.reads) keyMs=\(keyMs) candidateMs=\(candidateMs)")
        XCTAssertLessThan(keyMs, 150); XCTAssertLessThan(candidateMs, 400)
        let candidate = try XCTUnwrap(model.candidates.first)
        model.chooseDisplayed(candidate, context: model.candidateContext)
        XCTAssertEqual(proxy.reads, 1, "A tap validates document identity without blocking on remote text fields")
        XCTAssertEqual(proxy.contextReads, 0)
        XCTAssertEqual(proxy.before, "你吃饭了吗")
    }
    func testDelayedOwnHostNotificationsDoNotDiscardCandidates() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "nihao" { model.handle(.text(String(character))) }
        proxy.visibleBefore = "n"; controller.textDidChange(nil)
        XCTAssertEqual(model.composition.raw, "nihao")
        proxy.visibleBefore = nil; controller.textDidChange(nil)
        try await waitFor { model.candidatesAreCurrent }
        XCTAssertEqual(model.candidates.first?.text, "你好")
        proxy.before = "另一个输入框"; proxy.markedLength = 0; controller.textDidChange(nil)
        try await waitFor { model.composition.isEmpty }
        XCTAssertEqual(controller.contextBefore, "另一个输入框")
    }
    func testOwnNotificationBurstPerformsOneDeferredContextRead() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        proxy.reads = 0; proxy.contextReads = 0; proxy.readDelay = 0.008
        let start = ProcessInfo.processInfo.systemUptime
        for character in "nichifankm" { model.handle(.text(String(character))); controller.textDidChange(nil) }
        XCTAssertEqual(proxy.reads, 0, "Even document identity reads must be outside a key's notification callback")
        XCTAssertEqual(proxy.contextReads, 0, "Own notifications must not synchronously poll text during rapid typing")
        XCTAssertLessThan((ProcessInfo.processInfo.systemUptime - start) * 1_000, 250)
        try await waitFor { model.candidatesAreCurrent && proxy.contextReads > 0 }
        XCTAssertEqual(proxy.contextReads, 3, "A burst needs only one before/after/selection reconciliation")
        XCTAssertEqual(model.composition.raw, "nichifankm")
        print("REMOTE_HOST_NOTIFICATIONS keys=10 synchronousContextReads=0 deferredContextReads=\(proxy.contextReads)")
    }
    func testDelayedFirstLetterAcknowledgementCannotSplitLivePinyin() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "zaigansha" { model.handle(.text(String(character))) }
        try await waitFor { proxy.before == "zaigansha" && model.candidatesAreCurrent }
        controller.textDidChange(nil)
        try await waitFor { proxy.contextReads >= 6 }
        // The latest spelling was already acknowledged. An older first-letter
        // callback after the old one-second lease must not cancel the draft.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let reads = proxy.contextReads; proxy.visibleBefore = "z"; controller.textDidChange(nil)
        try await waitFor { proxy.contextReads > reads }
        XCTAssertEqual(model.composition.raw, "zaigansha")
        XCTAssertEqual(proxy.markedLength, "zaigansha".count)
        XCTAssertTrue(model.candidatesAreCurrent)
        XCTAssertFalse(model.candidates.isEmpty)
        proxy.visibleBefore = nil
        let choice = try XCTUnwrap(model.candidates.first)
        model.chooseDisplayed(choice, context: model.candidateContext)
        XCTAssertFalse(proxy.before.hasPrefix("z"), "A delayed acknowledgement must not leave a committed first letter")
        print("LIVE_PINYIN_OWNERSHIP delayedFirstLetter=true candidatesRetained=true commitRetained=true")
    }
    func testHostReadInterruptedByKeyCannotCancelNewSpelling() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        model.handle(.text("z")); try await waitFor { proxy.before == "z" }
        var interrupted = false
        proxy.visibleBefore = "旧的上下文"
        proxy.beforeContextRead = {
            guard !interrupted else { return }; interrupted = true
            model.handle(.text("a"))
            proxy.visibleBefore = nil
        }
        controller.textDidChange(nil)
        try await waitFor { interrupted }
        proxy.beforeContextRead = nil
        try await waitFor { proxy.before == "za" }
        XCTAssertEqual(model.composition.raw, "za")
        XCTAssertEqual(proxy.markedLength, 2)
        for character in "igansha" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent && proxy.before == "zaigansha" }
        XCTAssertEqual(model.composition.raw, "zaigansha")
        print("LIVE_PINYIN_OWNERSHIP interruptedHostRead=true newestSpellingRetained=true")
    }
    func testCandidateButtonCommitsWithoutSpaceWhenHostOmitsMarkedText() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        proxy.omitsMarkedText = true; controller.proxy = proxy; controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 276); controller.view.layoutIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "shaod" { model.handle(.text(String(character))) }
        controller.textDidChange(nil)
        try await waitFor { model.candidatesAreCurrent && model.candidates.first?.text == "稍等" }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(model.composition.raw, "shaod", "Reading candidates must not expire an uncommitted spelling")
        for view in descendants(controller.view) { view.setNeedsLayout(); view.layoutIfNeeded() }
        let button = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "candidate.稍等" })
        XCTAssertTrue(button.isUserInteractionEnabled)
        proxy.contextReads = 0; proxy.contextReadDelay = 0.15
        let start = ProcessInfo.processInfo.systemUptime
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(proxy.before, "稍等"); XCTAssertTrue(model.composition.isEmpty)
        XCTAssertEqual(proxy.contextReads, 0, "A finger choice must not read slow marked-text context")
        XCTAssertLessThan((ProcessInfo.processInfo.systemUptime - start) * 1_000, 150)
        print("CANDIDATE_NO_SPACE hostOmitsMarked=true pauseMs=1200 contextReadsOnTap=0 committed=passed")
    }
    func testReversingCandidateInteractionNeverRunsPendingHostReads() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first)
        let model = surface.model
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "shi" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent }
        let ribbon = try XCTUnwrap(descendants(surface).compactMap { $0 as? CandidateScrollView }.first)
        proxy.contextReads = 0; controller.textDidChange(nil)
        for _ in 0..<4 {
            ribbon.scrollViewWillBeginDragging(ribbon)
            try await Task.sleep(nanoseconds: 110_000_000)
            ribbon.scrollViewDidEndDragging(ribbon, willDecelerate: true)
        }
        ribbon.scrollViewWillBeginDragging(ribbon)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(proxy.contextReads, 0, "Host reads must stay deferred across direction reversals")
        ribbon.scrollViewDidEndDragging(ribbon, willDecelerate: false)
        try await waitFor { proxy.contextReads > 0 }
        XCTAssertEqual(proxy.contextReads, 3)
        print("CANDIDATE_REVERSALS turns=4 contextReadsDuringContact=0 idleReconciliation=passed")
    }
    func testCandidateCannotCommitToANewDocument() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "nihao" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent }
        let candidate = try XCTUnwrap(model.candidates.first), context = model.candidateContext
        proxy.identity = UUID(); proxy.before = "另一输入框"; proxy.markedLength = 0
        model.chooseDisplayed(candidate, context: context)
        XCTAssertEqual(proxy.before, "另一输入框")
    }
    func testVisiblePrefixCanBeTappedWhileMoreSpellingIsPending() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "ni" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent }
        let candidate = try XCTUnwrap(model.candidates.first { $0.text == "你" }), context = model.candidateContext
        for character in "hao" { model.handle(.text(String(character))) }
        model.chooseDisplayed(candidate, context: context)
        try await waitFor { proxy.before == "你hao" }
        XCTAssertEqual(proxy.before, "你hao")
        XCTAssertEqual(model.composition.raw, "hao", "A visible prefix choice must retain the later spelling")
    }
    func testPrefixChoiceDoesNotCrossAnExternalCursorEdit() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "ni" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent }
        let candidate = try XCTUnwrap(model.candidates.first { $0.text == "你" }), context = model.candidateContext
        model.clearComposition(); controller.insert("另一位置")
        for character in "nihao" { model.handle(.text(String(character))) }
        model.chooseDisplayed(candidate, context: context)
        try await waitFor { proxy.before == "另一位置nihao" }
        XCTAssertEqual(proxy.before, "另一位置nihao")
    }
    func testVisibleCompletionConsumesLaterLettersWithinItsReading() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "nih" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent }
        let candidate = try XCTUnwrap(model.candidates.first { $0.text == "你好" }), context = model.candidateContext
        for character in "aoma" { model.handle(.text(String(character))) }
        model.chooseDisplayed(candidate, context: context)
        try await waitFor { proxy.before == "你好ma" }
        XCTAssertEqual(proxy.before, "你好ma", "Completed hao belongs to 你好; only the following word stays marked")
        XCTAssertEqual(model.composition.raw, "ma")
    }
    func testCandidateStripPinsResultsUntilTheSpellingChanges() async throws {
        let ribbon = CandidateScrollView()
        ribbon.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        let context = KeyboardModel.CandidateContext(raw: "shi", before: "shi", after: "", document: "field", language: .chinese)
        let old = (0..<24).map { Candidate(text: "候选\($0)", consumed: 3) }
        ribbon.update(old, context: context, arithmetic: false, accent: .systemTeal)
        try await waitFor { ribbon.accessibilityElements?.count == 24 }
        ribbon.layoutIfNeeded()
        let controls = descendants(ribbon).compactMap { $0 as? UIButton }
        let frames = Dictionary(uniqueKeysWithValues: controls.filter { !$0.isHidden }.map { ($0.accessibilityIdentifier ?? "", $0.frame) })
        func assertVisibleTargets() {
            for button in descendants(ribbon).compactMap({ $0 as? UIButton }) where !button.isHidden && button.frame.intersects(ribbon.bounds) {
                if let expected = frames[button.accessibilityIdentifier ?? ""] { XCTAssertEqual(button.frame, expected) }
            }
        }
        let contentSize = ribbon.contentSize
        XCTAssertLessThan(controls.count, old.count)
        ribbon.scrollViewWillBeginDragging(ribbon)
        // Exercise snapshot retention and geometry only. Delegate calls and
        // offsets cannot validate native finger recognition or device latency.
        for offset: CGFloat in [70, 130, 40, 95, 20, 70] {
            ribbon.contentOffset.x = offset; ribbon.layoutIfNeeded()
            assertVisibleTargets()
            XCTAssertEqual(ribbon.contentSize, contentSize)
        }
        ribbon.update([Candidate(text: "新的结果", consumed: 3)], context: context, arithmetic: false, accent: .systemTeal)
        ribbon.scrollViewDidEndDragging(ribbon, willDecelerate: false)
        try await waitFor { ribbon.accessibilityElements?.count == 25 }
        let appendedControls = descendants(ribbon).compactMap { $0 as? UIButton }
        XCTAssertEqual(Array(appendedControls.prefix(controls.count)), controls)
        XCTAssertLessThan(appendedControls.count, 25)
        XCTAssertEqual(ribbon.accessibilityElements?.count, 25, "New choices extend the logical list without replacing visible targets")
        assertVisibleTargets()
        XCTAssertEqual(ribbon.contentOffset.x, 70, accuracy: 0.1)
        var selection: String?
        ribbon.onSelect = { candidate, _, _ in selection = candidate.text }
        try XCTUnwrap(descendants(ribbon).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "candidate.候选1" }).sendActions(for: .touchUpInside)
        XCTAssertEqual(selection, "候选1", "A late result must not change the visible tap target")
        let nextContext = KeyboardModel.CandidateContext(raw: "shij", before: "shij", after: "", document: "field", language: .chinese)
        ribbon.update([Candidate(text: "时间", consumed: 4)], context: nextContext, arithmetic: false, accent: .systemTeal)
        ribbon.layoutIfNeeded()
        let updated = descendants(ribbon).compactMap { $0 as? UIButton }.filter { !$0.isHidden }
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.first?.accessibilityIdentifier, "candidate.时间")
        XCTAssertEqual(ribbon.contentOffset.x, 0, accuracy: 0.1)
        XCTAssertLessThanOrEqual(ribbon.contentSize.height, ribbon.bounds.height)
    }
    func testCandidateStripReceivesTouchesAcrossWordsGapsAndUnusedSpace() async throws {
        let ribbon = CandidateScrollView()
        ribbon.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        let context = KeyboardModel.CandidateContext(raw: "shi", before: "shi", after: "", document: "field", language: .chinese)
        let candidates = (0..<24).map { Candidate(text: "候选\($0)", consumed: 3) }
        ribbon.update(candidates, context: context, arithmetic: false, accent: .systemTeal)
        try await waitFor { ribbon.accessibilityValue == "offset:0;count:24" }
        ribbon.layoutIfNeeded()
        for width: CGFloat in [320, 240] {
            ribbon.frame.size.width = width; ribbon.layoutIfNeeded()
            for offset: CGFloat in [0, 95, 20, 130] {
                ribbon.contentOffset.x = offset; ribbon.layoutIfNeeded()
                for x in stride(from: CGFloat(1), to: width, by: 3) {
                    for y: CGFloat in [1, 22, 43] {
                        let point = CGPoint(x: ribbon.bounds.minX + x, y: y)
                        XCTAssertTrue(ribbon.hitTest(point, with: nil) === ribbon,
                                      "Every visible point must reach the row at offset \(offset), point \(point)")
                    }
                }
            }
        }
        let next = KeyboardModel.CandidateContext(raw: "shij", before: "shij", after: "", document: "field", language: .chinese)
        ribbon.update([Candidate(text: "时", consumed: 4)], context: next, arithmetic: false, accent: .systemTeal)
        try await waitFor { ribbon.accessibilityValue == "offset:0;count:1" }
        ribbon.layoutIfNeeded()
        XCTAssertTrue(ribbon.hitTest(CGPoint(x: 1, y: 22), with: nil) === ribbon)
        XCTAssertTrue(ribbon.hitTest(CGPoint(x: 230, y: 22), with: nil) === ribbon,
                      "Unused space after a short row must also accept a drag")
        XCTAssertNil(ribbon.hitTest(CGPoint(x: -1, y: 22), with: nil))
        XCTAssertNil(ribbon.hitTest(CGPoint(x: 120, y: 45), with: nil))
    }
    func testCandidateViewportHasNoTransparentHolesForTheKeyboardHost() throws {
        let ribbon = CandidateScrollView()
        ribbon.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        // A normal UIKit hit test alone cannot detect clear-pixel rejection.
        // Verify rendered coverage separately; extension-host gesture delivery still
        // needs a physical device check.
        for style: UIUserInterfaceStyle in [.light, .dark] {
            ribbon.overrideUserInterfaceStyle = style
            for items: [Candidate] in [[], [Candidate(text: "看了", consumed: 0),
                                           Candidate(text: "教大家", consumed: 0)]] {
                ribbon.update(items, context: nil, arithmetic: false, accent: .systemTeal)
                ribbon.layoutIfNeeded()
                let width = 320, height = 44
                var pixels = [UInt8](repeating: 0, count: width * height * 4)
                try pixels.withUnsafeMutableBytes { storage in
                    let context = try XCTUnwrap(CGContext(data: storage.baseAddress,
                        width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                    ribbon.layer.render(in: context)
                }
                let transparentPixels = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] == 0 }.count
                XCTAssertEqual(transparentPixels, 0,
                    "Glyphs, word gaps, leading/trailing space and empty results all need rendered coverage")
            }
        }
    }
    func testCandidateRowTapsExcludeGapsAndKeepAccessibilityActivation() async throws {
        let ribbon = CandidateScrollView()
        ribbon.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        let context = KeyboardModel.CandidateContext(raw: "shi", before: "shi", after: "", document: "field", language: .chinese)
        ribbon.update((0..<24).map { Candidate(text: "候选\($0)", consumed: 3) },
                      context: context, arithmetic: false, accent: .systemTeal)
        try await waitFor { ribbon.accessibilityElements?.count == 24 }
        ribbon.layoutIfNeeded()
        let controls = descendants(ribbon).compactMap { $0 as? UIButton }
        let word = try XCTUnwrap(controls.first { $0.accessibilityIdentifier == "candidate.候选2" })
        var selected: [String] = []
        ribbon.onSelect = { candidate, snapshot, arithmetic in
            selected.append(candidate.text)
            XCTAssertEqual(snapshot, context); XCTAssertFalse(arithmetic)
        }
        for offset: CGFloat in [0, 95] {
            ribbon.contentOffset.x = offset; ribbon.layoutIfNeeded()
            ribbon.selectCandidate(at: word.convert(CGPoint(x: word.bounds.midX, y: 22), to: ribbon))
            XCTAssertEqual(selected.last, "候选2")
            let count = selected.count
            ribbon.selectCandidate(at: word.convert(CGPoint(x: word.bounds.maxX - 2, y: 22), to: ribbon))
            XCTAssertEqual(selected.count, count, "A light tap in a 4-point gap must not select a word")
        }
        XCTAssertEqual(selected, ["候选2", "候选2"])
        XCTAssertEqual(ribbon.accessibilityElements?.count, 24)
        XCTAssertTrue(word.accessibilityActivate())
        XCTAssertEqual(selected, ["候选2", "候选2", "候选2"])
    }
    func testPacedKeysDoNotReadTheHostInTheirFrames() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        host.addChild(controller); host.view.addSubview(controller.view)
        NSLayoutConstraint.activate([controller.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.view.bottomAnchor)])
        controller.didMove(toParent: host)
        host.view.layoutIfNeeded(); controller.view.layoutIfNeeded()
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first)
        let model = surface.model
        model.settings.language = .chinese; model.settings.learnChoices = false; model.settings.automaticClipboard = false
        let frames = KeyboardFrameProbe()
        defer { frames.stop(); window.isHidden = true; model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        try await Task.sleep(nanoseconds: 100_000_000)
        frames.start()
        let buttons = descendants(surface).compactMap { $0 as? KeyButton }
        for view in descendants(surface) { view.layoutIfNeeded() }
        let originalFrames = buttons.map(\.frame), originalHeight = surface.desiredHeight
        proxy.reads = 0; proxy.contextReads = 0; proxy.readDelay = 0.012
        var costs: [Double] = []
        for character in "nichifankmnihao" {
            let button = try XCTUnwrap(buttons.first { $0.key.action == .text(String(character)) })
            let start = ProcessInfo.processInfo.systemUptime
            button.sendActions(for: .touchDown); button.sendActions(for: .touchUpInside)
            controller.textDidChange(nil); controller.selectionDidChange(nil)
            costs.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            // Separate run-loop turns: a tight for-loop misses per-frame host work.
            try await Task.sleep(nanoseconds: 45_000_000)
        }
        XCTAssertEqual(proxy.reads, 0, "Continuous keys and acknowledgements must not poll the proxy")
        XCTAssertEqual(buttons.map(\.frame), originalFrames)
        XCTAssertEqual(surface.desiredHeight, originalHeight)
        let sorted = costs.sorted()
        print("PACED_KEY_FRAMES keys=\(costs.count) hostReads=\(proxy.reads) p95Ms=\(sorted[Int(Double(sorted.count - 1) * 0.95)]) maxMs=\(sorted.last!)")
        let gaps = frames.gaps.sorted()
        XCTAssertGreaterThan(gaps.count, 5, "The real window must keep drawing during the paced input")
        if !gaps.isEmpty {
            print("SIMULATOR_DISPLAY_FRAMES samples=\(gaps.count) p95Ms=\(gaps[Int(Double(gaps.count - 1) * 0.95)] * 1_000) maxMs=\(gaps.last! * 1_000)")
        }
        try await waitFor { proxy.contextReads > 0 }
        XCTAssertEqual(proxy.contextReads, 3, "Read the final host snapshot once after the typing burst")
    }
    func testHoldingAKeyDefersAnAlreadyScheduledHostRead() async throws {
        let proxy = DelayedDocumentProxy(), controller = ProxyKeyboardController()
        controller.proxy = proxy; controller.loadViewIfNeeded()
        let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardSurface }.first?.model)
        model.settings.automaticClipboard = false
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        proxy.contextReads = 0; controller.textDidChange(nil)
        controller.keyInteractionChanged(true)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(proxy.contextReads, 0)
        controller.keyInteractionChanged(false)
        try await waitFor { proxy.contextReads > 0 }
        XCTAssertEqual(proxy.contextReads, 3)
    }
    func testSlowWordLookupNeverRunsOnTheKeyThreadOrOverwritesNewerResults() async throws {
        let document = WordLookupDocument()
        let lookup = expectation(description: "Delayed word worker finishes")
        var settings = KeyboardSettings(); settings.automaticClipboard = false; settings.learnChoices = false
        let model = KeyboardModel(document: document, settings: settings) { engine, raw, preferred in
            XCTAssertFalse(Thread.isMainThread, "A mapped-file lookup must not run inside a touch event")
            if raw == "nihao" {
                Thread.sleep(forTimeInterval: 0.15)
                lookup.fulfill()
                return [Candidate(text: "过期的快速结果", consumed: 5)]
            }
            return engine.immediateCandidates(raw, preferred: preferred)
        }
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        let start = ProcessInfo.processInfo.systemUptime
        for character in "nihao" { model.handle(.text(String(character))) }
        XCTAssertEqual(document.before, "nihao", "Typed spelling reaches the editor before lookup completes")
        XCTAssertLessThan((ProcessInfo.processInfo.systemUptime - start) * 1_000, 50)
        try await waitFor { model.candidates.first?.text == "你好" && model.candidatesAreCurrent }
        await fulfillment(of: [lookup], timeout: 2)
        // Allow the worker's main-queue delivery to run after its expectation.
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.candidates.first?.text, "你好", "Late fast results cannot replace a settled sentence")
    }
    func testKeyContactPreparesWordsButOnlyReleaseChangesTheDocument() async throws {
        let document = WordLookupDocument()
        let lookup = expectation(description: "Word preparation begins during contact")
        var settings = KeyboardSettings()
        settings.automaticClipboard = false; settings.learnChoices = false; settings.predictions = false
        let model = KeyboardModel(document: document, settings: settings) { engine, raw, preferred in
            if raw == "d" { lookup.fulfill() }
            return engine.immediateCandidates(raw, preferred: preferred)
        }
        let surface = KeyboardSurface(model: model)
        surface.frame = CGRect(x: 0, y: 0, width: 390, height: 276); surface.layoutIfNeeded()
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" && model.candidatesAreCurrent }
        let key = try XCTUnwrap(descendants(surface).compactMap { $0 as? KeyButton }.first { $0.key.action == .text("d") })
        let oldRow = model.candidates, oldContext = model.candidateContext
        key.sendActions(for: .touchDown)
        await fulfillment(of: [lookup], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(document.before, "")
        XCTAssertEqual(model.composition.raw, "")
        XCTAssertEqual(model.candidates, oldRow, "Preparation must not show an uncommitted spelling")
        XCTAssertEqual(model.candidateContext, oldContext)
        key.sendActions(for: .touchUpInside)
        XCTAssertEqual(document.before, "d")
        XCTAssertEqual(model.candidateContext?.raw, "d")
        XCTAssertTrue(model.candidatesAreCurrent, "A ready result is adopted in the release frame")
        XCTAssertFalse(model.candidates.isEmpty)
    }
    func testCancelledPreparedKeyNeverAppearsInTheDocumentOrRow() async throws {
        let document = WordLookupDocument()
        var settings = KeyboardSettings(); settings.automaticClipboard = false; settings.learnChoices = false
        let model = KeyboardModel(document: document, settings: settings)
        let surface = KeyboardSurface(model: model)
        surface.frame = CGRect(x: 0, y: 0, width: 390, height: 276); surface.layoutIfNeeded()
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" && model.candidatesAreCurrent }
        let keys = descendants(surface).compactMap { $0 as? KeyButton }
        let d = try XCTUnwrap(keys.first { $0.key.action == .text("d") })
        let j = try XCTUnwrap(keys.first { $0.key.action == .text("j") })
        j.sendActions(for: .touchDown); j.sendActions(for: .touchCancel)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(document.before, ""); XCTAssertEqual(model.composition.raw, "")
        d.sendActions(for: .touchDown); d.sendActions(for: .touchUpInside)
        try await waitFor { model.candidatesAreCurrent }
        XCTAssertEqual(document.before, "d"); XCTAssertEqual(model.candidateContext?.raw, "d")
        XCTAssertEqual(model.composition.raw, "d", "Cancelled preparation cannot leak into a later key")
    }
    func testDirectKeyStartsWordWorkerBeforeSynchronousHostWrite() async throws {
        let document = WordLookupDocument(), started = DispatchSemaphore(value: 0)
        var settings = KeyboardSettings(); settings.automaticClipboard = false; settings.learnChoices = false
        let model = KeyboardModel(document: document, settings: settings) { engine, raw, preferred in
            XCTAssertFalse(Thread.isMainThread)
            if raw == "d" { started.signal() }
            return engine.immediateCandidates(raw, preferred: preferred)
        }
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        document.beforeMarkedWrite = {
            XCTAssertEqual(started.wait(timeout: .now() + 0.5), .success,
                           "Dictionary work must overlap a host write even without a preceding touchDown")
        }
        model.handle(.text("d"))
        document.beforeMarkedWrite = nil
        XCTAssertEqual(document.before, "d")
        try await waitFor { model.candidatesAreCurrent }
    }
    func testRepeatedSpellingCanReuseSettledCandidatesInTheSameTurn() async throws {
        let document = WordLookupDocument()
        var settings = KeyboardSettings(); settings.automaticClipboard = false; settings.learnChoices = false
        let model = KeyboardModel(document: document, settings: settings)
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for character in "nihao" { model.handle(.text(String(character))) }
        try await waitFor { model.candidatesAreCurrent && model.candidates.first?.text == "你好" }
        try await Task.sleep(nanoseconds: 300_000_000)
        model.clearComposition()
        for character in "nihao" { model.handle(.text(String(character))) }
        XCTAssertEqual(document.before, "nihao")
        XCTAssertTrue(model.candidatesAreCurrent, "No worker or main-queue turn is needed for a settled cached spelling")
        XCTAssertEqual(model.candidates.first?.text, "你好")
        XCTAssertEqual(model.candidateContext?.before, document.before)
    }
    func testDismissalPreservesQueuedKeysAndTheirCaseWhileDecoderIsPending() {
        let document = WordLookupDocument()
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = KeyboardSettings(); settings.language = .chinese
        settings.learnChoices = false; settings.predictions = false; settings.automaticClipboard = false
        let model = KeyboardModel(document: document, settings: settings, defaults: defaults) { engine, raw, preferred in
            Thread.sleep(forTimeInterval: 0.2); return engine.immediateCandidates(raw, preferred: preferred)
        }
        for character in "xqzabc" { model.handle(.text(String(character))) }
        model.handle(.space); model.handle(.text("x")); model.handle(.shift); model.handle(.text("a")); model.handle(.literal("#"))
        model.finishCompositionAsTyped()
        XCTAssertEqual(document.before, "xqzabc xA#"); XCTAssertTrue(document.marked.isEmpty)
        model.suspend()
    }
    func testConfirmCommitsExactRawSpellingWithoutWaitingForCandidates() async throws {
        let document = WordLookupDocument()
        var settings = KeyboardSettings()
        settings.learnChoices = false; settings.predictions = false; settings.automaticClipboard = false
        let model = KeyboardModel(document: document, settings: settings) { engine, raw, preferred in
            Thread.sleep(forTimeInterval: 0.1)
            return engine.immediateCandidates(raw, preferred: preferred)
        }
        defer { model.suspend() }
        for raw in ["jhjhjhjh", "nihao", "xqzabc"] {
            for letter in raw { model.handle(.text(String(letter))) }
            let before = ProcessInfo.processInfo.systemUptime
            model.handle(.enter)
            XCTAssertLessThan((ProcessInfo.processInfo.systemUptime - before)*1000, 30)
            XCTAssertTrue(model.composition.isEmpty)
            XCTAssertTrue(document.before.hasSuffix(raw))
            XCTAssertTrue(document.marked.isEmpty)
        }
        let rawResult = document.before
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(document.before, rawResult, "Late candidates must not replace explicit raw confirmation")
        model.handle(.enter); XCTAssertEqual(document.before, rawResult + "\n")
    }
    func testContextualShortSpellingDoesNotWaitForTheWordLookupWorker() async throws {
        let document = WordLookupDocument(); document.before = "办公"
        let previousLookupStarted = expectation(description: "Previous word lookup reached j")
        let lookupStarted = expectation(description: "Context-free word lookup reached ji")
        let releasePreviousLookup = DispatchSemaphore(value: 0)
        let releaseLookup = DispatchSemaphore(value: 0)
        var settings = KeyboardSettings()
        settings.learnChoices = false; settings.predictions = false; settings.automaticClipboard = false
        let model = KeyboardModel(document: document, settings: settings) { engine, raw, preferred in
            if raw == "j" {
                previousLookupStarted.fulfill()
                _ = releasePreviousLookup.wait(timeout: .now() + 5)
            }
            if raw == "ji" {
                lookupStarted.fulfill()
                _ = releaseLookup.wait(timeout: .now() + 5)
            }
            return engine.immediateCandidates(raw, preferred: preferred)
        }
        defer { releasePreviousLookup.signal(); releaseLookup.signal(); model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        model.handle(.text("j"))
        await fulfillment(of: [previousLookupStarted], timeout: 2)
        model.prepare(.text("i")); releasePreviousLookup.signal()
        await fulfillment(of: [lookupStarted], timeout: 2)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(document.before, "办公j", "A held key cannot write the prospective spelling")
        model.handle(.text("i"))
        XCTAssertTrue(model.candidatesAreCurrent, "The decoded row must be ready while the independent word worker is blocked")
        XCTAssertFalse(model.candidates.isEmpty)
        XCTAssertEqual(model.candidateContext?.raw, "ji")
        let settled = model.candidates
        releaseLookup.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.candidates, settled, "The late context-free row cannot replace the contextual decision")
        print("CONTEXTUAL_PREPARATION heldKeyWrites=0 blockedWordWorker=true readyOnRelease=true lateDowngrade=false")
    }
    func testPreparingSpaceOrCancellingALetterCannotStrandAnUnfinishedSentence() async throws {
        let document = WordLookupDocument()
        var settings = KeyboardSettings()
        settings.learnChoices = false; settings.predictions = false; settings.automaticClipboard = false
        let model = KeyboardModel(document: document, settings: settings)
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for cancelLetter in [false, true] {
            for letter in "nichifankm" { model.handle(.text(String(letter))) }
            if cancelLetter {
                model.prepare(.text("a"))
                model.cancelPreparation()
            }
            model.prepare(.space); model.handle(.space); model.cancelPreparation()
            try await waitFor { model.composition.isEmpty }
            XCTAssertTrue(document.before.hasSuffix("你吃饭了吗"))
            XCTAssertFalse(document.before.hasSuffix("a"))
        }
    }
    func testSpaceStillSelectsChineseAndBrowsingLoadsMoreWithoutReordering() async throws {
        let document = WordLookupDocument()
        var settings = KeyboardSettings()
        settings.learnChoices = false; settings.predictions = false; settings.automaticClipboard = false
        let model = KeyboardModel(document: document, settings: settings)
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" }
        for letter in "hd" { model.handle(.text(String(letter))) }
        try await waitFor { model.candidatesAreCurrent }
        let firstPage = model.candidates, context = model.candidateContext
        XCTAssertEqual(firstPage.first?.text, "好的")
        model.candidateInteractionChanged(true)
        model.loadMoreCandidates(context: context)
        try await waitFor { model.candidates.count > firstPage.count }
        XCTAssertEqual(Array(model.candidates.prefix(firstPage.count)), firstPage)
        model.loadMoreCandidates(context: context)
        try await waitFor { model.candidates.count > 24 }
        XCTAssertTrue(model.candidates.contains { $0.text == "很多" })
        XCTAssertTrue(model.candidates.contains { $0.text == "回答" })
        model.candidateInteractionChanged(false)
        model.handle(.space)
        XCTAssertEqual(document.before, "好的")
        XCTAssertTrue(model.composition.isEmpty)
        model.loadMoreCandidates(context: context)
        XCTAssertEqual(document.before, "好的", "A stale page request cannot re-open the composition")
    }
    func testWarmedLetterUpdatesOnlyInputAndHasCandidatesInTheSameTurn() async throws {
        let document = WordLookupDocument()
        var settings = KeyboardSettings()
        settings.learnChoices = false; settings.predictions = false; settings.automaticClipboard = false
        let model = KeyboardModel(document: document, settings: settings)
        defer { model.suspend() }
        try await waitFor { model.engineState == "离线就绪" && model.candidatesAreCurrent }
        var fullRenders = 0, inputRenders = 0
        model.onChange = { fullRenders += 1 }
        model.onInputChange = { inputRenders += 1 }
        model.handle(.text("d"))
        XCTAssertEqual(fullRenders, 0)
        XCTAssertEqual(inputRenders, 1)
        XCTAssertEqual(model.candidates.first?.text, "的")
        XCTAssertTrue(model.candidatesAreCurrent, "A warmed row requires no worker or UI queue turn at release")
        XCTAssertEqual(document.before, "d")
    }
    func testThousandsOfCandidatesKeepABoundedViewPoolAndAccessibleTail() async throws {
        let ribbon = CandidateScrollView()
        ribbon.frame = CGRect(x: 0, y: 0, width: 390, height: 44)
        let context = KeyboardModel.CandidateContext(raw: "hd", before: "hd", after: "", document: "field", language: .chinese)
        let items = (0..<4_000).map { Candidate(text: "候选\($0)", consumed: 2) }
        ribbon.update(items, context: context, arithmetic: false, accent: .systemTeal)
        try await waitFor { ribbon.accessibilityElements?.count == 4_000 }
        ribbon.layoutIfNeeded()
        XCTAssertEqual(ribbon.accessibilityElements?.count, 4_000)
        var selected: String?
        ribbon.onSelect = { candidate, _, _ in selected = candidate.text }
        for fraction: CGFloat in [0, 0.75, 0.25, 1, 0] {
            ribbon.contentOffset.x = (ribbon.contentSize.width - ribbon.bounds.width) * fraction
            ribbon.layoutIfNeeded()
            let controls = descendants(ribbon).compactMap { $0 as? UIButton }
            XCTAssertLessThanOrEqual(controls.count, 64)
            let visible = try XCTUnwrap(controls.first { !$0.isHidden && $0.frame.intersects(ribbon.bounds) })
            visible.sendActions(for: .touchUpInside)
            XCTAssertEqual(selected, items[visible.tag].text)
            XCTAssertTrue(ribbon.hitTest(CGPoint(x: ribbon.bounds.midX, y: 22), with: nil) === ribbon)
        }
        let tail = try XCTUnwrap(ribbon.accessibilityElements?.last as? UIAccessibilityElement)
        XCTAssertTrue(tail.accessibilityActivate())
        XCTAssertEqual(selected, "候选3999")
    }
    func testKeyCellMarginsHaveRenderedCoverageWithoutOverlappingHitAreas() throws {
        let key = try XCTUnwrap(KeyboardLayout.rows(page: .letters, uppercase: true, globe: false)
            .flatMap(\.keys).first { $0.action == .text("d") })
        let button = KeyButton(key: key)
        button.frame = CGRect(x: 0, y: 0, width: 40, height: 52); button.layoutIfNeeded()
        for style: UIUserInterfaceStyle in [.light, .dark] {
            button.overrideUserInterfaceStyle = style; button.apply(KeyboardSettings())
            var pixels = [UInt8](repeating: 0, count: 40 * 52 * 4)
            try pixels.withUnsafeMutableBytes { storage in
                let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 40, height: 52,
                    bitsPerComponent: 8, bytesPerRow: 40 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                button.layer.render(in: context)
            }
            XCTAssertFalse(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] == 0 })
            XCTAssertTrue(button.point(inside: CGPoint(x: 1, y: 1), with: nil))
            XCTAssertFalse(button.point(inside: CGPoint(x: -1, y: 1), with: nil))
        }
    }
}

@MainActor private final class KeyboardFrameProbe: NSObject {
    private var link: CADisplayLink?
    private var previous: CFTimeInterval?
    private(set) var gaps: [Double] = []
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        let rate = Float(UIScreen.main.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common); self.link = link
    }
    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let previous { gaps.append(now - previous) }; previous = now
    }
    func stop() { link?.invalidate(); link = nil }
}

@MainActor private final class WordLookupDocument: KeyboardDocument {
    var before = "", marked = ""
    var beforeMarkedWrite: (() -> Void)?
    var contextBefore: String { before }; var contextAfter: String { "" }
    let documentIdentity = UUID().uuidString
    var selectedText: String { "" }; var enterTitle: String { "换行" }
    var needsGlobe: Bool { false }; var fullAccess: Bool { false }
    var prefersEnglish: Bool { false }; var capitalization: UITextAutocapitalizationType { .none }
    func insert(_ text: String) { before += text }
    func commitMarkedText(_ text: String) { before = String(before.dropLast(marked.count)) + text; marked = "" }
    func setMarkedText(_ text: String) { beforeMarkedWrite?(); before = String(before.dropLast(marked.count)) + text; marked = text }
    func unmarkText() { marked = "" }
    func deleteBackward() { if !before.isEmpty { before.removeLast() } }
    func moveCursor(_ offset: Int) {}; func beginTrackpad() {}; func trackCursor(translation: CGPoint) {}
    func endTrackpad() {}; func nextKeyboard() {}
    func clearInput() -> DeletedInput? { nil }; func restoreInput(_ value: DeletedInput) -> Bool { false }
}

@MainActor private final class ProxyKeyboardController: KeyboardViewController {
    var proxy: UITextDocumentProxy?
    override var textDocumentProxy: UITextDocumentProxy { if let proxy { return proxy }; return super.textDocumentProxy }
}

// A generic proxy over actual UIKit UITextInput storage. The production SwiftUI
// TextField keeps its original delegate and binding; only transport notifications
// are injected by the test. This is not an out-of-process textDocumentProxy.
@MainActor private final class UIKitFieldDocumentProxy: NSObject, UITextDocumentProxy {
    let input: UIView & UITextInput
    let documentIdentifier = UUID()
    var insertedTexts: [String] = [], markedWrites: [String] = []
    var markedLimit: Int?
    var unmarkWrites = 0, deleteWrites = 0
    var onMutation: (() -> Void)?
    var hidesContext = false
    init(_ input: UIView & UITextInput) { self.input = input; super.init() }
    var text: String {
        guard let range = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument) else { return "" }
        return input.text(in: range) ?? ""
    }
    var markedText: String? { input.markedTextRange.flatMap { input.text(in: $0) } }
    var documentContextBeforeInput: String? {
        guard !hidesContext else { return nil }
        guard let selection = input.selectedTextRange,
              let range = input.textRange(from: input.beginningOfDocument, to: selection.start) else { return nil }
        return input.text(in: range)
    }
    var documentContextAfterInput: String? {
        guard !hidesContext else { return nil }
        guard let selection = input.selectedTextRange,
              let range = input.textRange(from: selection.end, to: input.endOfDocument) else { return nil }
        return input.text(in: range)
    }
    var selectedText: String? { input.selectedTextRange.flatMap { input.text(in: $0) } }
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { input.hasText }
    func insertText(_ text: String) { insertedTexts.append(text); input.insertText(text); onMutation?() }
    func deleteBackward() { deleteWrites += 1; input.deleteBackward(); onMutation?() }
    func setMarkedText(_ text: String, selectedRange: NSRange) {
        markedWrites.append(text)
        let accepted = markedLimit.map { String(text.prefix($0)) } ?? text
        let location = min(selectedRange.location, accepted.utf16.count)
        input.setMarkedText(accepted, selectedRange: NSRange(location: location, length: min(selectedRange.length, accepted.utf16.count - location))); onMutation?()
    }
    func unmarkText() { unmarkWrites += 1; input.unmarkText(); onMutation?() }
    func adjustTextPosition(byCharacterOffset offset: Int) {
        guard let selection = input.selectedTextRange,
              let position = input.position(from: selection.end, offset: offset) else { return }
        input.selectedTextRange = input.textRange(from: position, to: position); onMutation?()
    }
}

// A nil-context transport which does not implement replacement semantics for
// an empty marked-text call. This is an executable protocol counterexample,
// not a substitute for a new video from the actual remote-desktop client.
@MainActor private final class UnclearableMarkedDocumentProxy: NSObject, UITextDocumentProxy {
    var identity = UUID()
    var documentIdentifier: UUID { identity }
    var committed = "前文🙂", provisional = "", selection = ""
    var hidesContext = true
    var contextReads = 0
    var markedWrites: [String] = [], insertedTexts: [String] = []
    var unmarkWrites = 0, deleteWrites = 0
    var onMutation: (() -> Void)?
    var documentContextBeforeInput: String? { contextReads += 1; return hidesContext ? nil : committed }
    var documentContextAfterInput: String? { contextReads += 1; return hidesContext ? nil : "" }
    var selectedText: String? { contextReads += 1; return selection.isEmpty ? nil : selection }
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { !committed.isEmpty || !provisional.isEmpty }
    func insertText(_ text: String) {
        insertedTexts.append(text); committed += provisional + text
        provisional = ""; selection = ""; onMutation?()
    }
    func setMarkedText(_ text: String, selectedRange: NSRange) {
        markedWrites.append(text)
        if !text.isEmpty { provisional = text }
        onMutation?()
    }
    func unmarkText() {
        unmarkWrites += 1; committed += provisional; provisional = ""; onMutation?()
    }
    func deleteBackward() { deleteWrites += 1; if !committed.isEmpty { committed.removeLast() } }
    func adjustTextPosition(byCharacterOffset offset: Int) {}
}

// Protocol regression for a remote-style editor which buffers marked spelling
// and flushes that buffer if insertText arrives before an explicit empty mark.
// This intentionally models the reported ordering failure; it is not evidence
// that a particular desktop or third-party editor has been exercised.
@MainActor private final class BufferedMarkedDocumentProxy: NSObject, UITextDocumentProxy {
    var identity = UUID()
    var documentIdentifier: UUID { identity }
    var committed = "前文🙂", marked = ""
    var insertedTexts: [String] = [], events: [String] = []
    var unmarkWrites = 0, deleteWrites = 0
    var onEmptyMarked: (() -> Void)?
    var hidesContext = false
    var onMutation: (() -> Void)?
    var documentContextBeforeInput: String? { hidesContext ? nil : committed }
    var documentContextAfterInput: String? { hidesContext ? nil : "" }
    var selectedText: String? { nil }
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { !committed.isEmpty || !marked.isEmpty }
    func insertText(_ text: String) {
        events.append("insert:" + text); insertedTexts.append(text)
        committed += marked + text; marked = ""; onMutation?()
    }
    func setMarkedText(_ text: String, selectedRange: NSRange) {
        events.append("mark:" + text); marked = text
        if text.isEmpty { onEmptyMarked?() }
        onMutation?()
    }
    func unmarkText() { unmarkWrites += 1; events.append("unmark"); committed += marked; marked = "" }
    func deleteBackward() { deleteWrites += 1; if !committed.isEmpty { committed.removeLast() } }
    func adjustTextPosition(byCharacterOffset offset: Int) {}
}

// Drive the production controller with real UIKit text storage. This checks
// marked-range replacement independently of the delayed-proxy test double.
@MainActor private final class UIKitDocumentProxy: NSObject, UITextDocumentProxy {
    let textView = UITextView()
    let documentIdentifier = UUID()
    var markedWrites: [String] = [], insertedTexts: [String] = []
    var unmarkWrites = 0, deleteWrites = 0
    var afterInsert: (() -> Void)?
    override init() {
        super.init(); textView.inputView = UIView(frame: .zero)
        textView.autocorrectionType = .no; textView.spellCheckingType = .no
    }
    var documentContextBeforeInput: String? {
        (textView.text as NSString).substring(to: textView.selectedRange.location)
    }
    var documentContextAfterInput: String? {
        (textView.text as NSString).substring(from: NSMaxRange(textView.selectedRange))
    }
    var selectedText: String? { textView.selectedTextRange.flatMap { textView.text(in: $0) } }
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { textView.hasText }
    func insertText(_ text: String) { insertedTexts.append(text); textView.insertText(text); afterInsert?() }
    func deleteBackward() { deleteWrites += 1; textView.deleteBackward() }
    func setMarkedText(_ text: String, selectedRange: NSRange) {
        markedWrites.append(text); textView.setMarkedText(text, selectedRange: selectedRange)
    }
    func unmarkText() { unmarkWrites += 1; textView.unmarkText() }
    func adjustTextPosition(byCharacterOffset offset: Int) {
        guard let selection = textView.selectedTextRange,
              let position = textView.position(from: selection.end, offset: offset) else { return }
        textView.selectedTextRange = textView.textRange(from: position, to: position)
    }
}

@MainActor private final class DelayedDocumentProxy: NSObject, UITextDocumentProxy {
    var before = "", after = "", selected = ""
    var visibleBefore: String?
    var beforeContextRead: (() -> Void)?
    var markedLength = 0
    var markedWrites: [String] = []
    var insertedTexts: [String] = []
    var unmarkWrites = 0
    var reads = 0
    var contextReads = 0
    var readDelay: TimeInterval = 0
    var contextReadDelay: TimeInterval?
    var omitsMarkedText = false
    var identity = UUID()
    private func read(context: Bool = true) {
        reads += 1; if context { contextReads += 1 }
        let delay = context ? (contextReadDelay ?? readDelay) : readDelay
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    }
    var documentContextBeforeInput: String? {
        read()
        let value = visibleBefore ?? (omitsMarkedText ? String(before.dropLast(min(markedLength, before.count))) : before)
        beforeContextRead?()
        return value
    }
    var documentContextAfterInput: String? { read(); return after }
    var selectedText: String? { read(); return selected.isEmpty ? nil : selected }
    var documentIdentifier: UUID { read(context: false); return identity }
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { !before.isEmpty || !after.isEmpty }
    func insertText(_ text: String) {
        insertedTexts.append(text)
        before = String(before.dropLast(min(markedLength, before.count))) + text
        selected = ""; markedLength = 0
    }
    func deleteBackward() { if !before.isEmpty { before.removeLast() }; markedLength = 0 }
    func setMarkedText(_ text: String, selectedRange: NSRange) {
        markedWrites.append(text)
        before = String(before.dropLast(min(markedLength, before.count))) + text; markedLength = text.count
    }
    func unmarkText() { unmarkWrites += 1; markedLength = 0 }
    func adjustTextPosition(byCharacterOffset offset: Int) {
        let text = before + after, index = max(0, min(text.count, before.count + offset))
        before = String(text.prefix(index)); after = String(text.dropFirst(index)); markedLength = 0
    }
}

