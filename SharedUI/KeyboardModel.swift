import UIKit
import os

@MainActor protocol KeyboardDocument: AnyObject {
    var contextBefore: String { get }
    var contextAfter: String { get }
    var documentIdentity: String { get }
    var selectedText: String { get }
    var usesLocalPinyinComposition: Bool { get }
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
    func commitMarkedText(_ text: String)
    @discardableResult func commitMarkedText(_ text: String, remaining: String) -> Bool
    func unmarkText()
    func clearInput() -> DeletedInput?
    func restoreInput(_ value: DeletedInput) -> Bool
    func validateCandidate(before: String, after: String, identity: String) -> Bool
    func candidateInteractionChanged(_ active: Bool)
    func keyInteractionChanged(_ active: Bool)
}

extension KeyboardDocument {
    var usesLocalPinyinComposition: Bool { false }
    @discardableResult func commitMarkedText(_ text: String, remaining: String) -> Bool {
        commitMarkedText(text)
        if !remaining.isEmpty { setMarkedText(remaining) }
        return true
    }
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
        var characters: Bool = false
    }
    private(set) var candidateContext: CandidateContext?
    private var requestedContext: CandidateContext?
    private var awaitingCommit = false
    private var selectionRevision = 0
    private var deferredContext: CandidateContext?
    private var deferredActions: [KeyAction] = []
    private var deferredPreview: Composition?
    private var deferredVisibleContext: CandidateContext?
    private var documentEditDepth = 0
    private var drainingDocumentKeys = false
    private var pendingDocumentKeys: [(KeyAction, String)] = []
    private func beginDocumentEdit() { documentEditDepth += 1 }
    private func endDocumentEdit() {
        documentEditDepth -= 1
        guard documentEditDepth == 0, !drainingDocumentKeys, !pendingDocumentKeys.isEmpty else { return }
        drainingDocumentKeys = true
        defer { drainingDocumentKeys = false }
        while !pendingDocumentKeys.isEmpty {
            let (action, identity) = pendingDocumentKeys.removeFirst()
            if document?.documentIdentity == identity { handle(action) }
        }
    }
    weak var document: KeyboardDocument?
    var settings: KeyboardSettings { didSet {
        settings.sanitize()
        if settings != oldValue {
            if settings.language != oldValue.language { shiftState.reset(); manualShift = false }
            if settings.language != oldValue.language || settings.fuzzyPairs != oldValue.fuzzyPairs ||
                settings.learnChoices != oldValue.learnChoices {
                discardPreparedCandidates(); candidateCacheEpoch += 1; candidateCache = [:]; candidateCacheOrder = []
            }
            if settings.language != oldValue.language || settings.learnChoices != oldValue.learnChoices {
                phraseLearning.reset(); numericRun.reset()
            }
            if !loadingSavedSettings {
                store.save(settings)
                if AppearanceSnapshot(settings: settings) != AppearanceSnapshot(settings: oldValue) { appearanceLink?.publish(settings) }
            }
            if clipboardActive, settings.capturesClipboard != oldValue.capturesClipboard ||
                settings.clipboardLifetimeHours != oldValue.clipboardLifetimeHours { startClipboardCapture() }
            onChange?()
        }
    } }
    private(set) var page: KeyboardPage = .letters
    private(set) var characterSelectionMode = false
    func toggleCharacterSelection() {
        guard settings.language == .chinese, !composition.isEmpty, !awaitingCommit else { return }
        characterSelectionMode.toggle(); refreshCandidates()
    }
    private var shiftState = KeyboardShift()
    private(set) var shifted: Bool {
        get { shiftState.shifted }
        set { shiftState.shifted = newValue }
    }
    private(set) var capsLocked: Bool {
        get { shiftState.capsLocked }
        set { shiftState.capsLocked = newValue }
    }
    private(set) var composition = Composition()
    private(set) var candidates: [Candidate] = []
    private(set) var arithmetic: ArithmeticResult?
    private(set) var literalInputRevision = 0
    private(set) var isMovingCursor = false
    private var deletionUndo: (DeletedInput, String, String, String, Composition)?
    var canUndoClearInput: Bool { deletionUndo != nil }
    var candidatesAreCurrent: Bool { candidateGeneration == generation }
    private var automaticChoiceIsReady: Bool {
        guard candidatesAreCurrent else { return false }
        let raw = composition.normalized
        guard raw.utf8.count >= 3, raw.allSatisfy({ "bpmfdtnlgkhjqxrzcsyw".contains($0) }),
              (activeCandidates?.result?.stage ?? 1) == 0 else { return true }
        // A deliberate longer dictionary completion remains usable immediately.
        // Otherwise Space awaits the semantic row; a provisional frequency row
        // must not win merely because it arrived first.
        let syllables = candidates.first?.reading.split(separator: " ").count ?? 0
        return syllables > raw.utf8.count || (settings.learnChoices && personal.candidates(for: composition.raw).contains { $0.score >= 3 })
    }
    private(set) var engineState = "离线词库加载中…"
    var onChange: (() -> Void)?
    var onCandidatesChange: (() -> Void)?
    var onInputChange: (() -> Void)?
    private(set) var hasMoreCandidates = false
    private var loadingMoreCandidates = false
    private var browsedContext: CandidateContext?
    private func notifyCandidates() { if let onCandidatesChange { onCandidatesChange() } else { onChange?() } }
    let clipboardCapture = ClipboardCapture()
    private var clipboardActive = false
    private var store: SettingsStore
    private var loadingSavedSettings = false
    private var appearanceLink: AppearanceSettingsLink?
    private let suppliedDefaults: UserDefaults?
    private var engine: InputEngine?
    // One serial decoder owner. Common words have an independent memory/CLX
    // path; sentence enrichment starts in a typing gap or on explicit browsing.
    private let queue = DispatchQueue(label: "clear.candidates", qos: .userInitiated, autoreleaseFrequency: .workItem)
    // Read-only CLX lookups must not page mapped dictionaries in on the UI thread.
    // Keep them independent of the serial sentence decoder so a long sentence
    // never holds up the next common-word lookup.
    private let wordQueue = DispatchQueue(label: "clear.words", qos: .userInitiated)
    private let warmQueue = DispatchQueue(label: "clear.words.prefetch", qos: .utility)
    private let wordLookup: (InputEngine, String, [Candidate]) -> [Candidate]
    private let hotWords = HotWordCache()
    private let warmsWords: Bool
    private var work: DispatchWorkItem?
    private var preparedCandidates: PreparedCandidates?
    private var interruptedCandidates: PreparedCandidates?
    private var activeCandidates: PreparedCandidates?
    private var presentedRevision = 0
    private var candidateCache: [CandidateRequestKey: PreparedCandidates.Result] = [:]
    private var candidateCacheOrder: [CandidateRequestKey] = []
    private var candidateCacheEpoch = 0
    private var candidateBackendRevision = 0
    private var refinementWork: DispatchWorkItem?
    private var refinementCancellation = QueryCancellation()
    private var scheduledQuery: PreparedCandidates?
    private var scheduledLimit = 0
    private var scheduledStage = 0
    private var generation = 0
    private var candidateGeneration = -1
    private var englishSnapshot = ""
    var hasEnglishPrefix: Bool { settings.language == .english && !EnglishContext.word(in: englishSnapshot).isEmpty }
    // A clipboard preview can temporarily occupy the header. Space must never
    // confirm a hidden English prediction beneath it.
    var englishSpaceSelectionIsVisible = true
    private var learned: [String: Int] = [:]
    private var personal = PersonalLexicon()
    private var phraseLearning = PhraseLearning()
    private var numbers = NumericLexicon()
    private var numericRun = NumericInputRun()
    private var learningEpoch: String?
    private var saveWork: DispatchWorkItem?
    private var manualShift = false
    private var cancellation = QueryCancellation()
    private let signpost = OSLog(subsystem: "app.clear.keyboard", category: .pointsOfInterest)

    func candidateInteractionChanged(_ active: Bool) {
        document?.candidateInteractionChanged(active)
        if active {
            // Freeze order, not the result stream. New pages append after the
            // words the user has already seen.
            if candidatesAreCurrent { browsedContext = candidateContext }
            discardPreparedCandidates()
        }
    }

    func loadMoreCandidates(context: CandidateContext?) {
        guard hasMoreCandidates, !loadingMoreCandidates, acceptsCandidateContext(context),
              let query = activeCandidates, !query.token.isCancelled else { return }
        let previous = query.result
        let limit = min(4095, (previous?.stage ?? 0) == 0 ? 24 : (previous?.limit ?? 24) + 32)
        guard limit > (previous?.stage == 3 ? previous?.limit ?? 0 : 0) else { return }
        browsedContext = candidateContext; loadingMoreCandidates = true
        scheduleDecoder(query, limit: limit, stage: 3, correction: previous?.correction ?? false, delay: 0)
    }

    // Begin work during the contact, without changing the document or the row.
    // A cancelled key is still cancelled; only handle(_:) commits the spelling.
    func prepare(_ action: KeyAction) {
        guard !awaitingCommit, !isMovingCursor, !characterSelectionMode, settings.language == .chinese,
              page == .letters, !shifted else { return }
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
        // Only a possible spelling edit interrupts enrichment. In particular,
        // touching Space must leave the result it is about to commit running.
        interruptedCandidates = activeCandidates
        refinementCancellation.cancel(); refinementWork?.cancel()
        loadingMoreCandidates = false
        if !next.isEmpty { _ = prepareCandidates(for: next.raw) }
    }
    func cancelPreparation() {
        let interrupted = interruptedCandidates; interruptedCandidates = nil
        discardPreparedCandidates()
        // Sliding off a key cancels the edit, not the current composition's
        // ability to finish. A successful release has adopted a different query.
        if let interrupted, activeCandidates === interrupted, !candidatesAreCurrent {
            scheduleDecoder(interrupted, delay: 0)
        }
    }

    private func discardPreparedCandidates() {
        if preparedCandidates !== activeCandidates { preparedCandidates?.token.cancel() }
        preparedCandidates = nil
    }

    private func prepareCandidates(for raw: String) -> PreparedCandidates? {
        guard !characterSelectionMode, let engine, let document, !raw.isEmpty, document.selectedText.isEmpty else { return nil }
        let backend = CoreMLSentence.shared.revision
        if backend != candidateBackendRevision {
            candidateBackendRevision = backend; candidateCacheEpoch += 1
            candidateCache = [:]; candidateCacheOrder = []
        }
        let origin = CandidateContext(raw: "", before: document.contextBefore, after: document.contextAfter,
                                      document: document.documentIdentity, language: settings.language)
        if let query = preparedCandidates, query.raw == raw, query.generation == generation,
           query.origin == origin, !query.token.isCancelled { return query }
        discardPreparedCandidates()
        let preceding = CandidateLanguageContext.preceding(before: origin.before, markedDraft: composition.raw)
        let query = PreparedCandidates(raw: raw, generation: generation, origin: origin, cacheEpoch: candidateCacheEpoch, preceding: preceding)
        preparedCandidates = query
        if let cached = candidateCache[query.cacheKey] {
            query.publish(cached.items, stage: cached.stage, limit: cached.limit,
                          hasMore: cached.hasMore, correction: cached.correction)
            return query
        }
        let preferred = settings.learnChoices ? personal.candidates(for: raw) : []
        let immediateComposition = engine.hasImmediateComposition(raw)
        let lookup = wordLookup, cache = hotWords, warm = warmsWords
        let cachedWords = warm ? cache.value(raw) : nil
        if preferred.contains(where: { $0.score == 4 }) {
            // A learned initials alias is an explicit user mapping. It is safe
            // to publish from memory during this key, without a worker roundtrip.
            query.publish(Self.preferredWords(preferred, cachedWords ?? []), stage: 0)
        } else if let cachedWords, !cachedWords.isEmpty {
            query.publish(Self.preferredWords(preferred, cachedWords), stage: immediateComposition ? 1 : 0)
        }
        let job = DispatchWorkItem(qos: .userInitiated) { [weak self] in
            guard !query.token.isCancelled else { return }
            let words = cachedWords ?? lookup(engine, raw, warm ? [] : preferred)
            if warm { cache.put(raw, words) }
            query.wordLookupCompleted(empty: words.isEmpty)
            guard !query.token.isCancelled else { return }
            if !words.isEmpty { query.publish(Self.preferredWords(preferred, words), stage: immediateComposition ? 1 : 0) }
            DispatchQueue.main.async {
                guard let self, !query.token.isCancelled else { return }
                if self.preparedCandidates === query, self.activeCandidates !== query {
                    if words.isEmpty { self.scheduleDecoder(query, delay: 0) }
                    return
                }
                guard self.activeCandidates === query else { return }
                self.presentCandidates(query)
                guard self.activeCandidates === query, !query.token.isCancelled else { return }
                // Unknown spellings need the decoder immediately. A populated
                // word row can defer this work without delaying its first paint.
                if (query.result?.stage ?? 0) == 0 {
                    self.scheduleDecoder(query, delay: 0)
                }
            }

        }
        wordQueue.async(execute: job)
        let contextualShortSpelling = !preceding.isEmpty && raw.utf8.count <= 6
        if !immediateComposition, contextualShortSpelling ||
            (raw.utf8.count >= 3 && raw.allSatisfy({ "bpmfdtnlgkhjqxrzcsyw".contains($0) })) {
            // Start the semantic row at contact-down. It can finish while the
            // key is still held. A context-aware short spelling must not wait
            // for the independent, context-free word lookup to finish first.
            scheduleDecoder(query, delay: 0)
        }
        return query
    }

    nonisolated private static func preferredWords(_ preferred: [Candidate], _ words: [Candidate]) -> [Candidate] {
        PersonalLexicon.merging(preferred, into: words, limit: 8)
    }

    private func scheduleDecoder(_ query: PreparedCandidates, limit: Int = 8, stage: Int = 1,
                                 correction: Bool = true, delay: Double) {
        guard activeCandidates === query || preparedCandidates === query,
              !query.token.isCancelled, let engine else { return }
        // A late word callback for the old, still-visible spelling must not
        // cancel the prospective key's decoder. Cancelling the contact removes
        // this priority and explicitly resumes the interrupted current query.
        if let prepared = preparedCandidates, prepared !== query,
           activeCandidates === query, interruptedCandidates === query { return }
        // A quick-word miss may arrive after the same sentence query started.
        // Keep that work; cancelling and restarting it only adds latency.
        if scheduledQuery === query, scheduledLimit == limit, scheduledStage == stage,
           !refinementCancellation.isCancelled { return }
        refinementCancellation.cancel(); refinementWork?.cancel()
        let token = QueryCancellation(); refinementCancellation = token
        scheduledQuery = query; scheduledLimit = limit; scheduledStage = stage
        let raw = query.raw, settings = self.settings
        let preferred = settings.learnChoices ? personal.candidates(for: raw) : []
        let learned = settings.learnChoices ? self.learned : [:]
        let recent = settings.learnChoices ? personal.recentCorrections(for: raw) : []
        let job = DispatchWorkItem(qos: .userInitiated) { [weak self] in
            let cancelled = { query.token.isCancelled || token.isCancelled }
            guard !cancelled() else { return }
            let result = engine.candidates(raw, fuzzy: correction ? settings.fuzzyPairs : [],
                learned: learned, preferred: preferred, recentCorrections: recent, limit: limit + 1,
                correction: correction, context: query.preceding, cancelled: cancelled)
            guard !cancelled() else { return }
            query.publish(Array(result.prefix(limit)), stage: stage, limit: limit,
                          hasMore: stage == 1 ? !result.isEmpty : (result.count > limit && limit < 4095),
                          correction: correction)
            DispatchQueue.main.async {
                guard let self, self.activeCandidates === query, !cancelled() else { return }
                self.loadingMoreCandidates = false
                self.presentCandidates(query)
            }
        }
        refinementWork = job
        if delay == 0 { queue.async(execute: job) }
        else { queue.asyncAfter(deadline: .now() + delay, execute: job) }
    }


    private func presentCandidates(_ query: PreparedCandidates, notify: Bool = true) {
        guard activeCandidates === query, !query.token.isCancelled,
              let result = query.result, result.revision > presentedRevision else { return }
        presentedRevision = result.revision
        var items = result.items
        if browsedContext != nil, browsedContext == requestedContext, candidateContext == requestedContext {
            var seen = Set(candidates.map(\.text))
            items = candidates + items.filter { seen.insert($0.text).inserted }
        }
        let changed = candidates != items || candidateContext != requestedContext || hasMoreCandidates != result.hasMore
        candidates = items; hasMoreCandidates = result.hasMore
        candidateGeneration = generation; candidateContext = requestedContext
        if result.stage > 0 && result.stage < 3 {
            if query.cacheEpoch == candidateCacheEpoch {
                if candidateCache[query.cacheKey] == nil { candidateCacheOrder.append(query.cacheKey) }
                candidateCache[query.cacheKey] = result
                if candidateCacheOrder.count > 32 { candidateCache.removeValue(forKey: candidateCacheOrder.removeFirst()) }
            }
        }
        if notify {
            if changed { notifyCandidates() }
            completeDeferredActions(for: requestedContext)
        }
    }

    init(document: KeyboardDocument, settings: KeyboardSettings? = nil, defaults: UserDefaults? = nil,
         wordLookup: ((InputEngine, String, [Candidate]) -> [Candidate])? = nil,
         appearanceLink: AppearanceSettingsLink? = nil) {
        self.document = document
        self.wordLookup = wordLookup ?? { $0.immediateCandidates($1, preferred: $2) }
        self.warmsWords = wordLookup == nil
        suppliedDefaults = defaults
        let defaults = defaults ?? SharedStorage.defaults(allowShared: document.fullAccess)
        store = SettingsStore(defaults: defaults)
        self.settings = settings ?? store.load()
        learned = defaults.dictionary(forKey: "clear.learned.v1") as? [String: Int] ?? [:]
        personal = defaults.data(forKey: "clear.choices.v2").flatMap { try? JSONDecoder().decode(PersonalLexicon.self, from: $0) } ?? PersonalLexicon()
        numbers = defaults.data(forKey: "clear.numbers.v1").flatMap { try? JSONDecoder().decode(NumericLexicon.self, from: $0) } ?? NumericLexicon()
        learningEpoch = defaults.string(forKey: "clear.learned.epoch")
        if document.prefersEnglish { self.settings.language = .english }
        self.appearanceLink = appearanceLink
        self.appearanceLink?.currentSettings = { [weak self] in self?.settings ?? KeyboardSettings() }
        self.appearanceLink?.onReceive = { [weak self] snapshot in
            guard let self else { return }
            let value = snapshot.applying(to: self.settings)
            self.loadingSavedSettings = true
            self.settings = value
            self.loadingSavedSettings = false
            // Keep the local fallback current without broadcasting the read.
            self.store.save(snapshot.applying(to: self.store.load()))
        }
        if document.fullAccess { self.appearanceLink?.activate() }
        let cache = hotWords, warm = warmsWords, prefetch = warmQueue
        queue.async { [weak self] in
            let result = Result { try InputEngine.bundled() }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let engine):
                    // Confirm can be pressed before engine startup completes.
                    // Rebase only to the exact context our queued-letter preview
                    // wrote, so loading cannot silently drop those later keys.
                    if self.awaitingCommit {
                        if self.deferredVisibleContext == self.activeCandidateContext() {
                            self.deferredContext = self.deferredVisibleContext
                        } else { self.cancelDeferredActions() }
                    }
                    self.engine = engine; self.engineState = "离线就绪"; self.refreshCandidates()
                    self.resumeDeferredActions()
                case .failure: self.cancelDeferredActions(); self.engineState = "词库不可用 · 可继续输入英文"; self.onChange?()
                }
            }
            if warm, case .success(let engine) = result {
                prefetch.async {
                    for letter in "abcdefghijklmnopqrstuvwxyz" {
                        let raw = String(letter)
                        if cache.value(raw) == nil { cache.put(raw, engine.immediateCandidates(raw)) }
                    }
                }
            }
        }
    }
    func reloadSettings() {
        guard let document else { return }
        store = SettingsStore(defaults: suppliedDefaults ?? SharedStorage.defaults(allowShared: document.fullAccess))
        phraseLearning.reset(); numericRun.reset()
        var saved = store.load()
        if document.prefersEnglish { saved.language = .english }
        loadingSavedSettings = true
        settings = saved
        loadingSavedSettings = false
        learned = store.defaults.dictionary(forKey: "clear.learned.v1") as? [String: Int] ?? [:]
        personal = store.defaults.data(forKey: "clear.choices.v2").flatMap { try? JSONDecoder().decode(PersonalLexicon.self, from: $0) } ?? PersonalLexicon()
        numbers = store.defaults.data(forKey: "clear.numbers.v1").flatMap { try? JSONDecoder().decode(NumericLexicon.self, from: $0) } ?? NumericLexicon()
        learningEpoch = store.defaults.string(forKey: "clear.learned.epoch")
        refreshCandidates()
        refreshAppearanceConnection()
    }
    func refreshAppearanceConnection() {
        appearanceLink?.updateFullAccess(document?.fullAccess == true)
        if document?.fullAccess == true { appearanceLink?.activate() } else { appearanceLink?.deactivate() }
    }
    func clearComposition() {
        beginDocumentEdit(); defer { endDocumentEdit() }
        cancelDeferredActions()
        phraseLearning.reset(); numericRun.reset()
        if !composition.raw.isEmpty { document?.setMarkedText(""); document?.unmarkText() }
        composition.clear(); refreshCandidates()
    }
    func cursorChanged(unmarkDraft: Bool = true) {
        beginDocumentEdit(); defer { endDocumentEdit() }
        guard !isMovingCursor else { return }
        if !unmarkDraft { pendingDocumentKeys.removeAll() }
        cancelDeferredActions()
        deletionUndo = nil
        phraseLearning.reset(); finishNumericRun()
        if unmarkDraft, !composition.raw.isEmpty { document?.unmarkText() }; composition.clear(); refreshCandidates()
    }
    func finishCompositionAsTyped() {
        beginDocumentEdit(); defer { endDocumentEdit() }
        cancelDeferredActions()
        phraseLearning.reset()
        if !composition.raw.isEmpty { document?.unmarkText() }; composition.clear()
    }
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
        beginDocumentEdit(); defer { endDocumentEdit() }
        if !isMovingCursor { if awaitingCommit { finishCompositionAsTyped() } else { commitComposition() } }
        phraseLearning.reset(); finishNumericRun()
        document?.moveCursor(offset)
        if !isMovingCursor { refreshCandidates() }
    }
    func beginCursorMovement() {
        beginDocumentEdit(); defer { endDocumentEdit() }
        guard !isMovingCursor else { return }
        if awaitingCommit { finishCompositionAsTyped() } else { commitComposition() }
        phraseLearning.reset(); finishNumericRun()
        isMovingCursor = true; deletionUndo = nil
        cancellation.cancel(); work?.cancel(); refinementCancellation.cancel(); refinementWork?.cancel()
        discardPreparedCandidates(); activeCandidates = nil
        generation += 1; candidates = []; arithmetic = nil
        document?.beginTrackpad()
    }
    func trackCursor(translation: CGPoint) {
        beginDocumentEdit(); defer { endDocumentEdit() }
        guard isMovingCursor else { return }; document?.trackCursor(translation: translation)
    }
    func endCursorMovement() {
        beginDocumentEdit(); defer { endDocumentEdit() }
        guard isMovingCursor else { return }; document?.endTrackpad(); isMovingCursor = false; refreshCandidates()
    }
    func clearInput() {
        beginDocumentEdit(); defer { endDocumentEdit() }
        guard let document else { return }
        cancelDeferredActions()
        phraseLearning.reset(); numericRun.reset()
        let spelling = composition
        document.unmarkText(); composition.clear()
        if let deleted = document.clearInput() {
            deletionUndo = (deleted, document.documentIdentity, document.contextBefore, document.contextAfter, spelling)
        }
        refreshCandidates()
    }
    @discardableResult func undoClearInput() -> Bool {
        beginDocumentEdit(); defer { endDocumentEdit() }
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
        beginDocumentEdit(); defer { endDocumentEdit() }
        finishNumericRun()
        if awaitingCommit { finishCompositionAsTyped() } else { commitComposition() }
        settings.language = settings.language == .chinese ? .english : .chinese
        page = .letters; shiftState.reset(); manualShift = false; refreshCandidates()
    }
    func handle(_ action: KeyAction) {
        // Remote editor calls may service another UIKit key callback before
        // returning. Finish the current edit before applying that later key;
        // otherwise its spelling can be cleared or consumed by the old choice.
        if documentEditDepth > 0 {
            pendingDocumentKeys.append((action, document?.documentIdentity ?? "")); return
        }
        beginDocumentEdit(); defer { endDocumentEdit() }
        if awaitingCommit {
            deferredActions.append(action)
            // Keep letters visible while an earlier Space awaits decoding. The
            // original composition still owns the conversion; replay replaces
            // this one marked preview and then applies the queued suffix once.
            if var preview = deferredPreview {
                switch action {
                case .text(let text) where text.first?.isLetter == true || text == "'":
                    if preview.append(text) {
                        deferredPreview = preview; document?.setMarkedText(composition.raw + preview.raw)
                        deferredVisibleContext = activeCandidateContext()
                    }
                case .delete where !preview.raw.isEmpty:
                    preview.deleteBackward(); deferredPreview = preview
                    document?.setMarkedText(composition.raw + preview.raw)
                    deferredVisibleContext = activeCandidateContext()
                default: deferredPreview = nil
                }
            }
            return
        }
        if needsLatestCandidate(for: action), !automaticChoiceIsReady {
            deferUntilCandidates(action); return
        }
        if action != .shift { shiftState.interruptTapSequence() }
        deletionUndo = nil
        let event = OSSignpostID(log: signpost)
        os_signpost(.begin, log: signpost, name: "KeyAction", signpostID: event)
        defer { os_signpost(.end, log: signpost, name: "KeyAction", signpostID: event) }
        var prepared: PreparedCandidates?
        var inputOnly = false
        switch action {
        case .literal(let text):
            commitComposition(); insertText(text)
            if !capsLocked { shifted = false; manualShift = false }
        case .text(let text):
            let possibleOperator = composition.isEmpty && text.count == 1 && "xX+-*/×÷().".contains(text) &&
                !(shifted && page == .letters && text.first?.isLetter == true)
            let mathCharacter = possibleOperator && document?.contextBefore.last.map({ $0.isNumber || $0 == ")" }) == true
            if mathCharacter {
                commitComposition(); insertText(text)
            } else if settings.language == .chinese && page == .letters && !shifted && text.first?.isLetter == true {
                finishNumericRun()
                _ = composition.append(text)
                prepared = prepareCandidates(for: composition.raw)
                inputOnly = true; syncMarkedText()
            } else if settings.language == .chinese && text == "'" && !composition.isEmpty {
                _ = composition.append(text)
                prepared = prepareCandidates(for: composition.raw)
                inputOnly = true; syncMarkedText()
            } else {
                commitComposition()
                insertText(shifted && page == .letters ? text.uppercased() : punctuation(text))
                if !capsLocked { shifted = false; manualShift = false }
                if page != .letters && [".", ",", "?", "!", "。", "，", "？", "！"].contains(text) { page = .letters }
            }
        case .shift:
            shiftState.tap(now: ProcessInfo.processInfo.systemUptime)
            manualShift = true
            if settings.language == .chinese {
                // Changing case neither commits nor restarts the Chinese draft.
                // The next uppercase literal uses the normal ordered commit path.
                discardPreparedCandidates(); onChange?(); return
            }
        case .delete:
            phraseLearning.reset()
            if !composition.raw.isEmpty {
                composition.deleteBackward()
                prepared = prepareCandidates(for: composition.raw)
                inputOnly = true; syncMarkedText()
            } else {
                if let document, document.selectedText.isEmpty {
                    numericRun.delete(before: document.contextBefore, after: document.contextAfter, document: document.documentIdentity)
                } else { numericRun.reset() }
                document?.deleteBackward()
                literalInputRevision += 1
            }
        case .space:
            if settings.language == .english, englishSpaceSelectionIsVisible, candidatesAreCurrent,
               let candidate = candidates.first, let document,
               document.selectedText.isEmpty, document.contextBefore == englishSnapshot {
                commitChoice(candidate, document: document)
                return
            }
            if composition.isEmpty { insertText(" ") } else { commitComposition(flushRemainder: false) }
        case .enter:
            if composition.isEmpty { insertText("\n") } else { finishCompositionAsTyped() }
        case .page(let next): page = next
        case .globe: commitComposition(); finishNumericRun(); phraseLearning.reset(); document?.nextKeyboard()
        case .language: toggleLanguage(); return
        }
        refreshCandidates(using: prepared, inputOnly: inputOnly)
    }
    private func punctuation(_ text: String) -> String {
        guard settings.language == .chinese else { return text }
        return [",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；", "(": "（", ")": "）" ][text] ?? text
    }
    func beginClipboardSelection() -> ClipboardTextSession? {
        beginDocumentEdit(); defer { endDocumentEdit() }
        if awaitingCommit { finishCompositionAsTyped() } else { commitComposition() }
        guard let document, document.selectedText.isEmpty else { return nil }
        return ClipboardTextSession(document: document)
    }
    @discardableResult func updateClipboardSelection(_ session: ClipboardTextSession, text: String) -> Bool {
        beginDocumentEdit(); defer { endDocumentEdit() }
        let updated = session.apply(text)
        if updated { refreshCandidates() }
        return updated
    }
    func insertLiteral(_ text: String) {
        beginDocumentEdit(); defer { endDocumentEdit() }
        if awaitingCommit { finishCompositionAsTyped() } else { commitComposition() }
        insertText(text); refreshCandidates()
    }
    func chooseArithmetic(_ text: String) {
        beginDocumentEdit(); defer { endDocumentEdit() }
        guard let document, let arithmetic, arithmetic.candidates.contains(text),
              composition.isEmpty, document.selectedText.isEmpty, document.contextBefore.hasSuffix(arithmetic.expression) else { return }
        numericRun.reset(); phraseLearning.reset()
        for _ in arithmetic.expression { document.deleteBackward() }
        document.insert(text); refreshCandidates()
    }
    private func commitComposition(flushRemainder: Bool = true) {
        guard !composition.isEmpty else { composition.clear(); return }
        let current = candidateGeneration == generation ? candidates.first : nil
        // Gestures and language changes can commit before decoding finishes.
        // Never enter any dictionary or mutable decoder from the UI thread.
        let fallback = current ?? hotWords.value(composition.raw)?.first
        if let candidate = fallback {
            let spelling = composition.raw
            let phrase = trackPhrase(candidate)
            composition.consume(candidate.consumed)
            // Preserve any spelling not covered by a partial candidate.
            let output = candidate.text + (flushRemainder ? composition.normalized : "")
            if document?.commitMarkedText(output, remaining: flushRemainder ? "" : composition.raw) == true {
                learn(candidate, raw: spelling, phrase: phrase)
            }
        } else { document?.commitMarkedText(composition.normalized); phraseLearning.reset() }
        if flushRemainder { phraseLearning.reset() }
        if flushRemainder || fallback == nil { composition.clear() }
    }
    func choose(_ candidate: Candidate) {
        guard candidateGeneration == generation, candidates.contains(candidate), let document else { return }
        commitChoice(candidate, document: document)
    }
    private func activeCandidateContext() -> CandidateContext? {
        guard let document else { return nil }
        return CandidateContext(raw: composition.raw, before: document.contextBefore,
            after: document.contextAfter, document: document.documentIdentity, language: settings.language,
            characters: characterSelectionMode)
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
        guard documentEditDepth == 0 else { return }
        selectionRevision += 1
        chooseDisplayed(candidate, context: context, retry: 0)
    }
    private func chooseDisplayed(_ candidate: Candidate, context: CandidateContext?, retry: Int) {
        beginDocumentEdit(); defer { endDocumentEdit() }
        guard !awaitingCommit, !isMovingCursor, let context, let current = activeCandidateContext(), let document,
              document.selectedText.isEmpty else { return }
        var selected = candidate
        var learningRaw = context.raw
        if context != current {
            // A finger can reach a visible prefix word before sentence decoding
            // catches up with the next letters. Commit only that prefix and keep
            // the remaining spelling; never apply an old row to another field,
            // another cursor position, or a prediction from an empty composition.
            guard context.language == .chinese, current.language == .chinese,
                  context.characters == current.characters,
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
        guard document.validateCandidate(before: current.before, after: current.after, identity: current.document) else {
            // Remote identity can briefly be unavailable during a long marked
            // edit. Preserve the tapped choice and draft for two frame-sized
            // retries. Any new key, cursor/field change or suspension invalidates
            // the generation, so a delayed tap cannot commit in another context.
            if retry < 2, current == activeCandidateContext() {
                let revision = generation, selection = selectionRevision
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                    guard let self, self.generation == revision, self.selectionRevision == selection,
                          self.activeCandidateContext() == current else { return }
                    self.chooseDisplayed(candidate, context: context, retry: retry + 1)
                }
            }
            return
        }
        commitChoice(selected, document: document, learningRaw: learningRaw)
    }
    private func commitChoice(_ candidate: Candidate, document: KeyboardDocument, learningRaw: String? = nil) {
        beginDocumentEdit(); defer { endDocumentEdit() }
        if composition.isEmpty, candidate.consumed == 0, NumericLexicon.isDigits(candidate.reading) {
            guard settings.learnChoices, let prefix = numericPrefix(), numbers.candidates(for: prefix).contains(candidate) else { return }
            insertText(candidate.text); refreshCandidates(); return
        }
        if settings.language == .chinese {
            let spelling = learningRaw ?? composition.raw
            let phrase = trackPhrase(candidate)
            if composition.raw.isEmpty {
                insertText(candidate.text)
            }
            else {
                composition.consume(candidate.consumed)
                guard document.commitMarkedText(candidate.text, remaining: composition.raw) else { return }
            }
            if !spelling.isEmpty { learn(candidate, raw: spelling, phrase: phrase) }
        } else {
            guard document.selectedText.isEmpty, document.contextBefore == englishSnapshot else { refreshCandidates(); return }
            let word = EnglishContext.word(in: englishSnapshot)
            let output = EnglishContext.applyingCase(candidate.text, like: word)
            if candidate.consumed > 0, output == word {
                // A complete word is already in the host. Space confirms it
                // without deleting and reinserting the same characters.
                insertText(" ")
            } else {
                if candidate.consumed > 0 { for _ in word { document.deleteBackward() } }
                insertText(output + " ")
            }
        }
        refreshCandidates()
    }
    private func needsLatestCandidate(for action: KeyAction) -> Bool {
        guard settings.language == .chinese, !composition.isEmpty else { return false }
        switch action {
        // A long-press choice commits the Chinese draft before its literal
        // suffix, so it must await the same current candidate as punctuation.
        case .space, .literal: return requestedContext != nil
        case .text(let text):
            if page == .letters, !shifted, text.first?.isLetter == true || text == "'" { return false }
            return requestedContext != nil
        default: return false // Layout, delete and mode changes do not need a decoded sentence.
        }
    }
    private func cancelDeferredActions() {
        awaitingCommit = false; deferredContext = nil; deferredActions = []; deferredPreview = nil; deferredVisibleContext = nil
    }
    private func deferUntilCandidates(_ action: KeyAction) {
        awaitingCommit = true; deferredContext = requestedContext; deferredActions.append(action)
        deferredPreview = Composition()
        deferredVisibleContext = activeCandidateContext()
        // Reuse the in-flight current query. Cancelling it and enqueuing the
        // identical sentence again used to stall space and every following key.
    }
    private func resumeDeferredActions() {
        guard !awaitingCommit else { return }
        deferredPreview = nil
        deferredVisibleContext = nil
        deferredContext = nil
        let pending = deferredActions; deferredActions = []
        for action in pending { handle(action) }
    }
    func refreshCandidates() { refreshCandidates(using: nil) }
    private func refreshCandidates(using prepared: PreparedCandidates?, inputOnly: Bool = false) {
        let render: () -> Void = { [self] in
            if inputOnly, let onInputChange { onInputChange() } else { onChange?() }
        }
        guard !isMovingCursor else { return }
        if composition.isEmpty || settings.language != .chinese { characterSelectionMode = false }
        if prepared == nil { discardPreparedCandidates() }
        generation += 1; let requestedGeneration = generation
        cancellation.cancel(); activeCandidates = nil; presentedRevision = 0
        let token = prepared?.token ?? QueryCancellation(); cancellation = token
        if prepared == nil || scheduledQuery !== prepared {
            refinementCancellation.cancel(); refinementWork?.cancel()
        }
        work?.cancel(); candidateGeneration = -1
        hasMoreCandidates = false; loadingMoreCandidates = false
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
        if browsedContext != queryContext { browsedContext = nil }
        if arithmetic != nil { candidateGeneration = requestedGeneration; candidateContext = queryContext }
        let raw = composition.raw, settings = self.settings, learned = self.learned
        let preferred = settings.learnChoices ? personal.candidates(for: raw) : []
        // Numeric recall is a bounded in-memory lookup independent of the
        // Chinese decoder. No query or animation may automatically insert it.
        if arithmetic == nil, selectionIsEmpty, let prefix = numericPrefix() {
            candidates = settings.learnChoices ? numbers.candidates(for: prefix) : []
            candidateGeneration = requestedGeneration; candidateContext = queryContext
            render(); return
        }
        if arithmetic != nil { candidateGeneration = requestedGeneration; render(); return }
        guard let engine, document != nil, selectionIsEmpty else { render(); return }
        englishSnapshot = context
        if characterSelectionMode, settings.language == .chinese, !raw.isEmpty {
            render()
            let job = DispatchWorkItem(qos: .userInitiated) { [weak self] in
                let result = engine.characterCandidates(raw, cancelled: { token.isCancelled })
                guard !token.isCancelled else { return }
                DispatchQueue.main.async {
                    guard let self, self.generation == requestedGeneration, !token.isCancelled else { return }
                    self.candidates = result; self.candidateGeneration = requestedGeneration
                    self.candidateContext = queryContext; self.hasMoreCandidates = false
                    self.notifyCandidates(); self.completeDeferredActions(for: queryContext)
                }
            }
            work = job; queue.async(execute: job); return
        }
        if settings.language == .chinese, !raw.isEmpty {
            guard let query = prepared ?? prepareCandidates(for: raw) else { render(); return }
            activeCandidates = query; preparedCandidates = nil; cancellation = query.token
            presentCandidates(query, notify: false)
            render()
            if candidatesAreCurrent { completeDeferredActions(for: queryContext) }
            guard activeCandidates === query, !query.token.isCancelled else { return }
            if (query.result?.stage ?? 0) == 0 {
                // Publish one corrected sentence row. Showing an uncorrected
                // sentence and replacing it 250 ms later made the row jump and
                // allowed Space to commit the intermediate, incorrect phrase.
                scheduleDecoder(query, delay: 0)
            }
            return
        }
        render()
        let job = DispatchWorkItem(qos: .userInitiated, flags: .enforceQoS) { [weak self] in
            guard !token.isCancelled else { return }
            let result: [Candidate]
            if settings.language == .chinese {
                result = raw.isEmpty ? (settings.predictions ? engine.predictions(after: context) : []) : engine.candidates(raw, learned: settings.learnChoices ? learned : [:], preferred: preferred, correction: false, cancelled: { token.isCancelled })
            } else {
                let word = EnglishContext.word(in: context)
                if word.isEmpty {
                    result = settings.predictions ? engine.englishPredictions(after: context) : []
                } else {
                    let completions = engine.englishCandidates(prefix: word)
                    // Completion intentionally excludes the typed word. Keep a
                    // recognized whole word first so Space cannot expand what
                    // into what's (or can into can't) without an explicit tap.
                    // The mapped dictionary stays on this worker, never a key.
                    let exact = engine.english.lookup("e:" + FuzzyPinyin.normalize(word), limit: 12)
                        .contains { $0.text.lowercased() == word.lowercased() }
                    result = exact ? [Candidate(text: word, consumed: word.count)] + Array(completions.prefix(11)) : completions
                }
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
        if deferredContext == context && !automaticChoiceIsReady { return }
        awaitingCommit = false
        if deferredContext == context { resumeDeferredActions() }
        else { deferredActions = []; deferredContext = nil; deferredPreview = nil; deferredVisibleContext = nil }
    }
    private func trackPhrase(_ candidate: Candidate) -> PhraseLearning.Choice? {
        guard settings.learnChoices, let document else { phraseLearning.reset(); return nil }
        return phraseLearning.select(candidate, from: composition, before: document.contextBefore,
            after: document.contextAfter, document: document.documentIdentity)
    }
    private func numericPrefix() -> String? {
        guard let document, document.selectedText.isEmpty else { return nil }
        return numericRun.prefix(before: document.contextBefore, after: document.contextAfter, document: document.documentIdentity)
    }
    private func insertText(_ text: String) {
        guard let document else { return }
        if settings.learnChoices, document.selectedText.isEmpty, NumericLexicon.isDigits(text) {
            numericRun.append(text, before: document.contextBefore, after: document.contextAfter, document: document.documentIdentity)
        } else { finishNumericRun() }
        document.insert(text)
        literalInputRevision += 1
    }
    private func finishNumericRun() {
        guard !numericRun.isEmpty else { return }
        guard let document, document.selectedText.isEmpty else { numericRun.reset(); return }
        let value = numericRun.complete(before: document.contextBefore, after: document.contextAfter, document: document.documentIdentity)
        if settings.learnChoices, let value { numbers.record(value); scheduleLearningSave() }
    }
    private func learn(_ candidate: Candidate, raw: String, phrase: PhraseLearning.Choice? = nil) {
        guard settings.learnChoices else { return }
        candidateCacheEpoch += 1; candidateCache = [:]; candidateCacheOrder = []; discardPreparedCandidates()
        let text = candidate.text
        personal.record(candidate, for: raw)
        if let phrase, phrase.raw != raw || phrase.candidate.text != candidate.text {
            personal.record(phrase.candidate, for: phrase.raw)
        }
        learned[text] = min(10_000, (learned[text] ?? 0) + 1)
        if learned.count > 512, let least = learned.min(by: { $0.value < $1.value })?.key { learned.removeValue(forKey: least) }
        scheduleLearningSave()
    }
    private func scheduleLearningSave() {
        saveWork?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.flushLearning() }
        saveWork = save; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: save)
    }
    func flushLearning() {
        saveWork?.cancel()
        let epoch = store.defaults.string(forKey: "clear.learned.epoch")
        guard epoch == learningEpoch else {
            learned = [:]; personal = PersonalLexicon(); numbers = NumericLexicon(); learningEpoch = epoch
            phraseLearning.reset(); numericRun.reset()
            candidateCacheEpoch += 1; candidateCache = [:]; candidateCacheOrder = []; discardPreparedCandidates()
            return
        }
        store.defaults.set(learned, forKey: "clear.learned.v1")
        if let data = try? JSONEncoder().encode(personal) { store.defaults.set(data, forKey: "clear.choices.v2") }
        if let data = try? JSONEncoder().encode(numbers) { store.defaults.set(data, forKey: "clear.numbers.v1") }
    }
    func suspend() { appearanceLink?.deactivate(); finishNumericRun(); phraseLearning.reset(); pendingDocumentKeys.removeAll(); stopClipboardCapture(); work?.cancel(); cancellation.cancel(); discardPreparedCandidates(); activeCandidates = nil; refinementWork?.cancel(); refinementCancellation.cancel(); generation += 1; cancelDeferredActions(); flushLearning() }
}

