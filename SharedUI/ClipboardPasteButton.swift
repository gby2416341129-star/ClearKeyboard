import UIKit
import UniformTypeIdentifiers

/// UIPasteControl provides the system-recognized paste gesture, without another approval alert.
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
        guard let item = itemProviders.first else { return }
        let imageType = [UTType.png.identifier, UTType.jpeg.identifier, "public.heic", "public.heif", UTType.gif.identifier]
            .first { item.registeredTypeIdentifiers.contains($0) }
            ?? item.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
        if let imageType {
            // Keep the provider's encoded image: expanding a small JPEG/HEIC
            // to PNG can exceed the existing attachment limit unnecessarily.
            item.loadDataRepresentation(forTypeIdentifier: imageType) { [weak self] data, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let data, !data.isEmpty {
                        self.capture.acceptAttachment(data, typeIdentifier: imageType, name: "图片")
                    } else { self.loadImageFallback(from: item) }
                }
            }
        } else if item.canLoadObject(ofClass: UIImage.self) {
            loadImageFallback(from: item)
        } else if item.canLoadObject(ofClass: NSString.self) {
            item.loadObject(ofClass: NSString.self) { [weak self] value, _ in
                guard let value = value as? String else { return }
                Task { @MainActor [weak self] in self?.capture.acceptText(value) }
            }
        } else if item.canLoadObject(ofClass: NSURL.self) {
            item.loadObject(ofClass: NSURL.self) { [weak self] value, _ in
                guard let url = value as? URL else { return }
                Task { @MainActor [weak self] in self?.capture.acceptText(url.absoluteString) }
            }
        } else if let type = item.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) {
            item.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, _ in
                guard let data else { return }
                Task { @MainActor [weak self] in self?.capture.acceptAttachment(data, typeIdentifier: type, name: UTType(type)?.localizedDescription ?? "附件") }
            }
        }
    }
    private func loadImageFallback(from item: NSItemProvider) {
        guard item.canLoadObject(ofClass: UIImage.self) else { return }
        item.loadObject(ofClass: UIImage.self) { [weak self] value, _ in
            guard let image = value as? UIImage, let data = image.pngData() else { return }
            Task { @MainActor [weak self] in self?.capture.acceptAttachment(data, typeIdentifier: UTType.png.identifier, name: "图片") }
        }
    }
}
