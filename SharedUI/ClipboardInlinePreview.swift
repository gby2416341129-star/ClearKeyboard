import UIKit

/// TextKit lays out a single horizontally scrollable line without rasterizing
/// an article into an enormous label bitmap. Taps paste; pans only browse.
@MainActor final class ClipboardInlinePreview: UITextView {
    var onPaste: (() -> Void)?
    init() {
        let storage = NSTextStorage(), layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 10_000_000, height: 36))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        container.widthTracksTextView = false; container.heightTracksTextView = false
        container.lineFragmentPadding = 0; container.maximumNumberOfLines = 1
        isEditable = false; isSelectable = false; isUserInteractionEnabled = true
        backgroundColor = .clear; font = .systemFont(ofSize: 15, weight: .medium); textColor = .label
        textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = true; alwaysBounceVertical = false
        contentInsetAdjustmentBehavior = .never; delaysContentTouches = false
        accessibilityIdentifier = "clipboard.recent.text"
        let tap = UITapGestureRecognizer(target: self, action: #selector(pasteText))
        tap.require(toFail: panGestureRecognizer); addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var canBecomeFirstResponder: Bool { false }
    func show(_ value: String) {
        let line = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        guard text != line else { return }
        text = line; accessibilityLabel = value
        layoutManager.ensureLayout(for: textContainer)
        contentSize = CGSize(width: max(bounds.width, layoutManager.usedRect(for: textContainer).maxX + 8), height: 36)
        setContentOffset(.zero, animated: false)
    }
    @objc private func pasteText() { onPaste?() }
}
