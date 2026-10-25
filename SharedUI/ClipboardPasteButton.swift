import UIKit
import UniformTypeIdentifiers

@MainActor final class ClipboardPasteButton: UIView {
    private let receiver: ClipboardPasteReceiver
    private let pasteControl: UIPasteControl
    init(capture: ClipboardCapture) {
        receiver = ClipboardPasteReceiver(capture: capture)
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel; configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .systemBlue.withAlphaComponent(0.12)
        configuration.baseForegroundColor = .systemBlue
        pasteControl = UIPasteControl(configuration: configuration)
        super.init(frame: .zero)
        pasteControl.target = receiver; pasteControl.accessibilityLabel = "粘贴并保存到剪贴板"
        addSubview(receiver); addSubview(pasteControl)
        accessibilityIdentifier = "clipboard.systemPaste"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var intrinsicContentSize: CGSize { CGSize(width: 114, height: 38) }
    override func layoutSubviews() { super.layoutSubviews(); pasteControl.frame = bounds; receiver.frame = .zero }
}

@MainActor private final class ClipboardPasteReceiver: UIView {
    private let capture: ClipboardCapture
    init(capture: ClipboardCapture) {
        self.capture = capture; super.init(frame: .zero)
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.text.identifier, UTType.url.identifier, UTType.image.identifier, UTType.data.identifier])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func paste(itemProviders: [NSItemProvider]) {
        ClipboardItemLoader.load(itemProviders, revision: UIPasteboard.general.changeCount, into: capture)
    }
}

/// Bound attachment bytes before allocation. Import in order with one live payload.
@MainActor enum ClipboardItemLoader {
    static func load(_ providers: [NSItemProvider], revision: Int?, into capture: ClipboardCapture) {
        guard let provider = providers.first else { return }
        let next = { load(Array(providers.dropFirst()), revision: revision, into: capture) }
        let types = provider.registeredTypeIdentifiers
        let image = [UTType.png.identifier, UTType.jpeg.identifier, "public.heic", "public.heif", UTType.gif.identifier]
            .first(where: types.contains) ?? types.first { UTType($0)?.conforms(to: .image) == true }
        if let type = image ?? types.first(where: { UTType($0)?.conforms(to: .data) == true && UTType($0)?.conforms(to: .text) != true && UTType($0)?.conforms(to: .url) != true }) {
            let name = image == nil ? (UTType(type)?.localizedDescription ?? "附件") : "图片"
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                let result: Result<Data, Error> = Result {
                    guard let url else { throw ClipboardStore.Failure.unavailable }
                    return try ClipboardStore.boundedAttachment(at: url)
                }
                Task { @MainActor in
                    switch result {
                    case .success(let data): capture.acceptAttachment(data, typeIdentifier: type, name: name, revision: revision, completion: next)
                    case .failure(let error): capture.reportFailure(error as? ClipboardStore.Failure); next()
                    }
                }
            }
        } else if provider.canLoadObject(ofClass: NSString.self) {
            provider.loadObject(ofClass: NSString.self) { value, _ in
                let text = value as? String
                Task { @MainActor in
                    if let text { capture.acceptText(text, revision: revision, completion: next) }
                    else { capture.reportFailure(nil); next() }
                }
            }
        } else if provider.canLoadObject(ofClass: NSURL.self) {
            provider.loadObject(ofClass: NSURL.self) { value, _ in
                let text = (value as? URL)?.absoluteString
                Task { @MainActor in
                    if let text { capture.acceptText(text, revision: revision, completion: next) }
                    else { capture.reportFailure(nil); next() }
                }
            }
        } else { capture.reportFailure(nil); next() }
    }
}