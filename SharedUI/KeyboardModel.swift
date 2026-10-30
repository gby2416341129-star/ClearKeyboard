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
    func clearInput(completion: @escaping (DeletedInput?) -> Void)
    func restoreInput(_ value: DeletedInput) -> Bool
    func validateCandidate(before: String, after: String, identity: String) -> Bool
    func validateClipboardSelection(before: String, after: String, identity: String) -> Bool
    func candidateInteractionChanged(_ active: Bool)
    func keyInteractionChanged(_ active: Bool)
}

extension KeyboardDocument {
    func clearInput(completion: @escaping (DeletedInput?) -> Void) { completion(clearInput()) }
    func validateClipboardSelection(before: String, after: String, identity: String) -> Bool {
        validateCandidate(before: before, after: after, identity: identity)
    }
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
            let inputChanged=settings.language != oldValue.language || settings.fuzzyPairs != oldValue.fuzzyPairs ||
                settings.learnChoices != oldValue.learnChoices || settings.predictions != oldValue.predictions
            if inputChanged {
                activeCandidates?.token.cancel(); refinementCancellation.cancel(); refinementWork?.cancel(); scheduledQuery=nil
                discardPreparedCandidates();
            }
            if settings.language != oldValue.language || settings.learnChoices != oldValue.learnChoices {
                phraseLearning.reset(); numericRun.reset()
            }
            if !loadingSavedSettings {
                var saved = settings, previous = oldValue
                if document?.prefersEnglish == true, fieldLanguageOverride == nil, settings.language == oldValue.language {
                    let globalLanguage = store.load().language
                    saved.language = globalLanguage; previous.language = globalLanguage
                }
                store.save(saved)
                if AppearanceSnapshot(settings: saved, includeInputPreferences: true) != AppearanceSnapshot(settings: previous, includeInputPreferences: true) { appearanceLink?.publish(saved, previous: previous) }
            }
            if clipboardActive, settings.capturesClipboard != oldValue.capturesClipboard ||
                settings.clipboardLifetimeHours != oldValue.clipboardLifetimeHours { startClipboardCapture() }
            if !loadingSavedSettings,inputChanged,engineReady {refreshCandidates()}
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
        candidatesAreCurrent && candidateContext == activeCandidateContext() && recommendedCandidate?.canConsume(composition.raw) == true
    }
    private var recommendedCandidate: Candidate? {
        candidates.first{$0.nativeChoice?.recommended == true} ?? candidates.first
    }
    private(set) var engineState = "V19 原生内核加载中…"
    var onChange: (() -> Void)?
    var onCandidatesChange: (() -> Void)?
    var onCandidateSelection: (() -> Void)?
    var spaceSelectsCandidate: Bool {
        !composition.isEmpty || (settings.language == .english && englishSpaceSelectionIsVisible && candidatesAreCurrent)
    }
    var onInputChange: (() -> Void)?
    var onContentKey: (() -> Void)?
    var onNotice: ((String) -> Void)?
    private(set) var hasMoreCandidates = false
    private var loadingMoreCandidates = false
    private var browsedContext: CandidateContext?
    private func notifyCandidates() {
        if let onCandidatesChange { onCandidatesChange() } else { onChange?() }
    }
    let clipboardCapture = ClipboardCapture()
    private var clipboardActive = false
    private var store: SettingsStore
    private var candidatePreferences: CandidatePreferences?
    private var loadingSavedSettings = false
    private var appearanceLink: AppearanceSettingsLink?
    private let suppliedDefaults: UserDefaults?
    private var engineReady = false
    private var startup: Task<Void, Never>?
    private var preparedCandidates: PreparedCandidates?
    private var activeCandidates: PreparedCandidates?
    private var presentedRevision = 0
    private var refinementWork: Task<Void, Never>?
    private var refinementCancellation = QueryCancellation()
    private var work: DispatchWorkItem?
    private var scheduledQuery: PreparedCandidates?
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
    private var clearingInput = false
    private var pendingClearUndo = false
    private var manualShift = false
    private var fieldLanguageOverride: InputLanguage?
    private var fieldIdentity = ""
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

    func manageCandidate(_ candidate: Candidate, context: CandidateContext, pinned: Bool) {
        guard displaysCurrentCandidates(context) else { return }
        candidatePreferences?.set(candidate, context: context, pinned: pinned)

        discardPreparedCandidates(); refreshCandidates()
    }
    func loadMoreCandidates(context: CandidateContext?) {
        // V19 Trial 1 returns at most8 real candidates; no synthetic pages.
    }
    func prepare(_ action: KeyAction) {
        // Submit only accepted raw input. A cancelled contact must not supersede
        // the SDK result that is still available for selection.
    }
    func cancelPreparation() { discardPreparedCandidates() }
    private func discardPreparedCandidates() {
        if preparedCandidates !== activeCandidates {preparedCandidates?.token.cancel()}
        preparedCandidates=nil
    }
    private func prepareCandidates(for raw: String) -> PreparedCandidates? {
        guard engineReady, let document, !raw.isEmpty, document.selectedText.isEmpty else{return nil}
        let origin=CandidateContext(raw:"",before:document.contextBefore,after:document.contextAfter,
            document:document.documentIdentity,language:settings.language)
        let preceding=document.usesLocalPinyinComposition ? CandidateLanguageContext.tail(origin.before):CandidateLanguageContext.preceding(before:origin.before,markedDraft:composition.raw)
        return PreparedCandidates(raw:raw,generation:generation,origin:origin,preceding:preceding)
    }
    private func scheduleDecoder(_ query: PreparedCandidates, delay: Double) {
        guard activeCandidates === query, !query.token.isCancelled else{return}
        refinementCancellation.cancel();refinementWork?.cancel()
        let token=QueryCancellation();refinementCancellation=token;scheduledQuery=query
        let characters=characterSelectionMode
        refinementWork=Task { [weak self] in
            do {
                let result=try await V19InputService.shared.candidates(raw:query.raw,context:query.preceding,characters:characters)
                guard let self, !Task.isCancelled, !token.isCancelled, !query.token.isCancelled,
                      self.activeCandidates === query else{return}
                query.publish(result)
                self.presentCandidates(query)
            } catch {
                guard let self, !Task.isCancelled, !token.isCancelled, self.activeCandidates === query else{return}
                query.publish([]);self.engineState="V19 暂未返回候选："+error.localizedDescription
                self.presentCandidates(query)
            }
        }
    }
    private func presentCandidates(_ query: PreparedCandidates, notify: Bool = true) {
        guard activeCandidates === query, !query.token.isCancelled,
              query.raw==composition.raw, requestedContext?.raw==query.raw,
              let result=query.result else{return}
        candidates=result.items;hasMoreCandidates=false
        candidateGeneration=generation;candidateContext=requestedContext
        if notify {notifyCandidates();completeDeferredActions(for:requestedContext)}
    }

    init(document: KeyboardDocument, settings: KeyboardSettings? = nil, defaults: UserDefaults? = nil,
         appearanceLink: AppearanceSettingsLink? = nil) {
        self.document = document
        suppliedDefaults = defaults
        let defaults = defaults ?? SharedStorage.defaults(allowShared: document.fullAccess)
        store = SettingsStore(defaults: defaults)
        self.settings = settings ?? store.load()
        candidatePreferences = CandidatePreferences(defaults: defaults)
        learningEpoch = defaults.string(forKey: "clear.learned.epoch")
        let memory = LearningStore.load(defaults, epoch: learningEpoch)
        learned = memory.learned; personal = memory.personal; numbers = memory.numbers
        if document.prefersEnglish { self.settings.language = .english }
        fieldIdentity = document.documentIdentity
        self.appearanceLink = appearanceLink
        self.appearanceLink?.currentSettings = { [weak self] in
            guard let self else { return KeyboardSettings() }
            var value = self.settings
            if self.document?.prefersEnglish == true, self.fieldLanguageOverride == nil { value.language = self.store.load().language }
            return value
        }
        self.appearanceLink?.onReceive = { [weak self] snapshot in
            guard let self else { return }
            var value = snapshot.applying(to: self.settings)
            if self.document?.prefersEnglish == true, self.fieldLanguageOverride == nil { value.language = .english }
            let inputChanged = value.language != self.settings.language || value.fuzzyPairs != self.settings.fuzzyPairs ||
                value.predictions != self.settings.predictions || value.learnChoices != self.settings.learnChoices ||
                value.autoCapitalization != self.settings.autoCapitalization
            self.loadingSavedSettings = true
            if value.language != self.settings.language {
                self.finishCompositionAsTyped(); self.page = .letters
                self.shiftState.reset(); self.manualShift = false
            }
            self.settings = value
            self.loadingSavedSettings = false
            // Keep the local fallback current without broadcasting the read.
            self.store.save(snapshot.applying(to: self.store.load()))
            if inputChanged { self.refreshCandidates() }
        }
        if document.fullAccess { self.appearanceLink?.activate() }
        startup=Task { [weak self] in
            do {
                _ = try await V19InputService.shared.prepare()
                guard let self else{return}
                if self.awaitingCommit {
                    if self.deferredVisibleContext == self.activeCandidateContext() {self.deferredContext=self.deferredVisibleContext}
                    else {self.cancelDeferredActions()}
                }
                self.engineReady=true;self.engineState="V19 离线就绪";self.refreshCandidates()
            } catch {
                guard let self else{return}
                // Preserve the draft and editing on loading failure.
                self.engineState="V19 加载失败："+error.localizedDescription;self.onChange?()
            }
        }
    }

    func reloadSettings() {
        guard let document else { return }
        store = SettingsStore(defaults: suppliedDefaults ?? SharedStorage.defaults(allowShared: document.fullAccess))
        candidatePreferences = CandidatePreferences(defaults: store.defaults)
        phraseLearning.reset(); numericRun.reset()
        var saved = store.load()
        if fieldIdentity != document.documentIdentity { fieldIdentity = document.documentIdentity; fieldLanguageOverride = nil }
        if document.prefersEnglish, fieldLanguageOverride == nil { saved.language = .english }
        else if let fieldLanguageOverride { saved.language = fieldLanguageOverride }
        loadingSavedSettings = true
        settings = saved
        loadingSavedSettings = false
        learningEpoch = store.defaults.string(forKey: "clear.learned.epoch")
        let memory = LearningStore.load(store.defaults, epoch: learningEpoch)
        learned = memory.learned; personal = memory.personal; numbers = memory.numbers
        refreshCandidates()
        refreshAppearanceConnection()
    }
    func refreshAppearanceConnection() {
        appearanceLink?.updateFullAccess(document?.fullAccess == true)
        if document?.fullAccess == true { appearanceLink?.activate() } else { appearanceLink?.deactivate() }
    }
    func documentTraitsChanged() {
        guard let document, fieldIdentity != document.documentIdentity else { return }
        fieldIdentity = document.documentIdentity; fieldLanguageOverride = nil
        loadingSavedSettings = true
        settings.language = document.prefersEnglish ? .english : store.load().language
        loadingSavedSettings = false
        page = .letters; shiftState.reset(); manualShift = false; refreshCandidates()
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
        let pending = awaitingCommit ? deferredActions : []
        let identity = document?.documentIdentity
        // Invalidate conversion callbacks before the proxy can service a focus
        // change. No late candidate may restart/clear this literal on re-entry.
        cancellation.cancel(); work?.cancel(); refinementCancellation.cancel(); refinementWork?.cancel()
        discardPreparedCandidates(); activeCandidates = nil
        generation += 1; candidates = []; candidateContext = nil; requestedContext = nil
        if awaitingCommit { document?.setMarkedText(composition.raw) }
        cancelDeferredActions()
        phraseLearning.reset()
        if !composition.raw.isEmpty { document?.unmarkText() }; composition.clear()
        // Dismissal is an ordered barrier, not permission to discard accepted
        // keys that a slow decoder has not replayed yet.
        for action in pending where document?.documentIdentity == identity {
            switch action {
            case .text(let text):
                let decimal = page == .numbers && text == "."
                insertText(shifted && page == .letters ? text.uppercased() : decimal ? text : punctuation(text))
                if !capsLocked { shifted = false; manualShift = false }
                if !decimal, page != .letters && [".", ",", "?", "!", "。", "，", "？", "！"].contains(text) { page = .letters }
            case .literal(let text):
                insertText(text)
                if !capsLocked { shifted = false; manualShift = false }
            case .space: insertText(" ")
            case .enter: insertText("\n")
            case .delete: document?.deleteBackward()
            case .shift: shiftState.tap(now: ProcessInfo.processInfo.systemUptime); manualShift = true
            case .page(let next): page = next
            case .language: toggleLanguage()
            case .globe: document?.nextKeyboard()
            }
        }
    }
    private func syncMarkedText() {
        document?.setMarkedText(composition.raw)
        if composition.raw.isEmpty { document?.unmarkText() }
    }
    func startClipboardCapture(retryPermission: Bool = false, userRequested: Bool = false) {
        clipboardActive = true
        clipboardCapture.activate(settings: settings, allowed: document?.fullAccess == true, retryPermission: retryPermission, userRequested: userRequested)
    }
    func stopClipboardCapture() { clipboardActive = false; clipboardCapture.stop() }
    func moveCursor(_ offset: Int) {
        beginDocumentEdit(); defer { endDocumentEdit() }
        if !isMovingCursor { if awaitingCommit { finishCompositionAsTyped() } else if !finishForDocumentAction() { return } }
        phraseLearning.reset(); finishNumericRun()
        document?.moveCursor(offset)
        if !isMovingCursor { refreshCandidates() }
    }
    func beginCursorMovement() {
        beginDocumentEdit(); defer { endDocumentEdit() }
        guard !isMovingCursor else { return }
        if awaitingCommit { finishCompositionAsTyped() } else if !finishForDocumentAction() { return }
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
        guard !clearingInput, let document else { return }
        beginDocumentEdit(); clearingInput = true; pendingClearUndo = false
        deletionUndo = nil; cancelDeferredActions(); phraseLearning.reset(); numericRun.reset()
        let spelling = composition
        document.unmarkText(); composition.clear()
        candidates = []; candidateContext = nil; onChange?()
        document.clearInput { [weak self, weak document] deleted in
            guard let self else { return }
            if let deleted, let document {
                self.deletionUndo = (deleted, document.documentIdentity, document.contextBefore, document.contextAfter, spelling)
            }
            self.clearingInput = false
            let undo = self.pendingClearUndo; self.pendingClearUndo = false
            if undo { _ = self.undoClearInput() } else { self.refreshCandidates() }
            self.endDocumentEdit()
        }
    }
    @discardableResult func undoClearInput() -> Bool {
        if clearingInput { pendingClearUndo = true; return true }
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
        if awaitingCommit { finishCompositionAsTyped() } else if !finishForDocumentAction() { return }
        settings.language = settings.language == .chinese ? .english : .chinese
        if document?.prefersEnglish == true { fieldLanguageOverride = settings.language }
        page = .letters; shiftState.reset(); manualShift = false; refreshCandidates()
    }
    func handle(_ action: KeyAction) {
        switch action {
        case .text, .literal, .space, .enter: onContentKey?()
        default: break
        }
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
            guard finishForDocumentAction() else { return }
            insertText(text)
            if !capsLocked { shifted = false; manualShift = false }
        case .text(let text):
            let possibleOperator = composition.isEmpty && text.count == 1 && "xX+-*/×÷().".contains(text) &&
                !(shifted && page == .letters && text.first?.isLetter == true)
            let mathCharacter = possibleOperator && document?.contextBefore.last.map({ $0.isNumber || $0 == ")" }) == true
            if mathCharacter {
                guard finishForDocumentAction() else { return }
                insertText(text)
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
                guard finishForDocumentAction() else { return }
                let decimal = page == .numbers && text == "."
                insertText(shifted && page == .letters ? text.uppercased() : decimal ? text : punctuation(text))
                if !capsLocked { shifted = false; manualShift = false }
                if !decimal, page != .letters && [".", ",", "?", "!", "。", "，", "？", "！"].contains(text) { page = .letters }
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
            if composition.isEmpty { insertText(" ") }
            else {
                let selecting = automaticChoiceIsReady && candidates.first != nil
                if commitComposition(flushRemainder: false), selecting { onCandidateSelection?() }
            }
        case .enter:
            if composition.isEmpty {insertText("\n")}
            else if commitComposition(flushRemainder:false) {onCandidateSelection?()}
        case .page(let next): page = next
        case .globe: finishForDocumentAction(); finishNumericRun(); phraseLearning.reset(); document?.nextKeyboard()
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
        if awaitingCommit { finishCompositionAsTyped() } else { finishForDocumentAction() }
        guard let document else { return nil }
        return ClipboardTextSession(document: document)
    }
    @discardableResult func updateClipboardSelection(_ session: ClipboardTextSession, text: String) -> Bool {
        beginDocumentEdit(); defer { endDocumentEdit() }
        let updated = session.apply(text)
        return updated
    }
    func insertLiteral(_ text: String) {
        beginDocumentEdit(); defer { endDocumentEdit() }
        if awaitingCommit { finishCompositionAsTyped() } else if !finishForDocumentAction() { return }
        insertText(text); refreshCandidates()
    }
    func chooseArithmetic(_ text: String) {
        beginDocumentEdit(); defer { endDocumentEdit() }
        guard let document, let arithmetic, arithmetic.candidates.contains(text),
              composition.isEmpty, document.selectedText.isEmpty, document.contextBefore.hasSuffix(arithmetic.expression) else { return }
        numericRun.reset(); phraseLearning.reset()
        for _ in arithmetic.expression { document.deleteBackward() }
        document.insert(text); onCandidateSelection?(); refreshCandidates()
    }
    /// Explicit cursor, language, literal and document actions preserve an
    /// unconverted draft as typed. An empty SDK result itself never commits it.
    @discardableResult private func finishForDocumentAction() -> Bool {
        if !composition.isEmpty && !automaticChoiceIsReady {
            finishCompositionAsTyped(); return true
        }
        return commitComposition()
    }
    @discardableResult private func commitComposition(flushRemainder: Bool = true) -> Bool {
        guard !composition.isEmpty else {composition.clear();return true}
        guard automaticChoiceIsReady,let document,let candidate=recommendedCandidate,
              let choice=candidate.nativeChoice, candidateContext == activeCandidateContext() else{return false}
        let spelling=composition.raw,previousLearning=phraseLearning
        let context=CandidateLanguageContext.preceding(before:document.contextBefore,markedDraft:spelling)
        let phrase=trackPhrase(candidate,explicit:false)
        guard document.commitMarkedText(choice.selection.selectedText,remaining:choice.selection.remainingPinyin) else {
            phraseLearning=previousLearning;return false
        }
        composition.replace(with:choice.selection.remainingPinyin)
        learn(candidate,raw:spelling,phrase:phrase,context:context,explicit:false)
        return true
    }

    func choose(_ candidate: Candidate) {
        guard candidateGeneration == generation, candidates.contains(candidate), let document else { return }
        commitChoice(candidate, document: document, explicit:true)
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
        guard context == current, candidateContext == context, candidatesAreCurrent, candidates.contains(candidate) else{return}
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
        commitChoice(candidate, document: document, explicit:true)
    }
    private func commitChoice(_ candidate: Candidate, document: KeyboardDocument, learningRaw: String? = nil, explicit: Bool = false) {
        beginDocumentEdit(); defer { endDocumentEdit() }
        if composition.isEmpty, candidate.consumed == 0, NumericLexicon.isDigits(candidate.reading) {
            guard settings.learnChoices, let prefix = numericPrefix(), numbers.candidates(for: prefix).contains(candidate) else { return }
            insertText(candidate.text); onCandidateSelection?(); refreshCandidates(); return
        }
        if settings.language == .chinese {
            guard candidatesAreCurrent,candidateContext == activeCandidateContext(),candidates.contains(candidate),candidate.canConsume(composition.raw),let choice=candidate.nativeChoice else{return}
            let spelling=composition.raw,previousLearning=phraseLearning
            let context=CandidateLanguageContext.preceding(before:document.contextBefore,markedDraft:spelling)
            let phrase=trackPhrase(candidate,explicit:explicit)
            guard document.commitMarkedText(choice.selection.selectedText,remaining:choice.selection.remainingPinyin) else {
                phraseLearning=previousLearning;return
            }
            composition.replace(with:choice.selection.remainingPinyin)
            learn(candidate,raw:spelling,phrase:phrase,context:context,explicit:explicit)
        }
        onCandidateSelection?()
        refreshCandidates()
    }
    private func needsLatestCandidate(for action: KeyAction) -> Bool {
        guard settings.language == .chinese, !composition.isEmpty else { return false }
        switch action {
        // A long-press choice commits the Chinese draft before its literal
        // suffix, so it must await the same current candidate as punctuation.
        case .space, .literal, .enter: return requestedContext != nil && activeCandidates?.result == nil
        case .text(let text):
            if page == .letters, !shifted, text.first?.isLetter == true || text == "'" { return false }
            return requestedContext != nil && activeCandidates?.result == nil
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
        refinementCancellation.cancel();refinementWork?.cancel()
        work?.cancel();candidateGeneration = -1
        hasMoreCandidates = false; loadingMoreCandidates = false
        let selectionIsEmpty = document?.selectedText.isEmpty == true
        let context = composition.isEmpty || settings.language == .english ? (document?.contextBefore ?? "") : ""
        englishSnapshot=context
        arithmetic = composition.isEmpty && selectionIsEmpty ? InlineArithmetic.result(in: context) : nil
        if arithmetic != nil || !engineReady || !selectionIsEmpty { candidates = [] }
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
        let raw=composition.raw
        if arithmetic == nil, selectionIsEmpty, let prefix=numericPrefix() {
            candidates=settings.learnChoices ? numbers.candidates(for:prefix):[]
            candidateGeneration=requestedGeneration;candidateContext=queryContext;render();return
        }
        if arithmetic != nil {candidateGeneration=requestedGeneration;render();return}
        candidates=[];candidateContext=queryContext
        guard settings.language == .chinese,!raw.isEmpty,selectionIsEmpty,document != nil,engineReady else {
            candidateGeneration=requestedGeneration;render();return
        }
        guard let query=prepareCandidates(for:raw) else {render();return}
        activeCandidates=query;cancellation=query.token
        render();scheduleDecoder(query,delay:0)
    }

    private func completeDeferredActions(for context: CandidateContext?) {
        guard awaitingCommit else { return }
        if deferredContext == context && activeCandidates?.result == nil { return }
        awaitingCommit = false
        if deferredContext == context { resumeDeferredActions() }
        else { deferredActions = []; deferredContext = nil; deferredPreview = nil; deferredVisibleContext = nil }
    }
    private func trackPhrase(_ candidate: Candidate, explicit: Bool = false) -> PhraseLearning.Choice? {
        guard settings.learnChoices, let document else { phraseLearning.reset(); return nil }
        return phraseLearning.select(candidate, from: composition, before: document.contextBefore,
            after: document.contextAfter, document: document.documentIdentity, explicit:explicit)
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
    private func learn(_ candidate: Candidate, raw: String, phrase: PhraseLearning.Choice? = nil, context: String = "", explicit: Bool = false) {
        guard settings.learnChoices else { return }
        discardPreparedCandidates()
        let text = candidate.text
        personal.record(candidate,for:raw,context:context,explicit:explicit)
        if let phrase, phrase.raw != raw || phrase.candidate.text != candidate.text {
            personal.record(phrase.candidate,for:phrase.raw,context:phrase.context,explicit:phrase.explicit)
        }
        let learningKey=raw+"|"+text
        learned[learningKey] = min(10_000, (learned[learningKey] ?? 0) + 1)
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
            discardPreparedCandidates()
            return
        }
        LearningStore.save(LearningMemory(learned: learned, personal: personal, numbers: numbers), defaults: store.defaults, epoch: learningEpoch)
    }
    func suspend() {
        if isMovingCursor { document?.endTrackpad(); isMovingCursor = false }
        appearanceLink?.deactivate(); finishNumericRun(); phraseLearning.reset(); pendingDocumentKeys.removeAll()
        stopClipboardCapture(); work?.cancel(); cancellation.cancel(); discardPreparedCandidates(); activeCandidates = nil
        refinementWork?.cancel(); refinementCancellation.cancel(); generation += 1; cancelDeferredActions(); flushLearning()
    }
}

/// A version-scoped SDK response; no host scoring or candidate merging.
private final class PreparedCandidates {
    struct Result {let items:[Candidate]}
    let raw:String
    let generation:Int
    let origin:KeyboardModel.CandidateContext
    let preceding:String
    let token=QueryCancellation()
    var result:Result?
    init(raw:String,generation:Int,origin:KeyboardModel.CandidateContext,preceding:String) {
        self.raw=raw;self.generation=generation;self.origin=origin;self.preceding=preceding
    }
    func publish(_ items:[Candidate]) {result=Result(items:items)}
}
private final class QueryCancellation: @unchecked Sendable {
    private let lock=NSLock()
    private var value=false
    var isCancelled:Bool {lock.lock();defer{lock.unlock()};return value}
    func cancel() {lock.lock();value=true;lock.unlock()}
}
