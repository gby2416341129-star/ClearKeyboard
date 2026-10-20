import UIKit
import os

@MainActor protocol KeyboardDocument: AnyObject {
    var contextBefore: String { get }
    var contextAfter: String { get }
    var documentIdentity: String { get }
    var selectedText: String { get }
    var enterTitle: String { get }
    var needsGlobe: Bool { get }
    var fullAccess: Bool { get }
    var prefersEnglish: Bool { get }
    var capitalization: UITextAutocapitalizationType { get }
    func insert(_ text: String)
    func deleteBackward()
    func moveCursor(_ offset: Int)
    func beginTrackpad()
    func trackCursor(translation: CGPoint)
    func endTrackpad()
    func nextKeyboard()
    func setMarkedText(_ text: String)
    func unmarkText()
    func clearInput() -> DeletedInput?
    func restoreInput(_ value: DeletedInput) -> Bool
    func validateCandidate(before: String, after: String, identity: String) -> Bool
    func candidateInteractionChanged(_ active: Bool)
    func keyInteractionChanged(_ active: Bool)
}

extension KeyboardDocument {
    func candidateInteractionChanged(_ active: Bool) {}
    func keyInteractionChanged(_ active: Bool) {}
    func validateCandidate(before: String, after: String, identity: String) -> Bool {
        selectedText.isEmpty && documentIdentity == identity && contextBefore == before && contextAfter == after
    }
}

struct DeletedInput { let text: String; let selection: NSRange }

@MainActor final class KeyboardModel {
    struct CandidateContext: Equatable {
        let raw: String; let before: String; let after: String
        let document: String; let language: InputLanguage
    }
    private(set) var candidateContext: CandidateContext?
    private var requestedContext: CandidateContext?
    private var awaitingCommit = false
    private var deferredContext: CandidateContext?
    private var deferredActions: [KeyAction] = []
    weak var document: KeyboardDocument?
    var settings: KeyboardSettings { didSet { settings.sanitize(); discardPreparedCandidates(); candidateCacheEpoch += 1; candidateCache = [:]; candidateCacheOrder = []; store.save(settings); if clipboardActive { startClipboardCapture() }; onChange?() } }
    private(set) var page: KeyboardPage = .letters
    private(set) var shifted = false
    private(set) var capsLocked = false
    private(set) var composition = Composition()
    private(set) var candidates: [Candidate] = []
    private(set) var arithmetic: ArithmeticResult?
    private(set) var isMovingCursor = false
    private var deletionUndo: (DeletedInput, String, String, String, Composition)?
    var canUndoClearInput: Bool { deletionUndo != nil }
    var candidatesAreCurrent: Bool { candidateGeneration == generation }
    private(set) var engineState = "离线词库加载中…"
    var onChange: (() -> Void)?
    var onCandidatesChange: (() -> Void)?
    private func notifyCandidates() { if let onCandidatesChange { onCandidatesChange() } else { onChange?() } }
    let clipboardCapture = ClipboardCapture()
    private var clipboardActive = false
    private var store: SettingsStore
    private var engine: InputEngine?
    // One serial engine owner; full correction is only launched after a typing
    // gap. Normal sentence candidates never wait for a debounce timer.
    private let queue = DispatchQueue(label: "clear.candidates", qos: .userInitiated, autoreleaseFrequency: .workItem)
    // Read-only CLX lookups must not page mapped dictionaries in on the UI thread.
    // Keep them independent of the serial sentence decoder so a long sentence
    // never holds up the next common-word lookup.
    private let wordQueue = DispatchQueue(label: "clear.words", qos: .userInitiated)
    private let wordLookup: (InputEngine, String, [Candidate]) -> [Candidate]
    private var work: DispatchWorkItem?
    private var preparedCandidates: PreparedCandidates?
    private var activeCandidates: PreparedCandidates?
    private var presentedRevision = 0
    private var candidateCache: [String: PreparedCandidates.Result] = [:]
    private var candidateCacheOrder: [String] = []
    private var candidateCacheEpoch = 0
    private var refinementWork: DispatchWorkItem?
    private var refinementCancellation = QueryCancellation()
    private var generation = 0
    private var candidateGeneration = -1
    private var englishSnapshot = ""
    private var learned: [String: Int] = [:]
    private var personal = PersonalLexicon()
    private var learningEpoch: String?
    private var saveWork: DispatchWorkItem?
    private var lastShift = Date.distantPast
    private var manualShift = false
    private var cancellation = QueryCancellation()
    private let signpost = OSLog(subsystem: "app.clear.keyboard", category: .pointsOfInterest)

