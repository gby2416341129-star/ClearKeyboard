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
        textContainerInset = .zero
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = true; alwaysBounceVertical = false
        contentInsetAdjustmentBehavior = .never; delaysContentTouches = false
        accessibilityIdentifier = "clipboard.recent.text"
        let tap = UITapGestureRecognizer(target: self, action: #selector(pasteText))
        tap.require(toFail: panGestureRecognizer); addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var canBecomeFirstResponder: Bool { false }
    override func layoutSubviews() {
        super.layoutSubviews()
        alignLine()
    }
    private func alignLine() {
        guard bounds.height > 0 else { return }
        layoutManager.ensureLayout(for: textContainer)
        let line = layoutManager.usedRect(for: textContainer)
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let top = (max(0, (bounds.height - line.height) / 2 - line.minY) * max(1, scale)).rounded() / max(1, scale)
        let inset = UIEdgeInsets(top: top, left: 0, bottom: max(0, bounds.height - top - line.maxY), right: 0)
        if textContainerInset != inset { textContainerInset = inset }
        let size = CGSize(width: max(bounds.width, line.maxX + 8), height: bounds.height)
        if contentSize != size { contentSize = size }
        if contentOffset.y != 0 { setContentOffset(CGPoint(x: contentOffset.x, y: 0), animated: false) }
    }
    func show(_ value: String) {
        let line = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        guard text != line else { return }
        text = line; accessibilityLabel = value
        alignLine()
        setContentOffset(.zero, animated: false)
    }
    @objc private func pasteText() { onPaste?() }
}
