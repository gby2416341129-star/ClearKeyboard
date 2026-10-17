import UIKit

@objc(ClearKeyboardViewController)
final class KeyboardViewController: UIInputViewController, KeyboardDocument {
    private var model: KeyboardModel!
    private var surface: KeyboardSurface!
    private var heightConstraint: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?
    private var surfaceHeightConstraint: NSLayoutConstraint?
    private var documentID: UUID?
    private var previousContext = ""
    private var expectedContext: String?
    private var recentOwnContexts: [String] = []
    private var trackpad: ProxyTrackpad?
    private var lastLayoutLog = ""
    private var layoutLogCount = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear; view.isOpaque = false
        view.accessibilityIdentifier = "clear.keyboard.root"
        inputView?.allowsSelfSizing = false
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
        documentID = connectedDocumentIdentifier()
        previousContext = contextBefore
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); model?.reloadSettings()
        if let surface { updateHeight(surface.desiredHeight) }
    }
    override func updateViewConstraints() {
        if let surface { updateHeight(surface.desiredHeight) }
        super.updateViewConstraints()
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
        let hostWidth = view.window?.bounds.width ?? view.bounds.width
        guard hostWidth.isFinite, hostWidth > 0 else { return }
        // Resolve both axes before enabling UIKit's native self-sizing. A zero-width
        // fitting result cannot be hosted; a mask-derived height preserves a stale frame.
        // The surface uses constraints too, so its temporary frame never becomes a sizing input.
        view.translatesAutoresizingMaskIntoConstraints = false
        if widthConstraint == nil {
            let constraint = view.widthAnchor.constraint(equalToConstant: hostWidth)
            constraint.identifier = "clear.keyboard.system-width"; constraint.isActive = true; widthConstraint = constraint
        } else if abs((widthConstraint?.constant ?? 0) - hostWidth) > 0.5 { widthConstraint?.constant = hostWidth }
        if heightConstraint == nil {
            let constraint = view.heightAnchor.constraint(equalToConstant: height)
            constraint.identifier = "clear.keyboard.content-height"
            constraint.priority = .required; constraint.isActive = true; heightConstraint = constraint
        } else if abs((heightConstraint?.constant ?? 0) - height) > 0.5 { heightConstraint?.constant = height }
        if inputView?.allowsSelfSizing != true { inputView?.allowsSelfSizing = true }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated); surface?.stopInteractions(); model?.finishCompositionAsTyped(); model?.suspend()
    }
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        guard let model, let surface else { return }
        // Remote context reads are synchronous. A drag only needs to send caret offsets;
        // reconcile the context once when the trackpad session ends.
        if model.isMovingCursor { return }
        let identifier = connectedDocumentIdentifier(), context = contextBefore
        if identifier != documentID || (context != previousContext && context != expectedContext && !recentOwnContexts.contains(context)) {
            recentOwnContexts.removeAll()
            surface.closePanel(); model.cursorChanged()
        } else if model.composition.isEmpty { model.refreshCandidates() }
        documentID = identifier; previousContext = context; expectedContext = nil
    }
    private func connectedDocumentIdentifier() -> UUID? {
        // UIKit can return nil before connecting the host, despite its nonoptional Swift UUID declaration.
        // Call the public Objective-C getter so the absent value stays optional during bridging.
        let getter = #selector(getter: UITextDocumentProxy.documentIdentifier)
        guard let proxy = textDocumentProxy as? NSObject, proxy.responds(to: getter) else { return nil }
        return proxy.perform(getter)?.takeUnretainedValue() as? UUID
    }
    var contextBefore: String { textDocumentProxy.documentContextBeforeInput ?? "" }
    var contextAfter: String { textDocumentProxy.documentContextAfterInput ?? "" }
    var documentIdentity: String { connectedDocumentIdentifier()?.uuidString ?? "disconnected" }
    var selectedText: String { textDocumentProxy.selectedText ?? "" }
    var fullAccess: Bool { hasFullAccess }
    var needsGlobe: Bool { needsInputModeSwitchKey }
    var capitalization: UITextAutocapitalizationType { textDocumentProxy.autocapitalizationType ?? .sentences }
    var prefersEnglish: Bool {
        switch textDocumentProxy.keyboardType ?? .default {
        case .emailAddress, .URL, .asciiCapable, .asciiCapableNumberPad: return true
        default: return false
        }
    }
    var enterTitle: String {
        switch textDocumentProxy.returnKeyType ?? .default {
        case .send: return "发送"
        case .search, .google, .yahoo: return "搜索"
        case .go: return "前往"
        case .done: return "完成"
        case .next: return "下一项"
        case .join: return "加入"
        default: return "换行"
        }
    }
    func insert(_ text: String) {
        expectedContext = contextBefore + text
        rememberOwnContext(expectedContext)
        textDocumentProxy.insertText(text); previousContext = contextBefore
        rememberOwnContext(previousContext)
    }
    private var markedSpelling = ""
    func setMarkedText(_ text: String) {
        let context = contextBefore
        let prefix = !markedSpelling.isEmpty && context.hasSuffix(markedSpelling) ? String(context.dropLast(markedSpelling.count)) : context
        expectedContext = prefix + text
        rememberOwnContext(expectedContext)
        textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
        markedSpelling = text; previousContext = contextBefore
        rememberOwnContext(previousContext)
    }
    func unmarkText() { textDocumentProxy.unmarkText(); markedSpelling = ""; previousContext = contextBefore }
    func deleteBackward() {
        expectedContext = String(contextBefore.dropLast())
        rememberOwnContext(expectedContext)
        textDocumentProxy.deleteBackward(); previousContext = contextBefore
        rememberOwnContext(previousContext)
    }
    func moveCursor(_ offset: Int) {
        textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
        if model?.isMovingCursor == true { return }
        previousContext = contextBefore; expectedContext = previousContext
    }
    func beginTrackpad() { trackpad = ProxyTrackpad(before: contextBefore, after: contextAfter) }
    func trackCursor(translation: CGPoint) {
        guard var state = trackpad else { return }
        let offset = state.offset(translation: translation); trackpad = state
        if offset != 0 { moveCursor(offset) }
    }
    func endTrackpad() {
        trackpad = nil; documentID = connectedDocumentIdentifier()
        previousContext = contextBefore; expectedContext = previousContext
        rememberOwnContext(previousContext)
    }
    func nextKeyboard() { advanceToNextInputMode() }
    func clearInput() -> DeletedInput? {
        guard connectedDocumentIdentifier() != nil else { return nil }
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
        guard connectedDocumentIdentifier() != nil else { return false }
        insert(value.text)
        let prefix = (value.text as NSString).substring(to: min(value.selection.location, value.text.utf16.count))
        moveCursor(prefix.count - value.text.count)
        return true
    }
    private func rememberOwnContext(_ context: String?) {
        guard let context else { return }
        recentOwnContexts.append(context)
        if recentOwnContexts.count > 32 { recentOwnContexts.removeFirst(recentOwnContexts.count - 32) }
    }
}
