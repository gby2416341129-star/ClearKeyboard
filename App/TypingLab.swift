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
        if controller.model.settings != settings { controller.model.settings = settings; controller.model.refreshCandidates() }
    }
}

final class TypingLabController: UIViewController, KeyboardDocument, UITextViewDelegate {
    let textView = UITextView()
    var model: KeyboardModel!
    private var surface: KeyboardSurface!
    private var initialSettings: KeyboardSettings
    private var editingInternally = false
    init(settings: KeyboardSettings) { initialSettings = settings; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        textView.font = .systemFont(ofSize: 20); textView.backgroundColor = .clear
        textView.textColor = .label; textView.tintColor = initialSettings.accentColor
        textView.text = "你好，世界。\nHello, inspiration. "
        textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 12, right: 14)
        textView.inputView = UIView(frame: .zero)
        textView.autocorrectionType = .no; textView.spellCheckingType = .no
        textView.delegate = self; textView.accessibilityLabel = "输入体验区"
        view.addSubview(textView)
        model = KeyboardModel(document: self, settings: initialSettings)
        surface = KeyboardSurface(model: model); view.addSubview(surface)
        surface.onHeightChange = { [weak self] _ in self?.view.setNeedsLayout() }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = min(surface.desiredHeight, view.bounds.height - 88)
        textView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height - height)
        surface.frame = CGRect(x: 0, y: view.bounds.height - height, width: view.bounds.width, height: height)
    }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); surface.stopInteractions(); model.suspend(); textView.resignFirstResponder() }
    func textViewDidChangeSelection(_ textView: UITextView) { if !editingInternally { model?.cursorChanged() } }
    var contextBefore: String {
        let value = (textView.text ?? "") as NSString
        return value.substring(to: min(textView.selectedRange.location, value.length))
    }
    var selectedText: String {
        let value = (textView.text ?? "") as NSString
        let range = textView.selectedRange
        guard range.location + range.length <= value.length else { return "" }
        return value.substring(with: range)
    }
    var enterTitle: String { "换行" }
    var needsGlobe: Bool { true }
    var capitalization: UITextAutocapitalizationType { .sentences }
    var fullAccess: Bool { true }
    var prefersEnglish: Bool { false }
    func insert(_ text: String) { editingInternally = true; textView.insertText(text); editingInternally = false }
    func deleteBackward() { editingInternally = true; textView.deleteBackward(); editingInternally = false }
    func moveCursor(_ offset: Int) {
        editingInternally = true
        // Cursor offsets are grapheme offsets, never UTF-16 offsets into an emoji.
        let text = textView.text ?? "", old = textView.selectedRange.location
        let start = String.Index(utf16Offset: min(old, text.utf16.count), in: text)
        let next = offset >= 0 ? text.index(start, offsetBy: offset, limitedBy: text.endIndex) ?? text.endIndex : text.index(start, offsetBy: offset, limitedBy: text.startIndex) ?? text.startIndex
        textView.selectedRange = NSRange(location: next.utf16Offset(in: text), length: 0)
        editingInternally = false
    }
    func nextKeyboard() { model.toggleLanguage() }
}