/// Workers publish immutable results without waiting for UIKit's event loop.
/// A late word lookup cannot downgrade a decoded/corrected row.
private final class PreparedCandidates: @unchecked Sendable {
    struct Result {
        let items: [Candidate]; let stage: Int; let revision: Int
        let limit: Int; let hasMore: Bool; let correction: Bool
    }
    let raw: String
    let generation: Int
    let origin: KeyboardModel.CandidateContext
    let cacheEpoch: Int
    let preceding: String
    var cacheKey: CandidateRequestKey { CandidateRequestKey(raw: raw, preceding: preceding) }
    let token = QueryCancellation()
    private let lock = NSLock()
    private var stored: Result?
    private var emptyWordLookup = false
    init(raw: String, generation: Int, origin: KeyboardModel.CandidateContext, cacheEpoch: Int, preceding: String) {
        self.raw = raw; self.generation = generation; self.origin = origin; self.cacheEpoch = cacheEpoch
        self.preceding = preceding
    }
    var result: Result? { lock.lock(); defer { lock.unlock() }; return stored }
    var missedWords: Bool { lock.lock(); defer { lock.unlock() }; return emptyWordLookup }
    func wordLookupCompleted(empty: Bool) { lock.lock(); emptyWordLookup = empty; lock.unlock() }
    func publish(_ items: [Candidate], stage: Int, limit: Int = 8, hasMore: Bool = true, correction: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard stage >= (stored?.stage ?? -1) else { return }
        stored = Result(items: items, stage: stage, revision: (stored?.revision ?? 0) + 1,
                        limit: limit, hasMore: hasMore, correction: correction)
    }
}

private final class QueryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}


/// Only immutable quick-word rows live here. This lock is never held while
/// looking up a dictionary, entering Rime, or calling UIKit/the document proxy.
private final class HotWordCache: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: [Candidate]] = [:]
    private var order: [String] = []
    func value(_ raw: String) -> [Candidate]? {
        lock.lock(); defer { lock.unlock() }; return rows[raw]
    }
    func put(_ raw: String, _ items: [Candidate]) {
        lock.lock(); defer { lock.unlock() }
        if rows[raw] == nil { order.append(raw) }
        rows[raw] = items
        if order.count > 512 { rows.removeValue(forKey: order.removeFirst()) }
    }
}
