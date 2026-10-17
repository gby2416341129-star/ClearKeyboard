import UIKit

@objc(ClearKeyboardViewController)
final class KeyboardViewController: UIInputViewController, KeyboardDocument {
    private var model: KeyboardModel!
    private var surface: KeyboardSurface!
    private var heightConstraint: NSLayoutConstraint?
    private var documentID: UUID?
    private var previousContext = ""
    private var expectedContext: String?
    private var recentOwnContexts: [String] = []
    private var trackpad: ProxyTrackpad?
    private var heightRefreshQueued = false
    private var heightRefreshSignatures = Set<String>()
    private var isPresented = false

    override func loadView() {
        let keyboard = KeyboardInputView()
        inputView = keyboard; view = keyboard
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        inputView?.allowsSelfSizing = true
        model = KeyboardModel(document: self)
        surface = KeyboardSurface(model: model, systemBacked: true)
        surface.configureGlobe = { [weak self] button in
            guard let self else { return }
            button.addTarget(self, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        view.addSubview(surface)
        surface.onHeightChange = { [weak self] height in self?.updateHeight(height) }
        updateHeight(surface.desiredHeight)
        documentID = connectedDocumentIdentifier()
        previousContext = contextBefore
    }
    override func viewWillAppear(_ animated: Bool) {
        isPresented = false; heightRefreshSignatures.removeAll()
        super.viewWillAppear(animated); model?.reloadSettings()
        if let surface { updateHeight(surface.desiredHeight) }
    }
    override func updateViewConstraints() {
        if let surface { updateHeight(surface.desiredHeight) }
        super.updateViewConstraints()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isPresented = true
        // A remote host can cache its default height before our input view is attached.
        // Negotiate once after attachment even when the desired height has not changed.
        queueHeightRefresh(force: true)
        model?.startClipboardCapture()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let surface else { return }
        // A cached host frame is provisional, especially when Safari changes input traits.
        // Keep the requested key pitch while UIKit negotiates the remote view's final height.
        // Squeezing the surface into that frame permanently changed both key size and font size.
        surface.frame = CGRect(x: view.bounds.minX, y: view.bounds.minY, width: max(0, view.bounds.width), height: surface.desiredHeight)
        updateHeight(surface.desiredHeight)
        if view.bounds.height + 0.5 < surface.desiredHeight { queueHeightRefresh() }
    }
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if let surface { updateHeight(surface.desiredHeight); queueHeightRefresh() }
    }
    private func queueHeightRefresh(force: Bool = false) {
        guard isPresented, !heightRefreshQueued, let surface, view.window != nil,
              force || view.bounds.height + 0.5 < surface.desiredHeight else { return }
        // Re-negotiate each distinct host geometry once, instead of exhausting two retries
        // before a later Safari address-bar / web-input transition. No timer or layout polling.
        let signature = "\(view.bounds.width.rounded())/\(view.bounds.height.rounded())/\(view.safeAreaInsets.bottom.rounded())/\(surface.desiredHeight)"
        guard heightRefreshSignatures.insert(signature).inserted else { return }
        heightRefreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightRefreshQueued = false
            guard self.isPresented, self.view.window != nil, let surface = self.surface else { return }
            UIView.performWithoutAnimation {
                self.heightConstraint?.isActive = false; self.heightConstraint = nil
                self.updateHeight(surface.desiredHeight)
                self.view.invalidateIntrinsicContentSize()
                self.view.setNeedsUpdateConstraints(); self.view.setNeedsLayout()
                self.view.superview?.setNeedsLayout()
                self.parent?.preferredContentSizeDidChange(forChildContentContainer: self)
            }
        }
    }
    private func updateHeight(_ height: CGFloat) {
        (view as? KeyboardInputView)?.contentHeight = height
        if heightConstraint == nil {
            let constraint = view.heightAnchor.constraint(equalToConstant: height)
            constraint.identifier = "clear.keyboard.content-height"
            constraint.priority = .required; constraint.isActive = true; heightConstraint = constraint
        } else if abs((heightConstraint?.constant ?? 0) - height) > 0.5 { heightConstraint?.constant = height }
        if abs(preferredContentSize.height - height) > 0.5 { preferredContentSize = CGSize(width: 0, height: height) }
    }
    override func viewWillDisappear(_ animated: Bool) {
        isPresented = false
        super.viewWillDisappear(animated); surface?.stopInteractions(); model?.finishCompositionAsTyped(); model?.suspend()
    }
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        guard let model, let surface else { return }
        // Remote context reads are synchronous. A drag only needs to send caret offsets;
        // reconcile the context once when the trackpad session ends.
        if model.isMovingCursor { return }
        let identifier = connectedDocumentIdentifier(), context = contextBefore
        if identifier != documentID {
            heightRefreshSignatures.removeAll(); updateHeight(surface.desiredHeight); queueHeightRefresh(force: true)
        }
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

/// UIKit explicitly asks this view for its fitting height when allowsSelfSizing is enabled.
final class KeyboardInputView: UIInputView {
    var contentHeight: CGFloat = KeyboardGeometry.preferredHeight() {
        didSet { if abs(contentHeight - oldValue) > 0.5 { invalidateIntrinsicContentSize() } }
    }
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: KeyboardGeometry.preferredHeight()), inputViewStyle: .keyboard)
        allowsSelfSizing = true; isOpaque = false; backgroundColor = .clear
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: contentHeight) }
    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        CGSize(width: targetSize.width, height: contentHeight)
    }
    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority: UILayoutPriority, verticalFittingPriority: UILayoutPriority) -> CGSize {
        systemLayoutSizeFitting(targetSize)
    }
}
