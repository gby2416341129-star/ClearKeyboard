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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        inputView?.allowsSelfSizing = true
        model = KeyboardModel(document: self)
        surface = KeyboardSurface(model: model)
        surface.configureGlobe = { [weak self] button in
            guard let self else { return }
            button.addTarget(self, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        view.addSubview(surface)
        surface.onHeightChange = { [weak self] height in self?.updateHeight(height) }
        let constraint = view.heightAnchor.constraint(equalToConstant: surface.desiredHeight)
        constraint.priority = .init(999); constraint.isActive = true; heightConstraint = constraint
        documentID = connectedDocumentIdentifier()
        previousContext = contextBefore
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); model?.reloadSettings()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); model?.startClipboardCapture() }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let surface else { return }
        surface.frame = CGRect(x: 0, y: 0, width: max(0, view.bounds.width), height: max(0, view.bounds.height - view.safeAreaInsets.bottom))
        updateHeight(surface.desiredHeight)
    }
    private func updateHeight(_ height: CGFloat) {
        let newHeight = height + view.safeAreaInsets.bottom
        if abs((heightConstraint?.constant ?? 0) - newHeight) > 0.5 { heightConstraint?.constant = newHeight }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated); surface?.stopInteractions(); model?.finishCompositionAsTyped(); model?.suspend()
    }
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        guard let model, let surface else { return }
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
        previousContext = contextBefore; expectedContext = previousContext
    }
    func nextKeyboard() { advanceToNextInputMode() }
    private func rememberOwnContext(_ context: String?) {
        guard let context else { return }
        recentOwnContexts.append(context)
        if recentOwnContexts.count > 32 { recentOwnContexts.removeFirst(recentOwnContexts.count - 32) }
    }
}
