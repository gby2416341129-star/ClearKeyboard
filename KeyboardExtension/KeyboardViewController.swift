import UIKit
import os

@objc(ClearKeyboardViewController)
class KeyboardViewController: UIInputViewController, KeyboardDocument {
    private var model: KeyboardModel!
    private var surface: KeyboardSurface!
#if DEBUG
    // Test evidence from the actual extension process, without exposing typed
    // content or replacing the root's accessible key hierarchy with a leaf.
    private let runtimeProbe = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private var runtimeTimer: Timer?
#endif
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
    private var sentMarkedDraft = false
    private enum MarkedTransport: Equatable { case none, local, host }
    // Context getters may temporarily return nil in ordinary native fields.
    // They do not establish whether a field supports marked text. Only the
    // explicitly enabled compatibility option keeps spelling inside the keyboard.
    private var markedTransport = MarkedTransport.none
    private var markedDraft = ""
    private var readableHostContext = false
    private var hostRefreshGeneration = 0
    private var activeKeys = 0
    private var hostActive = true
    private var needsHostRefresh = false
    private var candidateSelectionNeedsValidation = false
    private var hostWriteDepth = 0
    private var hostNotificationRevision = 0
    private var deferredMarkedFlush = false
    private var trackpad: ProxyTrackpad?
    private var clipboardSelectionActive = false
    private var clipboardSelectionIdentity: String?
    private var lastLayoutLog = ""
    private var layoutLogCount = 0
    private let hostLog = OSLog(subsystem: "ClearKeyboard", category: "HostWrite")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear; view.isOpaque = false
        view.accessibilityIdentifier = "clear.keyboard.root"
#if DEBUG
        runtimeProbe.isUserInteractionEnabled = false
        runtimeProbe.isAccessibilityElement = true
        runtimeProbe.accessibilityIdentifier = "clear.keyboard.runtime"
        runtimeProbe.accessibilityLabel = "Keyboard runtime evidence"
        view.addSubview(runtimeProbe)
#endif
        inputView?.allowsSelfSizing = false
        refreshHostState(refreshTraits: true)
        // Only the real extension acknowledges an App appearance revision.
        // App previews and hosted test models must not produce that receipt.
        let appearanceLink: AppearanceSettingsLink? = Bundle.main.bundleURL.pathExtension == "appex"
            ? .production(role: .keyboard) : nil
        model = KeyboardModel(document: self, appearanceLink: appearanceLink)
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
        model?.refreshAppearanceConnection()
        model?.startClipboardCapture()
#if DEBUG
        runtimeTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRuntimeEvidence() }
        }
        runtimeTimer = timer; RunLoop.main.add(timer, forMode: .default)
#endif
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
#if DEBUG
        updateRuntimeEvidence()
#endif
    }
#if DEBUG
    private func updateRuntimeEvidence() {
        runtimeProbe.frame = CGRect(x: view.bounds.midX, y: 1, width: 1, height: 1)
        view.bringSubviewToFront(runtimeProbe)
        func rect(_ value: CGRect) -> [Double] {
            [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)]
        }
        let inset = view.safeAreaInsets
        var evidence: [String: Any] = [
            "bundleExtension": Bundle.main.bundleURL.pathExtension,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "pid": ProcessInfo.processInfo.processIdentifier,
            "hostActive": hostActive,
            "rootBounds": rect(view.bounds),
            "windowBounds": rect(view.window?.bounds ?? .zero),
            "safeAreaInsets": [Double(inset.top), Double(inset.left), Double(inset.bottom), Double(inset.right)]
        ]
        if let model {
            if let data = try? JSONEncoder().encode(AppearanceSnapshot(settings: model.settings)),
               let settings = try? JSONSerialization.jsonObject(with: data) { evidence["settings"] = settings }
            evidence["fullAccess"] = hasFullAccess
            evidence["sharedContainerAvailable"] = SharedStorage.applicationGroup() != nil
            evidence["clipboardItems"] = ClipboardStore(url: SharedStorage.clipboardURL(allowShared: hasFullAccess)).clips.count
            evidence["submittedHapticPulses"] = KeyboardVibration.shared.submittedPulses
        }
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]),
           let value = String(data: data, encoding: .utf8) {
            runtimeProbe.accessibilityValue = value
        }
    }
