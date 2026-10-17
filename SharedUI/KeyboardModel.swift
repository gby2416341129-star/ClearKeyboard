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
    func nextKeyboard()
    func setMarkedText(_ text: String)
    func unmarkText()
    func clearInput() -> DeletedInput?
    func restoreInput(_ value: DeletedInput) -> Bool
}

struct DeletedInput { let text: String; let selection: NSRange }

@MainActor final class KeyboardModel {
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
    let clipboardCapture = ClipboardCapture()
    private var clipboardActive = false
    private var store: SettingsStore
    private var engine: InputEngine?
    private let queue = DispatchQueue(label: "clear.candidates", qos: .userInitiated)
    private var work: DispatchWorkItem?
    private var generation = 0
    private var candidateGeneration = -1
    private var englishSnapshot = ""
    private var learned: [String: Int] = [:]
    private var learningEpoch: String?
    private var saveWork: DispatchWorkItem?
    private var lastShift = Date.distantPast
    private var manualShift = false
    private var cancellation = QueryCancellation()
    private let signpost = OSLog(subsystem: "app.clear.keyboard", category: .pointsOfInterest)

    init(document: KeyboardDocument, settings: KeyboardSettings? = nil) {
        self.document = document
        let defaults = SharedStorage.defaults(allowShared: document.fullAccess)
        store = SettingsStore(defaults: defaults)
        self.settings = settings ?? store.load()
        learned = defaults.dictionary(forKey: "clear.learned.v1") as? [String: Int] ?? [:]
        learningEpoch = defaults.string(forKey: "clear.learned.epoch")
        if document.prefersEnglish { self.settings.language = .english }
        queue.async { [weak self] in
            let result = Result { try InputEngine.bundled() }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let engine): self.engine = engine; self.engineState = "离线就绪"; self.refreshCandidates()
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
        learningEpoch = store.defaults.string(forKey: "clear.learned.epoch")
        refreshCandidates()
    }
    func clearComposition() {
        if !composition.raw.isEmpty { document?.setMarkedText(""); document?.unmarkText() }
        composition.clear(); refreshCandidates()
    }
    func cursorChanged() {
        guard !isMovingCursor else { return }
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
    }
    func endCursorMovement() { guard isMovingCursor else { return }; isMovingCursor = false; refreshCandidates() }
    func clearInput() {
        guard let document else { return }
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
        deletionUndo = nil
        let event = OSSignpostID(log: signpost)
        os_signpost(.begin, log: signpost, name: "KeyAction", signpostID: event)
        defer { os_signpost(.end, log: signpost, name: "KeyAction", signpostID: event) }
        switch action {
        case .text(let text):
            let mathContext = document?.contextBefore ?? ""
            let mathCharacter = text.count == 1 && "xX+-*/×÷().".contains(text) && mathContext.last.map({ $0.isNumber || $0 == ")" }) == true
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
            document?.setMarkedText(candidate.text); document?.unmarkText(); composition.consume(candidate.consumed)
            // Preserve any spelling not covered by a partial candidate.
            if flushRemainder && !composition.isEmpty { document?.insert(composition.normalized) }
            learn(candidate.text)
        } else { document?.setMarkedText(composition.normalized); document?.unmarkText() }
        if flushRemainder || fallback == nil { composition.clear() }
        else if !composition.raw.isEmpty { syncMarkedText() }
    }
    func choose(_ candidate: Candidate) {
        guard candidateGeneration == generation, candidates.contains(candidate), let document else { return }
        if settings.language == .chinese {
            if composition.raw.isEmpty { document.insert(candidate.text) }
            else {
                document.setMarkedText(candidate.text); document.unmarkText()
                composition.consume(candidate.consumed)
                if !composition.raw.isEmpty { syncMarkedText() }
            }
            learn(candidate.text)
        } else {
            guard document.selectedText.isEmpty, document.contextBefore == englishSnapshot else { refreshCandidates(); return }
            let word = EnglishContext.word(in: englishSnapshot)
            let output = EnglishContext.applyingCase(candidate.text, like: word)
            if candidate.consumed > 0 { for _ in word { document.deleteBackward() } }
            document.insert(output + " ")
        }
        refreshCandidates()
    }
    func refreshCandidates() {
        guard !isMovingCursor else { return }
        generation += 1; let requestedGeneration = generation
        cancellation.cancel(); let token = QueryCancellation(); cancellation = token
        work?.cancel(); candidateGeneration = -1
        arithmetic = composition.isEmpty && document?.selectedText.isEmpty == true ? InlineArithmetic.result(in: document?.contextBefore ?? "") : nil
        if arithmetic != nil || engine == nil || document?.selectedText.isEmpty != true { candidates = [] }
        if settings.language == .english && !capsLocked && !manualShift, let document {
            let context = document.contextBefore
            let trimmed = context.trimmingCharacters(in: .whitespaces)
            switch document.capitalization {
            case .allCharacters: shifted = settings.autoCapitalization
            case .words: shifted = settings.autoCapitalization && (context.isEmpty || context.last?.isWhitespace == true)
            case .sentences:
                shifted = settings.autoCapitalization && (context.isEmpty || context.last?.isNewline == true || (context.last?.isWhitespace == true && trimmed.last.map { ".!?。！？".contains($0) } == true))
            default: shifted = false
            }
        }
        if arithmetic != nil { candidateGeneration = requestedGeneration }
        onChange?()
        if arithmetic != nil { candidateGeneration = requestedGeneration; return }
        guard let engine, let document, document.selectedText.isEmpty else { return }
        let raw = composition.raw, context = document.contextBefore, settings = self.settings, learned = self.learned
        englishSnapshot = context
        let job = DispatchWorkItem { [weak self] in
            let result: [Candidate]
            if settings.language == .chinese {
                result = raw.isEmpty ? (settings.predictions ? engine.predictions(after: context) : []) : engine.candidates(raw, fuzzy: settings.fuzzyPairs, learned: settings.learnChoices ? learned : [:], cancelled: { token.isCancelled })
            } else {
                let word = EnglishContext.word(in: context)
                result = word.isEmpty ? (settings.predictions ? engine.englishPredictions(after: context) : []) : engine.englishCandidates(prefix: word)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == requestedGeneration else { return }
                self.candidates = result; self.candidateGeneration = requestedGeneration; self.onChange?()
            }
        }
        work = job; queue.async(execute: job)
    }
    private func learn(_ text: String) {
        guard settings.learnChoices else { return }
        learned[text] = min(10_000, (learned[text] ?? 0) + 1)
        if learned.count > 512, let least = learned.min(by: { $0.value < $1.value })?.key { learned.removeValue(forKey: least) }
        saveWork?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.flushLearning() }
        saveWork = save; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: save)
    }
    func flushLearning() {
        saveWork?.cancel()
        let epoch = store.defaults.string(forKey: "clear.learned.epoch")
        guard epoch == learningEpoch else { learned = [:]; learningEpoch = epoch; return }
        store.defaults.set(learned, forKey: "clear.learned.v1")
    }
    func suspend() { stopClipboardCapture(); work?.cancel(); cancellation.cancel(); generation += 1; flushLearning() }
}

private final class QueryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