    func candidateInteractionChanged(_ active: Bool) {
        document?.candidateInteractionChanged(active)
        if active {
            // Browsing a stable snapshot takes precedence over speculative work.
            // Do not restart correction between two opposite flicks.
            refinementCancellation.cancel(); refinementWork?.cancel()
            discardPreparedCandidates()
            if !awaitingCommit, candidatesAreCurrent { activeCandidates?.token.cancel() }
        }
    }

    // Begin work during the contact, without changing the document or the row.
    // A cancelled key is still cancelled; only handle(_:) commits the spelling.
    func prepare(_ action: KeyAction) {
        refinementCancellation.cancel(); refinementWork?.cancel()
        guard !awaitingCommit, !isMovingCursor, settings.language == .chinese,
              page == .letters else { return }
        var next = composition
        switch action {
        case .text(let text) where text.first?.isLetter == true || (text == "'" && !next.isEmpty):
            let math = next.isEmpty && text.count == 1 && "xX".contains(text) &&
                document?.contextBefore.last.map { $0.isNumber || $0 == ")" } == true
            guard !math, next.append(text) else { return }
        case .delete:
            next.deleteBackward()
        default: return
        }
        if !next.isEmpty { _ = prepareCandidates(for: next.raw) }
    }
    func cancelPreparation() { discardPreparedCandidates() }

    private func discardPreparedCandidates() {
        if preparedCandidates !== activeCandidates { preparedCandidates?.token.cancel() }
        preparedCandidates = nil
    }

    private func prepareCandidates(for raw: String) -> PreparedCandidates? {
        guard let engine, let document, !raw.isEmpty, document.selectedText.isEmpty else { return nil }
        let origin = CandidateContext(raw: "", before: document.contextBefore, after: document.contextAfter,
                                      document: document.documentIdentity, language: settings.language)
        if let query = preparedCandidates, query.raw == raw, query.generation == generation,
           query.origin == origin, !query.token.isCancelled { return query }
        discardPreparedCandidates()
        let query = PreparedCandidates(raw: raw, generation: generation, origin: origin, cacheEpoch: candidateCacheEpoch)
        preparedCandidates = query
        if let cached = candidateCache[raw] {
            query.publish(cached.items, stage: cached.stage)
            return query
        }
        let preferred = settings.learnChoices ? personal.candidates(for: raw) : []
        let learned = settings.learnChoices ? self.learned : [:], lookup = wordLookup
        wordQueue.async { [weak self] in
            guard !query.token.isCancelled else { return }
            let words = lookup(engine, raw, preferred)
            guard !words.isEmpty, !query.token.isCancelled else { return }
            query.publish(words, stage: 0)
            DispatchQueue.main.async { self?.presentCandidates(query) }
        }
        queue.async { [weak self] in
            guard !query.token.isCancelled else { return }
            let words = engine.candidates(raw, learned: learned, preferred: preferred,
                                          correction: false, cancelled: { query.token.isCancelled })
            guard !query.token.isCancelled else { return }
            query.publish(words, stage: 1)
            DispatchQueue.main.async { self?.presentCandidates(query) }
        }
        return query
    }

    private func presentCandidates(_ query: PreparedCandidates, notify: Bool = true) {
        guard activeCandidates === query, !query.token.isCancelled,
              let result = query.result, result.revision > presentedRevision else { return }
        presentedRevision = result.revision
        let changed = candidates != result.items || candidateContext != requestedContext
        candidates = result.items; candidateGeneration = generation; candidateContext = requestedContext
        if result.stage > 0 {
            if query.cacheEpoch == candidateCacheEpoch {
                if candidateCache[query.raw] == nil { candidateCacheOrder.append(query.raw) }
                candidateCache[query.raw] = result
                if candidateCacheOrder.count > 32 { candidateCache.removeValue(forKey: candidateCacheOrder.removeFirst()) }
            }
        }
        if notify {
            if changed { notifyCandidates() }
            completeDeferredActions(for: requestedContext)
        }
    }