#endif
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
#if DEBUG
        runtimeTimer?.invalidate(); runtimeTimer = nil
#endif
        hostRefreshGeneration += 1; hostRefresh?.invalidate(); hostRefresh = nil
        super.viewWillDisappear(animated); surface?.stopInteractions()
        // Dismissing the keyboard is not an explicit request to send a local
        // spelling to an unreadable remote editor.
        if markedTransport == .local { abandonDraftWithoutHostWrite() }
        else { model?.finishCompositionAsTyped() }
        model?.suspend()
    }
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        hostNotificationRevision += 1
        if model?.isMovingCursor == true { return }
        // Even the identity getter can cross the remote-host boundary. A text
        // acknowledgement must not do synchronous proxy reads in a key's frame.
        needsHostRefresh = true
        scheduleHostRefresh()
    }
    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        hostNotificationRevision += 1
        guard model?.isMovingCursor != true else { return }
        candidateSelectionNeedsValidation = true
        // Reconcile the captured selection/UUID before using an old candidate.
        // Nil/nil clients may deliver a delayed acknowledgement of a partial
        // insertion here; a notification alone cannot identify a moved caret.
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
        guard hostActive, activeKeys == 0, hostWriteDepth == 0 else { return }
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
    private func readHostSnapshot() -> (snapshot: HostTextSnapshot, connected: Bool) {
        // A temporarily unavailable remote identifier is not evidence that the
        // user switched fields. Treating nil as a new "disconnected" document
        // unmarked long input and cleared its candidates before a tap committed.
        guard let identifier = connectedDocumentIdentifier()?.uuidString else {
            var unavailable = hostState.snapshot
            unavailable.available = false
            return (unavailable, false)
        }
        let before = textDocumentProxy.documentContextBeforeInput
        let after = textDocumentProxy.documentContextAfterInput
        return (HostTextSnapshot(before: before ?? "", after: after ?? "", selected: textDocumentProxy.selectedText ?? "",
            document: identifier, available: before != nil || after != nil), true)
    }
    private func refreshHostState(refreshTraits: Bool = false) {
        guard hostWriteDepth == 0 else { needsHostRefresh = true; return }
        needsHostRefresh = false
        let revision = hostRefreshGeneration
        let read = readHostSnapshot(), actual = read.snapshot
        // A remote getter may service UIKit callbacks before returning. A key
        // or another notification in that interval invalidates this read; it
        // cannot cancel a newer spelling or unmark its first letter.
        guard revision == hostRefreshGeneration else {
            needsHostRefresh = true; scheduleHostRefresh(); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let wasReadable = readableHostContext
        if read.connected { readableHostContext = actual.available }
        let outcome: HostTextState.Reconciliation
        if read.connected && !actual.available && !actual.selected.isEmpty {
            hostState = HostTextState(actual); outcome = .externalEdit
        } else if read.connected, (!wasReadable || !hostState.snapshot.available), actual.available, actual.selected.isEmpty,
                  actual.document == hostState.snapshot.document, !markedDraft.isEmpty,
                  markedTransport == .local || actual.before.hasSuffix(markedDraft) {
            // Native fields can first expose their real surrounding text only
            // after marking starts. Adopt that boundary without committing or
            // dropping the visible spelling and its Chinese candidates.
            rebaseDraft(on: actual)
            outcome = .compositionContextChanged
        } else { outcome = hostState.reconcile(actual, now: now) }
        guard outcome != .unavailable else {
            // No context is not an external edit or a reason to switch modes.
            if !read.connected { needsHostRefresh = true; scheduleHostRefresh() }
            return
        }
        candidateSelectionNeedsValidation = hostState.shouldRecheck(actual, now: now)
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
            discardMarkedDelivery()
            surface?.closePanel(); model?.cursorChanged(unmarkDraft: false)
            model?.documentTraitsChanged()
        }
        if case .compositionContextChanged = outcome { model?.refreshCandidates() }
        // A differing snapshot may be an old acknowledgement, but it can also
        // be an external clear that happens to restore an earlier value. Read
        // again after the pending edit lease instead of retaining that stale
        // local text indefinitely. Hosts omitting a live marked range are exempt.
        if case .ownEdit = outcome, hostState.shouldRecheck(actual, now: now) {
            needsHostRefresh = true; scheduleHostRefresh()
        }
    }
    func validateCandidate(before: String, after: String, identity: String) -> Bool {
        guard hostWriteDepth == 0 else { return false }
        // The candidate's generation and local edit snapshot have already been
        // checked. Reading whole remote contexts on touch-up both blocks UIKit
        // and rejects hosts that omit the active marked range from their context.
        guard hostState.snapshot.selected.isEmpty, before == contextBefore, after == contextAfter,
              identity == documentIdentity else { return false }
        let revision = hostRefreshGeneration
        // Do not destroy an active draft on a transient nil response. A real,
        // different UUID still forces the normal external-field reconciliation.
        guard let actualIdentity = connectedDocumentIdentifier()?.uuidString else {
            needsHostRefresh = true; scheduleHostRefresh(); return false
        }
        guard actualIdentity == identity else { refreshHostState(); return false }
        // A selection notification can precede the idle reconciliation. An old
        // candidate must not clear a new selection or insert at a moved caret
        // in the same field. Only this unresolved selection case needs context
        // reads on a tap; ordinary keys/results still do no synchronous reads.
        if candidateSelectionNeedsValidation {
            let actualBefore = textDocumentProxy.documentContextBeforeInput
            let actualAfter = textDocumentProxy.documentContextAfterInput
            let actualSelected = textDocumentProxy.selectedText ?? ""
            let actual = HostTextSnapshot(before: actualBefore ?? "", after: actualAfter ?? "",
                selected: actualSelected, document: actualIdentity,
                available: actualBefore != nil || actualAfter != nil)
            guard revision == hostRefreshGeneration else { return false }
            let wasReadable = readableHostContext
            readableHostContext = actual.available
            if (!wasReadable || !hostState.snapshot.available), actual.available, actualSelected.isEmpty,
               markedTransport == .local || (!markedDraft.isEmpty && actual.before.hasSuffix(markedDraft)) {
                rebaseDraft(on: actual)
                if markedTransport == .host {
                    // The host just exposed the exact native draft being
                    // selected. Its newly readable prefix does not invalidate
                    // that choice or require the user to tap twice.
                    candidateSelectionNeedsValidation = false
                    return true
                }
                model?.refreshCandidates()
                return false // The old ribbon describes the previous boundary.
            }
            guard actualSelected.isEmpty,
                  !actual.available || hostState.accepts(hostState.snapshot, actual: actual) else {
                needsHostRefresh = true; scheduleHostRefresh(); return false
            }
            candidateSelectionNeedsValidation = false
        }
        guard revision == hostRefreshGeneration else { return false }
        return hostState.snapshot.selected.isEmpty && before == contextBefore &&
            after == contextAfter && identity == documentIdentity
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
    var usesLocalPinyinComposition: Bool {
        if markedTransport != .none { return markedTransport == .local }
        return model?.settings.localPinyinComposition == true
    }
    var fullAccess: Bool { hasFullAccess }
    var needsGlobe: Bool { hostNeedsGlobe }
    var capitalization: UITextAutocapitalizationType { hostCapitalization }
    var prefersEnglish: Bool { hostPrefersEnglish }
    var enterTitle: String { hostEnterTitle }
    private func beginHostWrite() {
        hostWriteDepth += 1
        hostRefreshGeneration += 1; hostRefresh?.invalidate(); hostRefresh = nil
    }
    private func endHostWrite() {
        hostWriteDepth -= 1
        guard hostWriteDepth == 0 else { return }
        if deferredMarkedFlush {
            deferredMarkedFlush = false
            DispatchQueue.main.async { [weak self] in self?.flushMarkedText() }
        }
        if needsHostRefresh { scheduleHostRefresh() }
    }
    private func performHostEdit(_ edit: () -> Void) {
        // A key arriving before the idle timer fires must cancel that read even
        // if its own textDidChange acknowledgement has not arrived yet.
        beginHostWrite(); defer { endHostWrite() }
        flushMarkedText(insideWrite: true)
        edit()
    }
    func insert(_ text: String) {
        performHostEdit {
            hostState.insert(text)
            markedDraft = ""; markedTransport = .none; sentMarkedDraft = false
            textDocumentProxy.insertText(text)
        }
    }
    func validateClipboardSelection(before: String, after: String, identity: String) -> Bool {
        guard hostWriteDepth == 0 else { return false }
        let read = readHostSnapshot()
        let expected = HostTextSnapshot(before: before, after: after, document: identity)
        return read.connected && HostTextState(expected).accepts(expected, actual: read.snapshot)
    }
    func replaceClipboardSelection(_ text: String, previous: String) -> Bool {
        guard previous.isEmpty || clipboardSelectionActive,
              !clipboardSelectionActive || markedDraft == previous else { return false }
        let identity = documentIdentity
        beginHostWrite(); defer { endHostWrite() }
        cancelQueuedMarkedWrites()
        // Let the host replace its own provisional range in one operation.
        // No cursor guessing or deleteBackward loop can reach pre-existing text.
        markedTransport = .host; markedDraft = text; clipboardSelectionActive = true
        clipboardSelectionIdentity = identity
        hostState.setMarked(text); sentMarkedDraft = !text.isEmpty
        textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
        let read = readHostSnapshot(), expected = hostState.snapshot
        guard read.connected, read.snapshot.document == identity,
              HostTextState(expected).accepts(expected, actual: read.snapshot) else {
            if read.connected, read.snapshot.document == identity { textDocumentProxy.unmarkText() }
            clipboardSelectionActive = false; discardMarkedDelivery()
            if read.connected { hostState = HostTextState(read.snapshot) }
            needsHostRefresh = true
            model?.onNotice?("当前输入框未接受完整选词，请重新选择或直接粘贴")
            return false
        }
        return true
    }
    func finishClipboardSelection() {
        guard clipboardSelectionActive else { return }
        clipboardSelectionActive = false
        guard connectedDocumentIdentifier()?.uuidString == clipboardSelectionIdentity else { discardMarkedDelivery(); return }
        beginHostWrite(); defer { endHostWrite() }
        textDocumentProxy.unmarkText(); hostState.unmark(); discardMarkedDelivery()
    }
    func commitMarkedText(_ text: String) {
        commitMarkedText(text, remaining: "")
    }
    @discardableResult func commitMarkedText(_ text: String, remaining: String) -> Bool {
        // Space, punctuation and mode changes can commit without a ribbon tap.
        // Give those entry points the same unresolved-selection protection.
        if candidateSelectionNeedsValidation,
           !validateCandidate(before: contextBefore, after: contextAfter, identity: documentIdentity) {
            abandonDraftWithoutHostWrite()
            return false
        }
        beginHostWrite(); defer { endHostWrite() }
        let originalState = hostState, notifications = hostNotificationRevision
        cancelQueuedMarkedWrites()
        // Clear only the provisional range we actually sent. Buffered editors
        // can otherwise flush its raw pinyin along with insertText's Chinese.
        // unmarkText would commit that pinyin; deleting host text is unsafe.
        let transport = markedTransport == .none ? (usesLocalPinyinComposition ? MarkedTransport.local : .host) : markedTransport
        hostState.commitMarked(text, remaining: remaining)
        markedDraft = remaining
        markedTransport = remaining.isEmpty ? .none : transport
        if sentMarkedDraft {
            sentMarkedDraft = false
            textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        }
        if !hostActive || (notifications != hostNotificationRevision && !hostStillMatches(originalState, requiresReadable: transport == .host)) {
            // A proxy can service a field switch inside its synchronous call.
            // Neither the old choice nor its remainder belongs to that field;
            // in particular, do not unmark the new field's own provisional text.
            hostState = originalState; abandonDraftWithoutHostWrite()
            needsHostRefresh = true
            return false
        }
        let insertionNotifications = hostNotificationRevision
        textDocumentProxy.insertText(text)
        if !hostActive || (insertionNotifications != hostNotificationRevision && !hostStillMatches(hostState, requiresReadable: transport == .host)) {
            abandonDraftWithoutHostWrite(); needsHostRefresh = true
            return false
        }
        if !remaining.isEmpty, transport == .host { enqueueMarkedText(remaining) }
        return true
    }
    private func hostStillMatches(_ expected: HostTextState, requiresReadable: Bool) -> Bool {
        let revision = hostNotificationRevision
        guard let identity = connectedDocumentIdentifier()?.uuidString,
              identity == expected.snapshot.document else { return false }
        let before = textDocumentProxy.documentContextBeforeInput
        let after = textDocumentProxy.documentContextAfterInput
        let selected = textDocumentProxy.selectedText ?? ""
        let actual = HostTextSnapshot(before: before ?? "", after: after ?? "", selected: selected,
            document: identity, available: before != nil || after != nil)
        // A reported field/selection change still aborts the transaction. A
        // temporarily missing context alone must not turn native pinyin literal.
        guard revision == hostNotificationRevision else { return false }
        let wasReadable = readableHostContext
        readableHostContext = actual.available
        if !requiresReadable, !wasReadable, actual.available, selected.isEmpty {
            // The client first exposed its real boundary while acknowledging
            // our selected Chinese. Keep the remainder local at that boundary.
            rebaseDraft(on: actual)
            return true
        }
        // Native fields can temporarily omit context while processing our own
        // mark/insert callbacks. A stable field with no reported selection must
        // retain its composition; nil is not a failed marked-text transaction.
        return selected.isEmpty && (!actual.available || !expected.snapshot.available || expected.accepts(expected.snapshot, actual: actual))
    }
    func setMarkedText(_ text: String) {
        hostRefreshGeneration += 1; hostRefresh?.invalidate(); hostRefresh = nil
        if markedTransport == .none, !text.isEmpty {
            markedTransport = usesLocalPinyinComposition ? .local : .host
        }
        markedDraft = text
        hostState.setMarked(text)
        if markedTransport == .host { enqueueMarkedText(text) }
        else { cancelQueuedMarkedWrites() }
    }
    private func cancelQueuedMarkedWrites() {
        markedFrame.cancel(); pendingMarkedText.discard()
        markedImmediateScheduled = false; markedWriteGeneration += 1
        deferredMarkedFlush = false
    }
    private func discardMarkedDelivery() {
        clipboardSelectionActive = false; clipboardSelectionIdentity = nil
        cancelQueuedMarkedWrites()
        markedDraft = ""; markedTransport = .none; sentMarkedDraft = false
    }
    private func abandonDraftWithoutHostWrite() {
        hostRefreshGeneration += 1
        discardMarkedDelivery()
        hostState.setMarked(""); hostState.unmark()
        model?.cursorChanged(unmarkDraft: false)
    }
    private func rebaseDraft(on actual: HostTextSnapshot) {
        var boundary = actual
        if markedTransport == .host, !markedDraft.isEmpty, boundary.before.hasSuffix(markedDraft) {
            boundary.before.removeLast(markedDraft.count)
        }
        hostState = HostTextState(boundary)
        if !markedDraft.isEmpty { hostState.setMarked(markedDraft) }
    }
    private func enqueueMarkedText(_ text: String) {
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
    private func flushMarkedText(insideWrite: Bool = false) {
        if hostWriteDepth > 0, !insideWrite { deferredMarkedFlush = true; return }
        // Commit, deletion, cursor movement and unmark are ordered barriers.
        // No pending spelling frame may run after those edits.
        markedFrame.cancel()
        markedImmediateScheduled = false; markedWriteGeneration += 1
        guard let text = pendingMarkedText.take() else { return }
        beginHostWrite(); defer { endHostWrite() }
        let event = OSSignpostID(log: hostLog)
        os_signpost(.begin, log: hostLog, name: "MarkedTextWrite", signpostID: event, "utf16=%d", text.utf16.count)
        defer { os_signpost(.end, log: hostLog, name: "MarkedTextWrite", signpostID: event) }
        sentMarkedDraft = !text.isEmpty
        textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
        markedCadence.didWrite(now: ProcessInfo.processInfo.systemUptime)
    }
    func unmarkText() {
        if markedTransport == .local {
            if !markedDraft.isEmpty { commitMarkedText(markedDraft, remaining: "") }
            else { hostState.unmark(); discardMarkedDelivery() }
            return
        }
        performHostEdit {
            hostState.unmark(); markedDraft = ""; markedTransport = .none
            textDocumentProxy.unmarkText(); sentMarkedDraft = false
        }
    }
    func deleteBackward() { performHostEdit { hostState.deleteBackward(); textDocumentProxy.deleteBackward() } }
    func moveCursor(_ offset: Int) {
        performHostEdit {
            let before = contextBefore, selected = selectedText, after = contextAfter
            let units: Int
            if selected.isEmpty {
                units = offset < 0 ? -String(before.suffix(-offset)).utf16.count : String(after.prefix(offset)).utf16.count
            } else {
                let whole = before + selected + after
                let target = max(0, min(whole.count, before.count + offset))
                units = String(whole.prefix(target)).utf16.count - before.utf16.count - selected.utf16.count
            }
            hostState.moveCursor(offset); textDocumentProxy.adjustTextPosition(byCharacterOffset: units)
        }
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
        let read = readHostSnapshot()
        guard read.connected, read.snapshot.available,
              HostTextState(hostState.snapshot).accepts(hostState.snapshot, actual: read.snapshot) else { return nil }
        let before = contextBefore, selected = selectedText, after = contextAfter
        let text = before + selected + after
        guard !text.isEmpty, text.count <= 4_096 else { return nil }
        let snapshot = DeletedInput(text: text, selection: NSRange(location: before.utf16.count, length: selected.utf16.count))
        if !selected.isEmpty { insert("") }
        if !after.isEmpty { moveCursor(after.count) }
        for _ in before + after { deleteBackward() }
        return snapshot
    }
    func clearInput(completion: @escaping (DeletedInput?) -> Void) {
        let read = readHostSnapshot(), identity = documentIdentity
        guard read.connected, read.snapshot.available,
              HostTextState(hostState.snapshot).accepts(hostState.snapshot, actual: read.snapshot) else { completion(nil); return }
        let before = contextBefore, selected = selectedText, after = contextAfter
        let text = before + selected + after
        guard !text.isEmpty, text.utf8.count <= ClipboardStore.textLimit else { completion(nil); return }
        let value = DeletedInput(text: text, selection: NSRange(location: before.utf16.count, length: selected.utf16.count))
        if !selected.isEmpty { insert("") }
        if !after.isEmpty { moveCursor(after.count) }
        func abort() { refreshHostState(refreshTraits: true); completion(nil) }
        func step(_ remaining: Int) {
            guard connectedDocumentIdentifier()?.uuidString == identity else { abort(); return }
            let actual = readHostSnapshot()
            guard actual.connected, HostTextState(hostState.snapshot).accepts(hostState.snapshot, actual: actual.snapshot) else { abort(); return }
            let count = min(32, remaining)
            for _ in 0..<count {
                guard connectedDocumentIdentifier()?.uuidString == identity else { abort(); return }
                deleteBackward()
            }
            if remaining > count { DispatchQueue.main.async { step(remaining - count) } }
            else {
                let final = readHostSnapshot()
                guard final.connected, final.snapshot.document == identity,
                      final.snapshot.before.isEmpty, final.snapshot.after.isEmpty, final.snapshot.selected.isEmpty else { completion(nil); return }
                completion(value)
            }
        }
        step(before.count + after.count)
    }
    func restoreInput(_ value: DeletedInput) -> Bool {
        let read = readHostSnapshot()
        guard read.connected, read.snapshot.available, read.snapshot.before.isEmpty,
              read.snapshot.after.isEmpty, read.snapshot.selected.isEmpty,
              read.snapshot.document == documentIdentity else { return false }
        let length = value.text.utf16.count
        guard value.selection.location <= length, NSMaxRange(value.selection) <= length else { return false }
        beginHostWrite(); defer { endHostWrite() }
        textDocumentProxy.setMarkedText(value.text, selectedRange: value.selection)
        textDocumentProxy.unmarkText()
        let actual = readHostSnapshot()
        guard actual.connected, actual.snapshot.document == read.snapshot.document else { return false }
        hostState = HostTextState(actual.snapshot); discardMarkedDelivery()
        let ns = value.text as NSString
        return actual.snapshot.before.hasSuffix(ns.substring(to: value.selection.location)) &&
            actual.snapshot.selected == ns.substring(with: value.selection) &&
            actual.snapshot.after.hasPrefix(ns.substring(from: NSMaxRange(value.selection)))
    }
}
