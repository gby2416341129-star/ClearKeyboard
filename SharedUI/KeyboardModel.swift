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
    var settings: KeyboardSettings { didSet { settings.sanitize(); store.save(settings); if clipboardActive { startClipboardCapture() }; onChange?() } }
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
    // Immediate dictionary results retain user-initiated priority. Expensive
    // grammar work yields CPU time to UIKit and those first-pass results.
    private let queue = DispatchQueue(label: "clear.candidates", qos: .utility)
    // Read-only CLX lookups must not page mapped dictionaries in on the UI thread.
    // Keep them independent of the serial sentence decoder so a long sentence
    // never holds up the next common-word lookup.
    private let wordQueue = DispatchQueue(label: "clear.words", qos: .userInitiated)
    private let wordLookup: (InputEngine, String, [Candidate]) -> [Candidate]
    private var work: DispatchWorkItem?
    private var wordWork: DispatchWorkItem?
    private var generation = 0
    private var candidateGeneration = -1
    private var resolvedGeneration = -1
    private var englishSnapshot = ""
    private var learned: [String: Int] = [:]
    private var personal = PersonalLexicon()
    private var learningEpoch: String?
    private var saveWork: DispatchWorkItem?
    private var lastShift = Date.distantPast
    private var manualShift = false
    private var cancellation = QueryCancellation()
    private let signpost = OSLog(subsystem: "app.clear.keyboard", category: .pointsOfInterest)

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
        cancellation.cancel(); work?.cancel(); generation += 1; candidates = []; arithmetic = nil
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
        switch action {
        case .text(let text):
            let possibleOperator = composition.isEmpty && text.count == 1 && "xX+-*/×÷().".contains(text)
            let mathCharacter = possibleOperator && document?.contextBefore.last.map({ $0.isNumber || $0 == ")" }) == true
            if mathCharacter {
                commitComposition(); document?.insert(text)
            } else if settings.language == .chinese && page == .letters && text.first?.isLetter == true {
                if !composition.append(text) { commitComposition(); _ = composition.append(text) }
                syncMarkedText()
            } else if settings.language == .chinese && text == "'" && !composition.isEmpty {
                _ = composition.append(text)
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
            if !composition.raw.isEmpty { composition.deleteBackward(); syncMarkedText() } else { document?.deleteBackward() }
        case .space:
            if composition.isEmpty { document?.insert(" ") } else { commitComposition(flushRemainder: false) }
        case .enter:
            if composition.isEmpty { document?.insert("\n") } else { commitComposition(flushRemainder: false) }
        case .page(let next): page = next
        case .globe: commitComposition(); document?.nextKeyboard()
        case .language: toggleLanguage(); return
        }
        refreshCandidates()
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
    func refreshCandidates() {
        guard !isMovingCursor else { return }
        generation += 1; let requestedGeneration = generation
        cancellation.cancel(); let token = QueryCancellation(); cancellation = token
        work?.cancel(); wordWork?.cancel(); candidateGeneration = -1
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
        onChange?()
        if arithmetic != nil { candidateGeneration = requestedGeneration; return }
        guard let engine, document != nil, selectionIsEmpty else { return }
        englishSnapshot = context
        if settings.language == .chinese, !raw.isEmpty {
            let lookup = wordLookup
            let words = DispatchWorkItem { [weak self] in
                guard !token.isCancelled else { return }
                let immediate = lookup(engine, raw, preferred)
                guard !token.isCancelled, !immediate.isEmpty else { return }
                DispatchQueue.main.async {
                    guard let self, self.generation == requestedGeneration,
                          self.resolvedGeneration != requestedGeneration else { return }
                    self.candidates = immediate; self.candidateGeneration = requestedGeneration
                    self.candidateContext = queryContext; self.notifyCandidates()
                    self.completeDeferredActions(for: queryContext)
                }
            }
            wordWork = words; wordQueue.async(execute: words)
        }
        let job = DispatchWorkItem(qos: .utility, flags: .enforceQoS) { [weak self] in
            guard !token.isCancelled else { return }
            let result: [Candidate]
            if settings.language == .chinese {
                result = raw.isEmpty ? (settings.predictions ? engine.predictions(after: context) : []) : engine.candidates(raw, fuzzy: settings.fuzzyPairs, learned: settings.learnChoices ? learned : [:], preferred: preferred, cancelled: { token.isCancelled })
            } else {
                let word = EnglishContext.word(in: context)
                result = word.isEmpty ? (settings.predictions ? engine.englishPredictions(after: context) : []) : engine.englishCandidates(prefix: word)
            }
            guard !token.isCancelled else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == requestedGeneration else { return }
                self.candidates = result; self.candidateGeneration = requestedGeneration
                self.resolvedGeneration = requestedGeneration
                self.candidateContext = queryContext; self.notifyCandidates()
                self.completeDeferredActions(for: queryContext)
            }
        }
        // Cancellation is checked on the serial worker before entering Rime.
        // An unconditional timer added a frame of latency even for ready words.
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
        guard epoch == learningEpoch else { learned = [:]; personal = PersonalLexicon(); learningEpoch = epoch; return }
        store.defaults.set(learned, forKey: "clear.learned.v1")
        if let data = try? JSONEncoder().encode(personal) { store.defaults.set(data, forKey: "clear.choices.v2") }
    }
    func suspend() { stopClipboardCapture(); work?.cancel(); wordWork?.cancel(); cancellation.cancel(); generation += 1; awaitingCommit = false; deferredContext = nil; deferredActions = []; flushLearning() }
}

private final class QueryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
