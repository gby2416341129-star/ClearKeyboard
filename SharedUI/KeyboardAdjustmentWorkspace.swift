import UIKit

/// One coordinate system for all keyboard adjustment pages. Equal side rails
/// share their top/bottom edges; the real keyboard preview stays in the center.
@MainActor final class KeyboardAdjustmentWorkspace: UIScrollView {
    let preview = KeyboardAppearancePreview()
    let left = UIStackView(), right = UIStackView()
    let footer = UIView()
    var footerHeight: CGFloat = 0 { didSet { setNeedsLayout() } }
    private let leftTitle = UILabel(), rightTitle = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never; delaysContentTouches = false; canCancelContentTouches = true
        showsHorizontalScrollIndicator = false; alwaysBounceVertical = false
        for rail in [left, right] { rail.axis = .vertical; rail.spacing = 5; rail.distribution = .fillEqually }
        for title in [leftTitle, rightTitle] {
            title.font = .systemFont(ofSize: 12, weight: .medium); title.textColor = .secondaryLabel
            title.textAlignment = .center; title.adjustsFontSizeToFitWidth = true; title.minimumScaleFactor = 0.9
        }
        [left, right, leftTitle, rightTitle, preview, footer].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func configure(left title: String, right other: String) {
        leftTitle.text = title; rightTitle.text = other
        footerHeight = 0; footer.subviews.forEach { $0.removeFromSuperview() }; setContentOffset(.zero, animated: false)
        for rail in [left, right] { rail.distribution = .fillEqually; for view in rail.arrangedSubviews { rail.removeArrangedSubview(view); view.removeFromSuperview() } }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        // A fixed width-based preview is shared by every page. Extra controls
        // extend scrollable content rather than squeezing the keyboard canvas.
        let area = CGRect(x: 10, y: 8, width: max(0, bounds.width - 20), height: max(0, bounds.height - 16))
        let side = min(76, floor(area.width * 0.18)), gap: CGFloat = 8
        let middle = max(1, area.width - side * 2 - gap * 2)
        let size = preview.fittingSize(forWidth: middle)
        let top = max(8, (area.height - size.height - 100) / 2)
        let previewX = bounds.width / 2 - size.width / 2
        leftTitle.frame = CGRect(x: previewX - gap - side, y: top, width: side, height: 16)
        rightTitle.frame = CGRect(x: previewX + size.width + gap, y: top, width: side, height: 16)
        left.frame = CGRect(x: leftTitle.frame.minX, y: top + 20, width: side, height: size.height)
        right.frame = CGRect(x: rightTitle.frame.minX, y: top + 20, width: side, height: size.height)
        preview.frame = CGRect(x: previewX, y: top + 20, width: size.width, height: size.height)
        footer.isHidden = footerHeight == 0
        footer.frame = CGRect(x: area.minX, y: preview.frame.maxY + 12, width: area.width, height: footerHeight)
        // Leave the keyboard-switch key's bottom row unobscured when scrolling.
        let height = max(bounds.height, (footerHeight > 0 ? footer.frame.maxY : preview.frame.maxY) + 52)
        if contentSize != CGSize(width: bounds.width, height: height) { contentSize = CGSize(width: bounds.width, height: height) }
    }
}

/// A narrow rail gets a vertical control, not a squeezed desktop-style row.
@MainActor final class KeyboardVerticalValueControl: UIView {
    let slider = UISlider()
    private let amount = UILabel()
    var onChange: ((Double) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        amount.textAlignment = .center; amount.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        amount.textColor = .label; addSubview(amount); addSubview(slider)
        slider.minimumValue = 0; slider.maximumValue = 1
        slider.transform = CGAffineTransform(rotationAngle: -.pi / 2)
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.updateAmount(); self.onChange?(Double(self.slider.value))
        }, for: .valueChanged)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        amount.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 21)
        amount.adjustsFontSizeToFitWidth = true; amount.minimumScaleFactor = 0.85
        slider.bounds = CGRect(x: 0, y: 0, width: max(56, bounds.height - 35), height: 28)
        slider.center = CGPoint(x: bounds.midX, y: (bounds.height + 35) / 2)
    }
    func configure(value: Double, enabled: Bool = true) {
        if !slider.isTracking { slider.value = Float(value) }
        slider.isEnabled = enabled; alpha = enabled ? 1 : 0.4; updateAmount()
    }
    private func updateAmount() { amount.text = "\(Int((slider.value * 100).rounded()))%" }
}
