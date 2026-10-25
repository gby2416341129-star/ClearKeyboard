import UIKit
import SwiftUI

/// UIKit owns the draft while a finger is down; persistence and SwiftUI receive
/// one final value. Accessibility adjustments commit immediately.
final class ValueSliderView: UIView {
    let slider = UISlider()
    private let title = UILabel(), amount = UILabel()
    private let artwork = UIImageView()
    private let reset = UIButton(type: .system)
    var onCommit: ((Double) -> Void)?
    var formatter: (Double) -> String = { String(Int($0.rounded())) }
    var defaultValue: Double = 50
    private var lastCommitted: Float = .nan
    private var roundsValue = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 15, weight: .medium)
        amount.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        amount.textColor = .secondaryLabel; amount.setContentHuggingPriority(.required, for: .horizontal)
        reset.setTitle("还原", for: .normal); reset.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        artwork.contentMode = .scaleAspectFit
        artwork.widthAnchor.constraint(equalToConstant: 24).isActive = true
        artwork.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let row = UIStackView(arrangedSubviews: [artwork, title, UIView(), amount, reset]); row.spacing = 8; row.alignment = .center
        let stack = UIStackView(arrangedSubviews: [row, slider]); stack.axis = .vertical; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        slider.addTarget(self, action: #selector(changed), for: .valueChanged)
        slider.addTarget(self, action: #selector(ended), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        reset.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.slider.value = Float(self.defaultValue); self.updateAmount(); self.commit()
        }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func configure(title text: String, value: Double, range: ClosedRange<Double>, defaultValue: Double, identifier: String, percent: Bool) {
        title.text = text
        artwork.image = ToolArtwork.image(symbol: text.contains("高度") ? "key.height" : text.contains("震动") ? "haptic" : text.contains("宽度") ? "keyboard.fill" : "key.glass", size: 24)
        slider.accessibilityLabel = text; slider.accessibilityIdentifier = identifier
        reset.accessibilityLabel = "还原" + text
        if identifier == "custom.keyHeight" { reset.accessibilityIdentifier = "custom.resetHeight" }
        self.defaultValue = defaultValue
        roundsValue = !percent
        formatter = percent ? { "\(Int(($0 * 100).rounded()))%" } : { "\(Int($0.rounded())) pt" }
        slider.minimumValue = Float(range.lowerBound); slider.maximumValue = Float(range.upperBound)
        guard !slider.isTracking else { return }
        slider.value = Float(value); lastCommitted = slider.value; updateAmount()
    }
    @objc private func changed() { updateAmount(); if !slider.isTracking { commit() } }
    @objc private func ended() { updateAmount(); commit() }
    private func updateAmount() { amount.text = formatter(Double(slider.value)) }
    private func commit() {
        if roundsValue { slider.value = slider.value.rounded(); updateAmount() }
        guard lastCommitted != slider.value else { return }
        lastCommitted = slider.value; onCommit?(Double(slider.value))
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { commit() } }
}

struct GlassValueSlider: UIViewRepresentable {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let identifier: String
    var percent = false
    func makeUIView(context: Context) -> ValueSliderView { ValueSliderView() }
    func updateUIView(_ view: ValueSliderView, context: Context) {
        view.onCommit = { value = $0 }
        view.configure(title: title, value: value, range: range, defaultValue: defaultValue, identifier: identifier, percent: percent)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ValueSliderView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: 68)
    }
}
