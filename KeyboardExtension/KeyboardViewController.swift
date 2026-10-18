import UIKit

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
    private var trackpad: ProxyTrackpad?
    private var lastLayoutLog = ""
    private var layoutLogCount = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear; view.isOpaque = false
        view.accessibilityIdentifier = "clear.keyboard.root"
        inputView?.allowsSelfSizing = false
        refreshHostState()
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
        super.viewWillAppear(animated); refreshHostState(); model?.reloadSettings()
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
        surface.layoutIfNeeded()
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
        super.viewWillDisappear(animated); surface?.stopInteractions(); model?.finishCompositionAsTyped(); model?.suspend()
    }
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if model?.isMovingCursor == true { return }
        refreshHostState()
    }
    private func readHostSnapshot() -> HostTextSnapshot {
        let before = textDocumentProxy.documentContextBeforeInput
        let after = textDocumentProxy.documentContextAfterInput
        return HostTextSnapshot(before: before ?? "", after: after ?? "", selected: textDocumentProxy.selectedText ?? "",
            document: connectedDocumentIdentifier()?.uuidString ?? "disconnected", available: before != nil || after != nil)
    }
    private func refreshHostState() {
        let outcome = hostState.reconcile(readHostSnapshot())
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
        if case .externalEdit = outcome { surface?.closePanel(); model?.cursorChanged() }
    }
    func validateCandidate(before: String, after: String, identity: String) -> Bool {
        let expected = HostTextSnapshot(before: before, after: after, document: identity)
        let actual = readHostSnapshot()
        let valid = hostState.accepts(expected, actual: actual)
        if !valid { refreshHostState() }
        return valid
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
    func insert(_ text: String) { hostState.insert(text); textDocumentProxy.insertText(text) }
    func setMarkedText(_ text: String) {
        hostState.setMarked(text)
        textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
    }
    func unmarkText() { hostState.unmark(); textDocumentProxy.unmarkText() }
    func deleteBackward() { hostState.deleteBackward(); textDocumentProxy.deleteBackward() }
    func moveCursor(_ offset: Int) {
        hostState.moveCursor(offset); textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
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
