import UIKit
import os

@objc(ClearKeyboardViewController)
class KeyboardViewController: UIInputViewController, KeyboardDocument {
    private var model: KeyboardModel!
    private var surface: KeyboardSurface!
    private var heightConstraint: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?
    private var surfaceHeightConstraint: NSLayoutConstraint?
    private var hostState = HostTextState()
    private var hostEnterTitle = "换行"
    private var hostCapitalization = UITextAutocapitalizationType.none
    private var hostPrefersEnglish = false
    private var hostNeedsGlobe = true
    private var hostRefresh: Timer?
    private var pendingMarkedText = LatestValue<String>()
    private let markedFrame = DisplayFrameTask()
    private var markedCadence = FrameWriteCadence()
    private var markedWriteGeneration = 0
    private var markedImmediateScheduled = false
    private var hostRefreshGeneration = 0
    private var activeKeys = 0
    private var hostActive = true
    private var needsHostRefresh = false
    private var trackpad: ProxyTrackpad?
    private var lastLayoutLog = ""
    private var layoutLogCount = 0
    private let hostLog = OSLog(subsystem: "ClearKeyboard", category: "HostWrite")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear; view.isOpaque = false
        view.accessibilityIdentifier = "clear.keyboard.root"
        inputView?.allowsSelfSizing = false
        refreshHostState(refreshTraits: true)
        model = KeyboardModel(document: self)
        surface = KeyboardSurface(model: model, systemBacked: true)
        surface.configureGlobe = { [weak self] button in
            guard let self else { return }
            button.addTarget(self, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        view.addSubview(surface)
        surface.translatesAutoresizingMaskIntoConstraints = false
        let contentHeight = surface.heightAnchor.constraint(equalToConstant: surface.desiredHeight)
        contentHeight.identifier = "clear.keyboard.surface-height"; surfaceHeightConstraint = contentHeight
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor), contentHeight
        ])
        surface.onHeightChange = { [weak self] height in self?.updateHeight(height) }
        updateHeight(surface.desiredHeight)

    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); hostActive = true; refreshHostState(refreshTraits: true); model?.reloadSettings()
        if let surface { updateHeight(surface.desiredHeight) }
    }
    override func updateViewConstraints() {
        if let surface { updateHeight(surface.desiredHeight) }
        super.updateViewConstraints()
    }
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        surface?.setNeedsLayout()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let surface { updateHeight(surface.desiredHeight) }
        model?.startClipboardCapture()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let surface else { return }
        // A cached host frame is provisional, especially when Safari changes input traits.
        // Keep the requested key pitch while UIKit negotiates the remote view's final height.
        // Squeezing the surface into that frame permanently changed both key size and font size.
        // UIKit completes the normal layout pass. Forcing a second synchronous
        // subtree layout here makes host size acknowledgements contend with keys.
        let layout = "root=\(view.bounds) content=\(surface.frame) parent=\(view.superview?.bounds ?? .zero) window=\(view.window?.bounds ?? .zero)"
        if layout != lastLayoutLog && layoutLogCount < 12 {
            lastLayoutLog = layout; layoutLogCount += 1
            NSLog("CLEAR_KEYBOARD_LAYOUT %@", layout)
        }
        updateHeight(surface.desiredHeight)
    }
    private func updateHeight(_ height: CGFloat) {
        if abs((surfaceHeightConstraint?.constant ?? 0) - height) > 0.5 { surfaceHeightConstraint?.constant = height }
        view.translatesAutoresizingMaskIntoConstraints = false
        if heightConstraint == nil {
            let constraint = view.heightAnchor.constraint(equalToConstant: height)
            constraint.identifier = "clear.keyboard.content-height"
            constraint.priority = .required; constraint.isActive = true; heightConstraint = constraint
        } else if abs((heightConstraint?.constant ?? 0) - height) > 0.5 { heightConstraint?.constant = height }
        let hostWidth = KeyboardGeometry.fittingWidth(primary: view.bounds.width,
            container: view.superview?.bounds.width ?? 0, window: view.window?.bounds.width ?? 0)
        guard hostWidth.isFinite, hostWidth > 0 else { return }
        // UIKit owns the available width. A lower-priority fallback gives its native
        // fitting pass a nonzero width without fighting required host constraints.
        // Never treat a remote window's full width or height as the keyboard's size.
        if widthConstraint == nil {
            let constraint = view.widthAnchor.constraint(equalToConstant: hostWidth)
            constraint.identifier = "clear.keyboard.system-width"; constraint.priority = .defaultHigh
            constraint.isActive = true; widthConstraint = constraint
        } else if abs((widthConstraint?.constant ?? 0) - hostWidth) > 0.5 { widthConstraint?.constant = hostWidth }
        if inputView?.allowsSelfSizing != true { inputView?.allowsSelfSizing = true }
    }
    override func viewWillDisappear(_ animated: Bool) {
        hostActive = false
        hostRefreshGeneration += 1; hostRefresh?.invalidate(); hostRefresh = nil
        super.viewWillDisappear(animated); surface?.stopInteractions(); model?.finishCompositionAsTyped(); model?.suspend()
    }
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if model?.isMovingCursor == true { return }
        // Even the identity getter can cross the remote-host boundary. A text
        // acknowledgement must not do synchronous proxy reads in a key's frame.
        needsHostRefresh = true
        scheduleHostRefresh()
    }
    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        guard model?.isMovingCursor != true else { return }
        needsHostRefresh = true; scheduleHostRefresh()
    }
    func keyInteractionChanged(_ active: Bool) {
        activeKeys = max(0, activeKeys + (active ? 1 : -1))
        if active { hostRefreshGeneration += 1; hostRefresh?.invalidate(); hostRefresh = nil }
        else if activeKeys == 0, needsHostRefresh { scheduleHostRefresh() }
    }
    func candidateInteractionChanged(_ active: Bool) {
        if active { hostRefreshGeneration += 1; hostRefresh?.invalidate(); hostRefresh = nil }
        else if needsHostRefresh { scheduleHostRefresh() }
    }
    private func scheduleHostRefresh() {
        hostRefresh?.invalidate(); hostRefresh = nil
        guard hostActive, activeKeys == 0 else { return }
        hostRefreshGeneration += 1; let request = hostRefreshGeneration
        let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hostRefreshGeneration == request,
                      self.hostActive, self.activeKeys == 0 else { return }
                self.hostRefresh = nil
                // Read UIKit's actual tracking state, not a latched gesture flag.
                // In particular, the next touch may already own a coasting row.
                if self.surface?.isInteractingWithCandidates == true { self.scheduleHostRefresh(); return }
                self.refreshHostState()
            }
        }
        hostRefresh = timer
        RunLoop.main.add(timer, forMode: .default)
    }
    private func readHostSnapshot() -> HostTextSnapshot {
        // A temporarily unavailable remote identifier is not evidence that the
        // user switched fields. Treating nil as a new "disconnected" document
        // unmarked long input and cleared its candidates before a tap committed.
        guard let identifier = connectedDocumentIdentifier()?.uuidString else {
            var unavailable = hostState.snapshot
            unavailable.available = false
            return unavailable
        }
        let before = textDocumentProxy.documentContextBeforeInput
        let after = textDocumentProxy.documentContextAfterInput
        return HostTextSnapshot(before: before ?? "", after: after ?? "", selected: textDocumentProxy.selectedText ?? "",
            document: identifier, available: before != nil || after != nil)
    }
    private func refreshHostState(refreshTraits: Bool = false) {
        needsHostRefresh = false
        let revision = hostRefreshGeneration
        let actual = readHostSnapshot()
        // A remote getter may service UIKit callbacks before returning. A key
        // or another notification in that interval invalidates this read; it
        // cannot cancel a newer spelling or unmark its first letter.
        guard revision == hostRefreshGeneration else {
            needsHostRefresh = true; scheduleHostRefresh(); return
        }
        let outcome = hostState.reconcile(actual)
        guard outcome != .unavailable else { needsHostRefresh = true; scheduleHostRefresh(); return }
        // Traits belong to the field. Own text acknowledgements must not fetch
        // all of them again after each confirmed word.
        if refreshTraits || outcome == .externalEdit {
            hostNeedsGlobe = needsInputModeSwitchKey
            hostCapitalization = textDocumentProxy.autocapitalizationType ?? .sentences
            switch textDocumentProxy.keyboardType ?? .default {
            case .emailAddress, .URL, .asciiCapable, .asciiCapableNumberPad: hostPrefersEnglish = true
            default: hostPrefersEnglish = false
            }
            switch textDocumentProxy.returnKeyType ?? .default {
            case .send: hostEnterTitle = "发送"
            case .search, .google, .yahoo: hostEnterTitle = "搜索"
            case .go: hostEnterTitle = "前往"
            case .done: hostEnterTitle = "完成"
            case .next: hostEnterTitle = "下一项"
            case .join: hostEnterTitle = "加入"
            default: hostEnterTitle = "换行"
            }
        }
        if case .externalEdit = outcome {
            markedFrame.cancel(); pendingMarkedText.discard()
            markedWriteGeneration += 1; markedImmediateScheduled = false
            surface?.closePanel(); model?.cursorChanged()
        }
    }
    func validateCandidate(before: String, after: String, identity: String) -> Bool {
        // The candidate's generation and local edit snapshot have already been
        // checked. Reading whole remote contexts on touch-up both blocks UIKit
        // and rejects hosts that omit the active marked range from their context.
        guard hostState.snapshot.selected.isEmpty, before == contextBefore, after == contextAfter,
              identity == documentIdentity else { return false }
        // Do not destroy an active draft on a transient nil response. A real,
        // different UUID still forces the normal external-field reconciliation.
        guard let actualIdentity = connectedDocumentIdentifier()?.uuidString else {
            needsHostRefresh = true; scheduleHostRefresh(); return false
        }
        guard actualIdentity == identity else { refreshHostState(); return false }
        return true
    }
    private func connectedDocumentIdentifier() -> UUID? {
        // UIKit can return nil before connecting the host, despite its nonoptional Swift UUID declaration.
        // Call the public Objective-C getter so the absent value stays optional during bridging.
        let getter = #selector(getter: UITextDocumentProxy.documentIdentifier)
        guard let proxy = textDocumentProxy as? NSObject, proxy.responds(to: getter) else { return nil }
        return proxy.perform(getter)?.takeUnretainedValue() as? UUID
    }
    var contextBefore: String { hostState.snapshot.before }
    var contextAfter: String { hostState.snapshot.after }
    var documentIdentity: String { hostState.snapshot.document }
    var selectedText: String { hostState.snapshot.selected }
    var fullAccess: Bool { hasFullAccess }
    var needsGlobe: Bool { hostNeedsGlobe }
    var capitalization: UITextAutocapitalizationType { hostCapitalization }
    var prefersEnglish: Bool { hostPrefersEnglish }
    var enterTitle: String { hostEnterTitle }
    private func performHostEdit(_ edit: () -> Void) {
        // A key arriving before the idle timer fires must cancel that read even
        // if its own textDidChange acknowledgement has not arrived yet.
        hostRefreshGeneration += 1; hostRefresh?.invalidate(); hostRefresh = nil
        flushMarkedText()
        edit()
        if needsHostRefresh { scheduleHostRefresh() }
    }
    func insert(_ text: String) { performHostEdit { hostState.insert(text); textDocumentProxy.insertText(text) } }
    func setMarkedText(_ text: String) {
        hostRefreshGeneration += 1; hostRefresh?.invalidate(); hostRefresh = nil
        hostState.setMarked(text)
        pendingMarkedText.replace(with: text)
        // UIKit's host proxy crosses a process boundary. Queue turns can run
        // many times before one frame is presented; send the latest spelling
        // once per display opportunity, while keeping the local ledger current.
        guard !markedImmediateScheduled else { return }
        let rate = view.window?.screen.maximumFramesPerSecond ?? 60
        if markedCadence.canWriteImmediately(now: ProcessInfo.processInfo.systemUptime, maximumFramesPerSecond: rate) {
            // Normal single taps retain next-main-turn delivery. Only a burst
            // needs pacing; an idle key must not acquire a full extra frame.
            markedImmediateScheduled = true
            let revision = markedWriteGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.markedWriteGeneration == revision else { return }
                self.flushMarkedText()
                if self.needsHostRefresh { self.scheduleHostRefresh() }
            }
            return
        }
        markedFrame.schedule(in: view, maximumFramesPerSecond: rate) { [weak self] in
            guard let self else { return }
            self.flushMarkedText()
            if self.needsHostRefresh { self.scheduleHostRefresh() }
        }
    }
    private func flushMarkedText() {
        // Commit, deletion, cursor movement and unmark are ordered barriers.
        // No pending spelling frame may run after those edits.
        markedFrame.cancel()
        markedImmediateScheduled = false; markedWriteGeneration += 1
        guard let text = pendingMarkedText.take() else { return }
        let event = OSSignpostID(log: hostLog)
        os_signpost(.begin, log: hostLog, name: "MarkedTextWrite", signpostID: event, "utf16=%d", text.utf16.count)
        defer { os_signpost(.end, log: hostLog, name: "MarkedTextWrite", signpostID: event) }
        textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
        markedCadence.didWrite(now: ProcessInfo.processInfo.systemUptime)
    }
    func unmarkText() { performHostEdit { hostState.unmark(); textDocumentProxy.unmarkText() } }
    func deleteBackward() { performHostEdit { hostState.deleteBackward(); textDocumentProxy.deleteBackward() } }
    func moveCursor(_ offset: Int) {
        performHostEdit { hostState.moveCursor(offset); textDocumentProxy.adjustTextPosition(byCharacterOffset: offset) }
    }
    func beginTrackpad() { trackpad = ProxyTrackpad(before: contextBefore, after: contextAfter) }
    func trackCursor(translation: CGPoint) {
        guard var state = trackpad else { return }
        let offset = state.offset(translation: translation); trackpad = state
        if offset != 0 { moveCursor(offset) }
    }
    func endTrackpad() { trackpad = nil; refreshHostState() }
    func nextKeyboard() { advanceToNextInputMode() }
    func clearInput() -> DeletedInput? {
        guard hostState.snapshot.document != "disconnected" else { return nil }
        let before = contextBefore, selected = selectedText, after = contextAfter
        let text = before + selected + after
        guard !text.isEmpty, text.count <= 4_096 else { return nil }
        let snapshot = DeletedInput(text: text, selection: NSRange(location: before.utf16.count, length: selected.utf16.count))
        if !selected.isEmpty { insert("") }
        if !after.isEmpty { moveCursor(after.count) }
        for _ in before + after { deleteBackward() }
        return snapshot
    }
    func restoreInput(_ value: DeletedInput) -> Bool {
        guard hostState.snapshot.document != "disconnected" else { return false }
        insert(value.text)
        let prefix = (value.text as NSString).substring(to: min(value.selection.location, value.text.utf16.count))
        moveCursor(prefix.count - value.text.count)
        return true
    }
}
