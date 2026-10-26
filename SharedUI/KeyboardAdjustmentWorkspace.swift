import UIKit

/// One coordinate system for all keyboard adjustment pages. Equal side rails
/// share their top/bottom edges; the real keyboard preview stays in the center.
@MainActor final class KeyboardAdjustmentWorkspace: UIView {
    let preview = KeyboardAppearancePreview()
    let left = UIStackView(), right = UIStackView()
    private let leftTitle = UILabel(), rightTitle = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; backgroundColor = .clear
        for rail in [left, right] { rail.axis = .vertical; rail.spacing = 5; rail.distribution = .equalSpacing }
        for title in [leftTitle, rightTitle] {
            title.font = .systemFont(ofSize: 12, weight: .medium); title.textColor = .secondaryLabel
            title.textAlignment = .center; title.adjustsFontSizeToFitWidth = true; title.minimumScaleFactor = 0.9
        }
        [left, right, leftTitle, rightTitle, preview].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func configure(left title: String, right other: String) {
        leftTitle.text = title; rightTitle.text = other
        for rail in [left, right] { rail.distribution = .equalSpacing; for view in rail.arrangedSubviews { rail.removeArrangedSubview(view); view.removeFromSuperview() } }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.insetBy(dx: 10, dy: 10), side = min(84, floor(max(0, area.width) * 0.22)), gap: CGFloat = 8
        let middle = max(1, area.width - side * 2 - gap * 2)
        let height = min(max(144, preview.fittingSize(forWidth: middle).height), max(144, area.height - 22))
        let top = max(area.minY, area.midY - (height + 22) / 2)
        leftTitle.frame = CGRect(x: area.minX, y: top, width: side, height: 16)
        rightTitle.frame = CGRect(x: area.maxX - side, y: top, width: side, height: 16)
        left.frame = CGRect(x: area.minX, y: top + 22, width: side, height: height)
        right.frame = CGRect(x: area.maxX - side, y: top + 22, width: side, height: height)
        preview.frame = CGRect(x: left.frame.maxX + gap, y: top + 22, width: middle, height: height)
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
        slider.bounds = CGRect(x: 0, y: 0, width: max(56, bounds.height - 35), height: 28)
        slider.center = CGPoint(x: bounds.midX, y: (bounds.height + 23) / 2)
    }
    func configure(value: Double, enabled: Bool = true) {
        if !slider.isTracking { slider.value = Float(value) }
        slider.isEnabled = enabled; alpha = enabled ? 1 : 0.4; updateAmount()
    }
    private func updateAmount() { amount.text = "\(Int((slider.value * 100).rounded()))%" }
}
