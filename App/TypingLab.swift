import SwiftUI
import UIKit

struct TypingLab: UIViewControllerRepresentable {
    var settings: KeyboardSettings
    func makeUIViewController(context: Context) -> TypingLabController {
        let controller = TypingLabController(settings: settings)
        controller.loadViewIfNeeded()
        return controller
    }
    func updateUIViewController(_ controller: TypingLabController, context: Context) {
        controller.applyExternalSettings(settings)
    }
}

final class TypingLabController: UIViewController, KeyboardDocument, UITextViewDelegate {
    let documentIdentity = UUID().uuidString
    let textView = UITextView()
    private let placeholder = UILabel()
    var model: KeyboardModel!
    private var surface: KeyboardSurface!
    private var initialSettings: KeyboardSettings
    private var editingInternally = false
    private var lastSelection = NSRange(location: NSNotFound, length: 0)
    private var lastText = ""
    private var trackpadAnchor: CGPoint?
    init(settings: KeyboardSettings) { initialSettings = settings; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        textView.font = .systemFont(ofSize: 20); textView.backgroundColor = .clear
        textView.textColor = .label; textView.tintColor = initialSettings.accentColor
        textView.text = ""
        textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 12, right: 14)
        textView.inputView = UIView(frame: .zero)
        textView.autocorrectionType = .no; textView.spellCheckingType = .no
        textView.delegate = self; textView.accessibilityLabel = "输入体验区"
        rememberSelection()
        view.addSubview(textView)
        placeholder.text = "试试输入 nihao 或 hello"; placeholder.font = .systemFont(ofSize: 14)
        placeholder.textColor = .tertiaryLabel; placeholder.isUserInteractionEnabled = false; view.addSubview(placeholder)
        model = KeyboardModel(document: self, settings: initialSettings)
        surface = KeyboardSurface(model: model); view.addSubview(surface)
        surface.onHeightChange = { [weak self] _ in
            guard let self else { return }
            self.placeholder.isHidden = !(self.textView.text ?? "").isEmpty || !self.model.composition.isEmpty
            self.view.setNeedsLayout()
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let surface, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let height = min(surface.desiredHeight, max(0, view.bounds.height - 64))
        textView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height - height)
        placeholder.frame = CGRect(x: 16, y: 17, width: max(0, view.bounds.width - 32), height: 22)
        surface.frame = CGRect(x: 0, y: view.bounds.height - height, width: view.bounds.width, height: height)
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); model?.startClipboardCapture() }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); surface?.stopInteractions(); model?.finishCompositionAsTyped(); model?.suspend(); textView.resignFirstResponder() }
    func applyExternalSettings(_ settings: KeyboardSettings) {
        guard initialSettings != settings else { return }
        initialSettings = settings
        model?.settings = settings; model?.refreshCandidates()
    }
    private func rememberSelection() { lastSelection = textView.selectedRange; lastText = textView.text ?? "" }
    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !editingInternally, lastSelection != textView.selectedRange || lastText != textView.text else { return }
        rememberSelection(); if model?.isMovingCursor != true { model?.cursorChanged() }
    }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !editingInternally, let model else { return true }
        if range != textView.selectedRange {
            editingInternally = true; textView.selectedRange = range; editingInternally = false
            rememberSelection(); model.cursorChanged()
        }
        if text.isEmpty { model.handle(.delete) }
        else if text == " " { model.handle(.space) }
        else if text == "\n" { model.handle(.enter) }
        else if text.count == 1 { model.handle(.text(text)) }
        else { model.insertLiteral(text) }
        return false
    }
    var contextBefore: String {
        let value = (textView.text ?? "") as NSString
        return value.substring(to: min(textView.selectedRange.location, value.length))
    }
    var selectedText: String {
        let value = (textView.text ?? "") as NSString
        let range = textView.selectedRange
        guard range.location != NSNotFound, range.location <= value.length, range.length <= value.length - range.location else { return "" }
        return value.substring(with: range)
    }
    var contextAfter: String {
        let value = (textView.text ?? "") as NSString
        return value.substring(from: min(value.length, NSMaxRange(textView.selectedRange)))
    }
    var enterTitle: String { "换行" }
    var needsGlobe: Bool { true }
    var capitalization: UITextAutocapitalizationType { .sentences }
    var fullAccess: Bool { true }
    var prefersEnglish: Bool { false }
    func insert(_ text: String) { editingInternally = true; textView.insertText(text); rememberSelection(); editingInternally = false }
    func setMarkedText(_ text: String) {
        editingInternally = true
        textView.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
        rememberSelection(); editingInternally = false
    }
    func unmarkText() { editingInternally = true; textView.unmarkText(); rememberSelection(); editingInternally = false }
    func deleteBackward() { editingInternally = true; textView.deleteBackward(); rememberSelection(); editingInternally = false }
    func moveCursor(_ offset: Int) {
        editingInternally = true
        // Cursor offsets are grapheme offsets, never UTF-16 offsets into an emoji.
        let text = textView.text ?? "", old = textView.selectedRange.location
        let start = String.Index(utf16Offset: min(old, text.utf16.count), in: text)
        let next = offset >= 0 ? text.index(start, offsetBy: offset, limitedBy: text.endIndex) ?? text.endIndex : text.index(start, offsetBy: offset, limitedBy: text.startIndex) ?? text.startIndex
        textView.selectedRange = NSRange(location: next.utf16Offset(in: text), length: 0)
        rememberSelection()
        editingInternally = false
    }
    func nextKeyboard() { model.toggleLanguage() }
    func beginTrackpad() {
        guard let selection = textView.selectedTextRange else { return }
        let rect = textView.caretRect(for: selection.end)
        trackpadAnchor = CGPoint(x: rect.midX, y: rect.midY)
    }
    func trackCursor(translation: CGPoint) {
        guard let anchor = trackpadAnchor, translation.x.isFinite, translation.y.isFinite,
              let position = textView.closestPosition(to: CGPoint(x: anchor.x + translation.x, y: anchor.y + translation.y)) else { return }
        editingInternally = true
        textView.selectedTextRange = textView.textRange(from: position, to: position)
        rememberSelection(); textView.scrollRangeToVisible(textView.selectedRange); editingInternally = false
    }
    func endTrackpad() { trackpadAnchor = nil }
    func clearInput() -> DeletedInput? {
        guard let text = textView.text, !text.isEmpty else { return nil }
        let value = DeletedInput(text: text, selection: textView.selectedRange)
        editingInternally = true; textView.unmarkText(); textView.text = ""; textView.selectedRange = NSRange(location: 0, length: 0)
        rememberSelection(); editingInternally = false; return value
    }
    func restoreInput(_ value: DeletedInput) -> Bool {
        guard (textView.text ?? "").isEmpty else { return false }
        editingInternally = true; textView.text = value.text; textView.selectedRange = value.selection
        rememberSelection(); editingInternally = false; return true
    }
}