    init(document: KeyboardDocument, settings: KeyboardSettings? = nil,
         wordLookup: @escaping (InputEngine, String, [Candidate]) -> [Candidate] = { $0.immediateCandidates($1, preferred: $2) }) {
        self.document = document
        self.wordLookup = wordLookup
        let defaults = SharedStorage.defaults(allowShared: document.fullAccess)
        store = SettingsStore(defaults: defaults)
        self.settings = settings ?? store.load()
        learned = defaults.dictionary(forKey: "clear.learned.v1") as? [String: Int] ?? [:]
        personal = defaults.data(forKey: "clear.choices.v2").flatMap { try? JSONDecoder().decode(PersonalLexicon.self, from: $0) } ?? PersonalLexicon()
        learningEpoch = defaults.string(forKey: "clear.learned.epoch")
        if document.prefersEnglish { self.settings.language = .english }
        queue.async { [weak self] in
            let result = Result { try InputEngine.bundled() }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let engine):
                    self.engine = engine; self.engineState = "离线就绪"; self.refreshCandidates()
                    self.resumeDeferredActions()
                case .failure: self.engineState = "词库不可用 · 可继续输入英文"; self.onChange?()
                }
            }
        }
    }
    func reloadSettings() {
        guard let document else { return }
        store = SettingsStore(defaults: SharedStorage.defaults(allowShared: document.fullAccess))
        settings = store.load()
        if document.prefersEnglish { settings.language = .english }
        learned = store.defaults.dictionary(forKey: "clear.learned.v1") as? [String: Int] ?? [:]
        personal = store.defaults.data(forKey: "clear.choices.v2").flatMap { try? JSONDecoder().decode(PersonalLexicon.self, from: $0) } ?? PersonalLexicon()
        learningEpoch = store.defaults.string(forKey: "clear.learned.epoch")
        refreshCandidates()
    }
    func clearComposition() {
        awaitingCommit = false; deferredContext = nil; deferredActions = []
        if !composition.raw.isEmpty { document?.setMarkedText(""); document?.unmarkText() }
        composition.clear(); refreshCandidates()
    }
    func cursorChanged() {
        guard !isMovingCursor else { return }
        awaitingCommit = false; deferredContext = nil; deferredActions = []
        deletionUndo = nil
        if !composition.raw.isEmpty { document?.unmarkText() }; composition.clear(); refreshCandidates()
    }
    func finishCompositionAsTyped() { if !composition.raw.isEmpty { document?.unmarkText() }; composition.clear() }
    private func syncMarkedText() {
        document?.setMarkedText(composition.raw)
        if composition.raw.isEmpty { document?.unmarkText() }
    }
    func startClipboardCapture() {
        clipboardActive = true
        clipboardCapture.activate(settings: settings, allowed: document?.fullAccess == true)
    }
    func stopClipboardCapture() { clipboardActive = false; clipboardCapture.stop() }
    func moveCursor(_ offset: Int) {
        if !isMovingCursor { commitComposition() }
        document?.moveCursor(offset)
        if !isMovingCursor { refreshCandidates() }
    }
    func beginCursorMovement() {
        guard !isMovingCursor else { return }
        commitComposition(); isMovingCursor = true; deletionUndo = nil
        cancellation.cancel(); work?.cancel(); refinementCancellation.cancel(); refinementWork?.cancel()
        discardPreparedCandidates(); activeCandidates = nil
        generation += 1; candidates = []; arithmetic = nil
        document?.beginTrackpad()
    }
    func trackCursor(translation: CGPoint) { guard isMovingCursor else { return }; document?.trackCursor(translation: translation) }
    func endCursorMovement() { guard isMovingCursor else { return }; document?.endTrackpad(); isMovingCursor = false; refreshCandidates() }
    func clearInput() {
        guard let document else { return }
        awaitingCommit = false; deferredContext = nil; deferredActions = []
        let spelling = composition
        document.unmarkText(); composition.clear()
        if let deleted = document.clearInput() {
            deletionUndo = (deleted, document.documentIdentity, document.contextBefore, document.contextAfter, spelling)
        }
        refreshCandidates()
    }
    @discardableResult func undoClearInput() -> Bool {
        guard let document, let (deleted, identity, before, after, spelling) = deletionUndo,
              document.documentIdentity == identity, document.contextBefore == before,
              document.contextAfter == after, document.selectedText.isEmpty else { deletionUndo = nil; return false }
        deletionUndo = nil
        let restored = document.restoreInput(deleted)
        if restored, !spelling.raw.isEmpty, document.contextBefore.hasSuffix(spelling.raw) {
            for _ in spelling.raw { document.deleteBackward() }
            composition = spelling; syncMarkedText()
        }
        refreshCandidates(); return restored
    }
    func toggleLanguage() {
        commitComposition(); settings.language = settings.language == .chinese ? .english : .chinese
        page = .letters; shifted = false; capsLocked = false; manualShift = false; refreshCandidates()
    }
    func handle(_ action: KeyAction) {
        if awaitingCommit { deferredActions.append(action); return }
        if needsLatestCandidate(for: action), !candidatesAreCurrent, engine != nil {
            deferUntilCandidates(action); return
        }
        deletionUndo = nil
        let event = OSSignpostID(log: signpost)
        os_signpost(.begin, log: signpost, name: "KeyAction", signpostID: event)
        defer { os_signpost(.end, log: signpost, name: "KeyAction", signpostID: event) }
        var prepared: PreparedCandidates?
        switch action {
        case .text(let text):
            let possibleOperator = composition.isEmpty && text.count == 1 && "xX+-*/×÷().".contains(text)
            let mathCharacter = possibleOperator && document?.contextBefore.last.map({ $0.isNumber || $0 == ")" }) == true
            if mathCharacter {
                commitComposition(); document?.insert(text)
            } else if settings.language == .chinese && page == .letters && text.first?.isLetter == true {
                if !composition.append(text) { commitComposition(); _ = composition.append(text) }
                prepared = prepareCandidates(for: composition.raw)
                syncMarkedText()
            } else if settings.language == .chinese && text == "'" && !composition.isEmpty {
                _ = composition.append(text)
                prepared = prepareCandidates(for: composition.raw)
                syncMarkedText()
            } else {
                commitComposition()
                document?.insert(shifted && page == .letters ? text.uppercased() : punctuation(text))
                if !capsLocked { shifted = false; manualShift = false }
                if page != .letters && [".", ",", "?", "!"].contains(text) { page = .letters }
            }
        case .shift:
            if settings.language == .chinese { toggleLanguage(); return }
            let now = Date()
            if now.timeIntervalSince(lastShift) < 0.3 { capsLocked = true; shifted = true }
            else { shifted.toggle(); capsLocked = false }
            manualShift = true
            lastShift = now
        case .delete:
            if !composition.raw.isEmpty {
                composition.deleteBackward()
                prepared = prepareCandidates(for: composition.raw)
                syncMarkedText()
            } else { document?.deleteBackward() }
        case .space:
            if composition.isEmpty { document?.insert(" ") } else { commitComposition(flushRemainder: false) }
        case .enter:
            if composition.isEmpty { document?.insert("\n") } else { commitComposition(flushRemainder: false) }
        case .page(let next): page = next
        case .globe: commitComposition(); document?.nextKeyboard()
        case .language: toggleLanguage(); return
        }
        refreshCandidates(using: prepared)
    }
    private func punctuation(_ text: String) -> String {
        guard settings.language == .chinese else { return text }
        return [",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；", "(": "（", ")": "）" ][text] ?? text
    }
    func insertLiteral(_ text: String) { commitComposition(); document?.insert(text); refreshCandidates() }
    func chooseArithmetic(_ text: String) {
        guard let document, let arithmetic, arithmetic.candidates.contains(text),
              composition.isEmpty, document.selectedText.isEmpty, document.contextBefore.hasSuffix(arithmetic.expression) else { return }
        for _ in arithmetic.expression { document.deleteBackward() }
        document.insert(text); refreshCandidates()
    }
    private func commitComposition(flushRemainder: Bool = true) {
        guard !composition.isEmpty else { composition.clear(); return }
        let current = candidateGeneration == generation ? candidates.first : nil
        let fallback = current ?? engine?.candidates(composition.raw, fuzzy: settings.fuzzyPairs, learned: learned, compose: false).first
        if let candidate = fallback {
            let spelling = composition.raw
            document?.setMarkedText(candidate.text); document?.unmarkText(); composition.consume(candidate.consumed)
            // Preserve any spelling not covered by a partial candidate.
            if flushRemainder && !composition.isEmpty { document?.insert(composition.normalized) }
            learn(candidate, raw: spelling)
        } else { document?.setMarkedText(composition.normalized); document?.unmarkText() }
        if flushRemainder || fallback == nil { composition.clear() }
        else if !composition.raw.isEmpty { syncMarkedText() }
    }
    func choose(_ candidate: Candidate) {
        guard candidateGeneration == generation, candidates.contains(candidate), let document else { return }
        commitChoice(candidate, document: document)
    }
    private func activeCandidateContext() -> CandidateContext? {
        guard let document else { return nil }
        return CandidateContext(raw: composition.raw, before: document.contextBefore,
            after: document.contextAfter, document: document.documentIdentity, language: settings.language)
    }
    func acceptsCandidateContext(_ context: CandidateContext?) -> Bool {
        guard let context, document?.selectedText.isEmpty == true else { return false }
        return context == activeCandidateContext()
    }
    // Rendering uses the already captured snapshot. Remote proxy getters can
    // synchronously cross a process boundary; only a real tap revalidates them.
    func displaysCurrentCandidates(_ context: CandidateContext?) -> Bool {
        context != nil && context == requestedContext
    }
    func chooseDisplayed(_ candidate: Candidate, context: CandidateContext?) {
        guard !awaitingCommit, let context, let current = activeCandidateContext(), let document,
              document.selectedText.isEmpty else { return }
        var selected = candidate
        var learningRaw = context.raw
        if context != current {
            // A finger can reach a visible prefix word before sentence decoding
            // catches up with the next letters. Commit only that prefix and keep
            // the remaining spelling; never apply an old row to another field,
            // another cursor position, or a prediction from an empty composition.
            guard context.language == .chinese, current.language == .chinese,
                  !context.raw.isEmpty, current.raw.hasPrefix(context.raw),
                  candidate.consumed > 0, candidate.consumed <= FuzzyPinyin.normalize(context.raw).count,
                  context.document == current.document, context.after == current.after,
                  context.before.hasSuffix(context.raw), current.before.hasSuffix(current.raw),
                  context.before.dropLast(context.raw.count) == current.before.dropLast(current.raw.count) else { return }
            // A completed word may have been shown for an unfinished final
            // syllable (nih -> 你好). Consume letters subsequently typed inside
            // that same reading too, while retaining any following word.
            let old = FuzzyPinyin.normalize(context.raw), typed = composition.normalized
            let reading = FuzzyPinyin.normalize(candidate.reading)
            if candidate.consumed == old.count, reading.hasPrefix(old) {
                let consumed = reading.hasPrefix(typed) ? typed.count : (typed.hasPrefix(reading) ? reading.count : candidate.consumed)
                selected = Candidate(text: candidate.text, reading: candidate.reading, consumed: consumed, score: candidate.score)
            }
            var remainder = composition; remainder.consume(selected.consumed)
            learningRaw = String(composition.raw.dropLast(remainder.raw.count))
        }
        guard document.validateCandidate(before: current.before, after: current.after, identity: current.document) else { return }
        commitChoice(selected, document: document, learningRaw: learningRaw)
    }
    private func commitChoice(_ candidate: Candidate, document: KeyboardDocument, learningRaw: String? = nil) {
        if settings.language == .chinese {
            let spelling = learningRaw ?? composition.raw
            if composition.raw.isEmpty { document.insert(candidate.text) }
            else {
                document.setMarkedText(candidate.text); document.unmarkText()
                composition.consume(candidate.consumed)
                if !composition.raw.isEmpty { syncMarkedText() }
            }
            learn(candidate, raw: spelling)
        } else {
            guard document.selectedText.isEmpty, document.contextBefore == englishSnapshot else { refreshCandidates(); return }
            let word = EnglishContext.word(in: englishSnapshot)
            let output = EnglishContext.applyingCase(candidate.text, like: word)
            if candidate.consumed > 0 { for _ in word { document.deleteBackward() } }
            document.insert(output + " ")
        }
        refreshCandidates()
    }
    private func needsLatestCandidate(for action: KeyAction) -> Bool {
        guard settings.language == .chinese, !composition.isEmpty else { return false }
        if action == .delete { return false }
        if case .text(let text) = action, page == .letters,
           text.first?.isLetter == true || text == "'" { return false }
        return requestedContext != nil
    }
    private func deferUntilCandidates(_ action: KeyAction) {
        awaitingCommit = true; deferredContext = requestedContext; deferredActions.append(action)
        // Reuse the in-flight current query. Cancelling it and enqueuing the
        // identical sentence again used to stall space and every following key.
    }
    private func resumeDeferredActions() {
        guard !awaitingCommit else { return }
        deferredContext = nil
        let pending = deferredActions; deferredActions = []
        for action in pending { handle(action) }
    }
    func refreshCandidates() { refreshCandidates(using: nil) }
    private func refreshCandidates(using prepared: PreparedCandidates?) {
        guard !isMovingCursor else { return }
        if prepared == nil { discardPreparedCandidates() }
        generation += 1; let requestedGeneration = generation
        cancellation.cancel(); activeCandidates = nil; presentedRevision = 0
        let token = prepared?.token ?? QueryCancellation(); cancellation = token
        refinementCancellation.cancel(); refinementWork?.cancel()
        let refinementToken = QueryCancellation(); refinementCancellation = refinementToken
        work?.cancel(); candidateGeneration = -1
        let selectionIsEmpty = document?.selectedText.isEmpty == true
        let context = composition.isEmpty || settings.language == .english ? (document?.contextBefore ?? "") : ""
        arithmetic = composition.isEmpty && selectionIsEmpty ? InlineArithmetic.result(in: context) : nil
        if arithmetic != nil || engine == nil || !selectionIsEmpty { candidates = [] }
        if settings.language == .english && !capsLocked && !manualShift, let document {
            let trimmed = context.trimmingCharacters(in: .whitespaces)
            switch document.capitalization {
            case .allCharacters: shifted = settings.autoCapitalization
            case .words: shifted = settings.autoCapitalization && (context.isEmpty || context.last?.isWhitespace == true)
            case .sentences:
                shifted = settings.autoCapitalization && (context.isEmpty || context.last?.isNewline == true || (context.last?.isWhitespace == true && trimmed.last.map { ".!?。！？".contains($0) } == true))
            default: shifted = false
            }
        }
        let queryContext = selectionIsEmpty ? activeCandidateContext() : nil
        requestedContext = queryContext
        if arithmetic != nil { candidateGeneration = requestedGeneration; candidateContext = queryContext }
        let raw = composition.raw, settings = self.settings, learned = self.learned
        let preferred = settings.learnChoices ? personal.candidates(for: raw) : []
        // Explicit personal choices are already in memory. All dictionary reads,
        // including the small first-pass lookup, belong on a worker.
        if arithmetic == nil, selectionIsEmpty, settings.language == .chinese, !preferred.isEmpty {
            candidates = preferred; candidateGeneration = requestedGeneration; candidateContext = queryContext
        }
        if arithmetic != nil { candidateGeneration = requestedGeneration; onChange?(); return }
        guard let engine, document != nil, selectionIsEmpty else { onChange?(); return }
        englishSnapshot = context
        if settings.language == .chinese, !raw.isEmpty {
            guard let query = prepared ?? prepareCandidates(for: raw) else { onChange?(); return }
            activeCandidates = query; preparedCandidates = nil; cancellation = query.token
            // Read the worker's mailbox now, not another main-queue round trip
            // after the host write. A result ready at release shares this frame.
            presentCandidates(query, notify: false)
            onChange?()
            if candidatesAreCurrent { completeDeferredActions(for: queryContext) }
            guard activeCandidates === query, !query.token.isCancelled,
                  query.result?.stage != 2 else { return }
            let refinement = DispatchWorkItem(qos: .utility, flags: .enforceQoS) { [weak self] in
                let cancelled = { query.token.isCancelled || refinementToken.isCancelled }
                guard !cancelled() else { return }
                let result = engine.candidates(raw, fuzzy: settings.fuzzyPairs,
                    learned: settings.learnChoices ? learned : [:], preferred: preferred, cancelled: cancelled)
                guard !cancelled() else { return }
                query.publish(result, stage: 2)
                DispatchQueue.main.async {
                    guard !cancelled() else { return }
                    self?.presentCandidates(query)
                }
            }
            refinementWork = refinement
            // Typing and scrolling cancel this work before it enters Rime's
            // non-interruptible set_input. The first pass has no debounce.
            queue.asyncAfter(deadline: .now() + (raw.count > 16 ? 0.25 : 0.18), execute: refinement)
            return
        }
        onChange?()
        let job = DispatchWorkItem(qos: .userInitiated, flags: .enforceQoS) { [weak self] in
            guard !token.isCancelled else { return }
            let result: [Candidate]
            if settings.language == .chinese {
                result = raw.isEmpty ? (settings.predictions ? engine.predictions(after: context) : []) : engine.candidates(raw, learned: settings.learnChoices ? learned : [:], preferred: preferred, correction: false, cancelled: { token.isCancelled })
            } else {
                let word = EnglishContext.word(in: context)
                result = word.isEmpty ? (settings.predictions ? engine.englishPredictions(after: context) : []) : engine.englishCandidates(prefix: word)
            }
            guard !token.isCancelled else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == requestedGeneration else { return }
                self.candidates = result; self.candidateGeneration = requestedGeneration
                self.candidateContext = queryContext; self.notifyCandidates()
                self.completeDeferredActions(for: queryContext)
            }
        }
        work = job; queue.async(execute: job)
    }
    private func completeDeferredActions(for context: CandidateContext?) {
        guard awaitingCommit else { return }
        awaitingCommit = false
        if deferredContext == context { resumeDeferredActions() }
        else { deferredActions = []; deferredContext = nil }
    }
    private func learn(_ candidate: Candidate, raw: String) {
        guard settings.learnChoices else { return }
        candidateCacheEpoch += 1; candidateCache = [:]; candidateCacheOrder = []; discardPreparedCandidates()
        let text = candidate.text
        personal.record(candidate, for: raw)
        learned[text] = min(10_000, (learned[text] ?? 0) + 1)
        if learned.count > 512, let least = learned.min(by: { $0.value < $1.value })?.key { learned.removeValue(forKey: least) }
        saveWork?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.flushLearning() }
        saveWork = save; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: save)
    }
    func flushLearning() {
        saveWork?.cancel()
        let epoch = store.defaults.string(forKey: "clear.learned.epoch")
        guard epoch == learningEpoch else {
            learned = [:]; personal = PersonalLexicon(); learningEpoch = epoch
            candidateCacheEpoch += 1; candidateCache = [:]; candidateCacheOrder = []; discardPreparedCandidates()
            return
        }
        store.defaults.set(learned, forKey: "clear.learned.v1")
        if let data = try? JSONEncoder().encode(personal) { store.defaults.set(data, forKey: "clear.choices.v2") }
    }
    func suspend() { stopClipboardCapture(); work?.cancel(); cancellation.cancel(); discardPreparedCandidates(); activeCandidates = nil; refinementWork?.cancel(); refinementCancellation.cancel(); generation += 1; awaitingCommit = false; deferredContext = nil; deferredActions = []; flushLearning() }
}

/// Workers publish immutable results without waiting for UIKit's event loop.
/// A late word lookup cannot downgrade a decoded/corrected row.
private final class PreparedCandidates: @unchecked Sendable {
    struct Result { let items: [Candidate]; let stage: Int; let revision: Int }
    let raw: String
    let generation: Int
    let origin: KeyboardModel.CandidateContext
    let cacheEpoch: Int
    let token = QueryCancellation()
    private let lock = NSLock()
    private var stored: Result?
    init(raw: String, generation: Int, origin: KeyboardModel.CandidateContext, cacheEpoch: Int) {
        self.raw = raw; self.generation = generation; self.origin = origin; self.cacheEpoch = cacheEpoch
    }
    var result: Result? { lock.lock(); defer { lock.unlock() }; return stored }
    func publish(_ items: [Candidate], stage: Int) {
        lock.lock(); defer { lock.unlock() }
        guard stage >= (stored?.stage ?? -1) else { return }
        stored = Result(items: items, stage: stage, revision: (stored?.revision ?? 0) + 1)
    }
}

private final class QueryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
