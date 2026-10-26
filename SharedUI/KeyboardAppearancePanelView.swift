import UIKit

/// Remote keyboard controls stay in UIKit's touch hierarchy. The App can use
/// SwiftUI navigation, but a keyboard-hosted settings row must remain a real
/// button/slider with an explicit model write and an immediately refreshed preview.
@MainActor final class KeyboardAppearancePanelView: UIView {
    private let current: () -> KeyboardSettings
    private let save: (KeyboardSettings) -> Void
    private let scroll = KeyboardPanelScrollView()
    private let stack = UIStackView()
    private let preview = KeyboardAppearancePreview()
    private(set) var selected: AppearanceItem?
    var onNavigate: ((AppearanceItem?) -> Void)?
    private var strength: ValueSliderView?
    private var sizes: UISegmentedControl?
    private var animations: UISegmentedControl?
    private var colorSliders: [UISlider] = []
    private var swatches: [(UIButton, String)] = []
    private var reset: UIButton?
    init(current: @escaping () -> KeyboardSettings, save: @escaping (KeyboardSettings) -> Void) {
        self.current = current; self.save = save
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.5, alpha: 0.01)
        accessibilityIdentifier = "keyboard.appearance.panel"
        scroll.delaysContentTouches = false; addSubview(scroll)
        stack.axis = .vertical; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -14),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -20)
        ])
        preview.heightAnchor.constraint(equalToConstant: 124).isActive = true
        show(nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() { super.layoutSubviews(); scroll.frame = bounds }
    private func button(_ title: String, symbol: String?, identifier: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title; config.baseForegroundColor = .label
        config.image = symbol.map { ToolArtwork.image(symbol: $0, size: 25) }
        config.imagePadding = 12; config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { values in
            var result = values; result.font = .systemFont(ofSize: 15, weight: .medium); return result
        }
        let button = FeedbackButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.accessibilityIdentifier = identifier; button.contentHorizontalAlignment = .leading
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        let glass = LiquidGlassView(radius: 16); glass.translatesAutoresizingMaskIntoConstraints = false
        button.insertSubview(glass, at: 0)
        NSLayoutConstraint.activate([glass.leadingAnchor.constraint(equalTo: button.leadingAnchor), glass.trailingAnchor.constraint(equalTo: button.trailingAnchor), glass.topAnchor.constraint(equalTo: button.topAnchor), glass.bottomAnchor.constraint(equalTo: button.bottomAnchor)])
        return button
    }
    func show(_ item: AppearanceItem?) {
        if selected == item, !stack.arrangedSubviews.isEmpty { return }
        selected = item; strength = nil; sizes = nil; animations = nil; colorSliders = []; swatches = []; reset = nil
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        scroll.setContentOffset(.zero, animated: false)
        guard let item else {
            for item in AppearanceItem.allCases {
                stack.addArrangedSubview(button(item.title + "  ›", symbol: item.symbol, identifier: "keyboard.appearance." + item.rawValue) { [weak self] in self?.navigate(item) })
            }
            return
        }
        stack.addArrangedSubview(button(item.title, symbol: "chevron.left", identifier: "keyboard.appearance.back") { [weak self] in self?.navigate(nil) })
        stack.addArrangedSubview(preview)
        switch item {
        case .keyGlass:
            let value = ValueSliderView(); value.heightAnchor.constraint(equalToConstant: 76).isActive = true
            value.onCommit = { [weak self] amount in self?.edit { $0.keyGlassStrength = amount } }
            strength = value; stack.addArrangedSubview(value)
        case .candidateSize:
            let value = UISegmentedControl(items: CandidateTextSize.allCases.map(\.title))
            value.accessibilityIdentifier = "keyboard.appearance.candidateSize"
            value.heightAnchor.constraint(equalToConstant: 34).isActive = true
            value.addAction(UIAction { [weak self, weak value] _ in
                guard let value, CandidateTextSize.allCases.indices.contains(value.selectedSegmentIndex) else { return }
                self?.edit { $0.candidateTextSize = CandidateTextSize.allCases[value.selectedSegmentIndex] }
            }, for: .valueChanged)
            sizes = value; stack.addArrangedSubview(value)
            let label = UILabel(); label.text = "候选词动画"; label.font = .systemFont(ofSize: 14, weight: .medium)
            stack.addArrangedSubview(label)
            let animation = UISegmentedControl(items: CandidateAnimation.allCases.map(\.shortTitle))
            animation.accessibilityIdentifier = "keyboard.appearance.candidateAnimation"
            animation.heightAnchor.constraint(equalToConstant: 34).isActive = true
            animation.addAction(UIAction { [weak self, weak animation] _ in
                guard let self, let animation, CandidateAnimation.allCases.indices.contains(animation.selectedSegmentIndex) else { return }
                self.edit { $0.candidateAnimation = CandidateAnimation.allCases[animation.selectedSegmentIndex] }
                KeyboardVibration.shared.attach(to: self); KeyboardVibration.shared.pulseInterface()
            }, for: .valueChanged)
            animations = animation; stack.addArrangedSubview(animation)
        case .keyColor, .candidateColor:
            let row = UIStackView(); row.spacing = 8; row.distribution = .fillEqually
            for hex in ["#F2F3F8", "#292C39", "#7573F5", "#558DF2", "#D799BC", "#E3AC72"] {
                let value = UIButton(type: .system); value.backgroundColor = KeyboardSettings.color(hex: hex)
                value.layer.cornerRadius = 12; value.heightAnchor.constraint(equalToConstant: 34).isActive = true
                value.accessibilityLabel = hex; value.accessibilityIdentifier = "keyboard.swatch." + hex
                value.addAction(UIAction { [weak self] _ in self?.setColor(hex) }, for: .touchUpInside)
                row.addArrangedSubview(value); swatches.append((value, hex))
            }
            stack.addArrangedSubview(row)
            for (index, name) in ["R", "G", "B"].enumerated() {
                let label = UILabel(); label.text = name; label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
                label.widthAnchor.constraint(equalToConstant: 18).isActive = true
                let slider = UISlider(); slider.minimumValue = 0; slider.maximumValue = 1
                slider.accessibilityLabel = "自定义颜色 " + name
                slider.accessibilityIdentifier = "keyboard.color." + name
                slider.addAction(UIAction { [weak self, weak slider] _ in
                    guard let self, let slider else { return }
                    var rgb = self.color()
                    if index == 0 { rgb.red = Double(slider.value) }
                    if index == 1 { rgb.green = Double(slider.value) }
                    if index == 2 { rgb.blue = Double(slider.value) }
                    self.setColor(rgb.hex)
                }, for: .valueChanged)
                let row = UIStackView(arrangedSubviews: [label, slider]); row.spacing = 8
                stack.addArrangedSubview(row); colorSliders.append(slider)
            }
        }
        let reset = button("恢复默认", symbol: "arrow.counterclockwise", identifier: "keyboard.appearance.reset") { [weak self] in
            guard let self else { return }
            if !UIAccessibility.isReduceMotionEnabled { self.reset?.imageView?.layer.add(Self.resetAnimation(), forKey: "reset.confirmation") }
            self.edit {
                switch item {
                case .keyGlass: $0.keyGlassStrength = nil
                case .keyColor: $0.keyColorHex = nil
                case .candidateColor: $0.candidateColorHex = nil
                case .candidateSize: $0.candidateTextSize = nil; $0.candidateAnimation = nil
                }
            }
        }
        self.reset = reset; stack.addArrangedSubview(reset); apply(current())
    }
    private static func resetAnimation() -> CAAnimation {
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0; turn.toValue = -Double.pi * 2; turn.duration = 0.32
        turn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return turn
    }
    private func edit(_ change: (inout KeyboardSettings) -> Void) {
        var settings = current(); change(&settings)
        guard settings != current() else { return }
        save(settings); apply(settings)
    }
    private func setColor(_ hex: String) {
        guard let path = selected?.colorPath else { return }
        edit { $0[keyPath: path] = hex }
    }
    private func navigate(_ item: AppearanceItem?) {
        if let onNavigate { onNavigate(item) } else { show(item) }
    }
    private func color() -> RGBColor {
        let value = selected?.colorPath.flatMap { current()[keyPath: $0] }
        let dark = traitCollection.userInterfaceStyle == .dark
        let fallback = selected == .keyColor ? (dark ? "#BFC4D6" : "#FFFFFF") : (dark ? "#F4F4F8" : "#20212A")
        return RGBColor(hex: value ?? fallback)!
    }
    func apply(_ settings: KeyboardSettings) {
        guard let selected else { return }
        preview.apply(settings)
        strength?.configure(title: "通透强度", value: settings.resolvedKeyGlassStrength, range: 0...1, defaultValue: 0.55,
                            identifier: "keyboard.appearance.strength", percent: true)
        sizes?.selectedSegmentIndex = CandidateTextSize.allCases.firstIndex(of: settings.resolvedCandidateTextSize) ?? 1
        animations?.selectedSegmentIndex = CandidateAnimation.allCases.firstIndex(of: settings.resolvedCandidateAnimation) ?? 0
        if selected.colorPath != nil {
            let rgb = color(), values = [rgb.red, rgb.green, rgb.blue]
            for (index, slider) in colorSliders.enumerated() where !slider.isTracking { slider.value = Float(values[index]) }
            for (button, hex) in swatches {
                let selected = rgb.hex == hex
                button.layer.borderWidth = selected ? 2 : 0; button.layer.borderColor = UIColor.label.cgColor
                button.accessibilityTraits = selected ? [.button, .selected] : .button
            }
        }
    }
}
