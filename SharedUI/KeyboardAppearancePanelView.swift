import UIKit

/// Only the keyboard uses the three-column workspace. Both side rails have the
/// same width; the live preview owns constraints in its final parent.
@MainActor final class KeyboardAppearancePanelView: UIView {
    private let current: () -> KeyboardSettings
    private let save: (KeyboardSettings) -> Void
    private let scroll = KeyboardPanelScrollView()
    private let stack = UIStackView()
    private let preview = KeyboardAppearancePreview()
    private var workspaceHeight: NSLayoutConstraint?
    private var strength: ValueSliderView?
    private var swatches: [(UIButton, String)] = []
    private var colorSliders: [UISlider] = []
    private var options: [(UIButton, (KeyboardSettings) -> Bool)] = []
    private(set) var selected: AppearanceItem?
    var onNavigate: ((AppearanceItem?) -> Void)?
    init(current: @escaping () -> KeyboardSettings, save: @escaping (KeyboardSettings) -> Void) {
        self.current = current; self.save = save
        super.init(frame: .zero)
        backgroundColor = .clear; isOpaque = false
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
        show(nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews(); scroll.frame = bounds
        let height = max(174, bounds.height - 22)
        if workspaceHeight?.constant != height { workspaceHeight?.constant = height }
    }
    private func pulse() { KeyboardVibration.shared.attach(to: self); KeyboardVibration.shared.pulseInterface() }
    private func option(_ title: String, selected: @escaping (KeyboardSettings) -> Bool = { _ in false }, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled(); config.title = title
        config.baseBackgroundColor = .secondarySystemFill; config.baseForegroundColor = .label
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 3)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { values in
            var next = values; next.font = .systemFont(ofSize: 12, weight: .medium); return next
        }
        let button = FeedbackButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.pulse(); action() })
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        options.append((button, selected)); return button
    }
    func show(_ item: AppearanceItem?) {
        if selected == item, !stack.arrangedSubviews.isEmpty { apply(current()); return }
        preview.removeFromSuperview()
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        selected = item; workspaceHeight = nil; strength = nil; swatches = []; colorSliders = []; options = []
        scroll.setContentOffset(.zero, animated: false)
        guard let item else {
            for entry in AppearanceItem.allCases {
                let row = ToolTileButton(title: entry.title, symbol: entry.symbol) { [weak self] in
                    self?.pulse(); self?.onNavigate?(entry)
                }
                row.heightAnchor.constraint(equalToConstant: 60).isActive = true
                row.accessibilityIdentifier = "keyboard.appearance." + entry.rawValue
                stack.addArrangedSubview(row)
            }
            return
        }
        let area = UIView(), left = UIStackView(), right = UIStackView()
        left.axis = .vertical; right.axis = .vertical; left.spacing = 5; right.spacing = 5
        [left, preview, right].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; area.addSubview($0) }
        stack.addArrangedSubview(area)
        let height = area.heightAnchor.constraint(equalToConstant: max(174, bounds.height - 22))
        workspaceHeight = height
        NSLayoutConstraint.activate([
            height,
            left.leadingAnchor.constraint(equalTo: area.leadingAnchor),
            left.widthAnchor.constraint(equalTo: area.widthAnchor, multiplier: 0.22),
            right.trailingAnchor.constraint(equalTo: area.trailingAnchor),
            right.widthAnchor.constraint(equalTo: left.widthAnchor),
            left.centerYAnchor.constraint(equalTo: area.centerYAnchor),
            right.centerYAnchor.constraint(equalTo: area.centerYAnchor),
            preview.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 8),
            preview.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -8),
            preview.centerYAnchor.constraint(equalTo: area.centerYAnchor),
            preview.heightAnchor.constraint(equalTo: area.heightAnchor)
        ])
        switch item {
        case .keyGlass:
            for (title, amount) in [("清透", 0.9), ("均衡", 0.55), ("质感", 0.15)] {
                left.addArrangedSubview(option(title, selected: { abs($0.resolvedKeyGlassStrength - amount) < 0.01 }) { [weak self] in self?.edit { $0.keyGlassStrength = amount } })
            }
            let value = ValueSliderView(); value.heightAnchor.constraint(equalToConstant: 76).isActive = true
            value.onCommit = { [weak self] amount in self?.edit { $0.keyGlassStrength = amount } }
            right.addArrangedSubview(value); strength = value
        case .candidateSize:
            for size in CandidateTextSize.allCases {
                left.addArrangedSubview(option(size.title, selected: { $0.resolvedCandidateTextSize == size }) { [weak self] in self?.edit { $0.candidateTextSize = size } })
            }
            let label = UILabel(); label.text = "候选动画"; label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textAlignment = .center; right.addArrangedSubview(label)
            for animation in CandidateAnimation.allCases {
                right.addArrangedSubview(option(animation.shortTitle, selected: { $0.resolvedCandidateAnimation == animation }) { [weak self] in self?.edit { $0.candidateAnimation = animation } })
            }
        case .keyColor, .candidateColor:
            let palette = ["#F2F3F8", "#292C39", "#7573F5", "#558DF2", "#D799BC", "#E3AC72"]
            for start in stride(from: 0, to: palette.count, by: 2) {
                let row = UIStackView(); row.spacing = 5; row.distribution = .fillEqually
                for hex in palette[start..<start + 2] {
                    let button = FeedbackButton(type: .custom); button.backgroundColor = KeyboardSettings.color(hex: hex)
                    button.layer.cornerRadius = 9; button.heightAnchor.constraint(equalToConstant: 28).isActive = true
                    button.accessibilityLabel = hex; button.accessibilityIdentifier = "keyboard.swatch." + hex
                    button.addAction(UIAction { [weak self] _ in self?.pulse(); self?.setColor(hex) }, for: .touchUpInside)
                    row.addArrangedSubview(button); swatches.append((button, hex))
                }
                left.addArrangedSubview(row)
            }
            for (index, name) in ["R", "G", "B"].enumerated() {
                let label = UILabel(); label.text = name; label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
                right.addArrangedSubview(label)
                let slider = UISlider(); slider.minimumValue = 0; slider.maximumValue = 1
                slider.accessibilityLabel = "自定义颜色 " + name; slider.accessibilityIdentifier = "keyboard.color." + name
                slider.addAction(UIAction { [weak self, weak slider] _ in
                    guard let self, let slider else { return }
                    var rgb = self.color()
                    if index == 0 { rgb.red = Double(slider.value) }
                    if index == 1 { rgb.green = Double(slider.value) }
                    if index == 2 { rgb.blue = Double(slider.value) }
                    self.setColor(rgb.hex)
                }, for: .valueChanged)
                right.addArrangedSubview(slider); colorSliders.append(slider)
            }
        }
        let reset = option("还原") { [weak self] in self?.edit {
            switch item {
            case .keyGlass: $0.keyGlassStrength = nil
            case .keyColor: $0.keyColorHex = nil
            case .candidateColor: $0.candidateColorHex = nil
            case .candidateSize: $0.candidateTextSize = nil; $0.candidateAnimation = nil
            }
        } }
        reset.accessibilityIdentifier = "keyboard.appearance.reset"; left.addArrangedSubview(reset)
        apply(current()); setNeedsLayout()
    }
    private func edit(_ change: (inout KeyboardSettings) -> Void) {
        var settings = current(); change(&settings)
        guard settings != current() else { return }
        save(settings); apply(settings)
    }
    private func setColor(_ hex: String) {
        guard let path = selected?.colorPath else { return }; edit { $0[keyPath: path] = hex }
    }
    private func color() -> RGBColor {
        let value = selected?.colorPath.flatMap { current()[keyPath: $0] }
        let dark = traitCollection.userInterfaceStyle == .dark
        let fallback = selected == .keyColor ? (dark ? "#BFC4D6" : "#FFFFFF") : (dark ? "#F4F4F8" : "#20212A")
        return RGBColor(hex: value ?? fallback)!
    }
    func apply(_ settings: KeyboardSettings) {
        guard selected != nil else { return }; preview.apply(settings)
        for (button, matches) in options {
            let active = matches(settings)
            button.configuration?.baseBackgroundColor = active ? tintColor.withAlphaComponent(0.22) : .secondarySystemFill
            button.accessibilityTraits = active ? [.button, .selected] : .button
        }
        strength?.configure(title: "通透", value: settings.resolvedKeyGlassStrength, range: 0...1, defaultValue: 0.55, identifier: "keyboard.appearance.strength", percent: true)
        if selected?.colorPath != nil {
            let rgb = color(), values = [rgb.red, rgb.green, rgb.blue]
            for (index, slider) in colorSliders.enumerated() where !slider.isTracking { slider.value = Float(values[index]) }
            for (button, hex) in swatches {
                let active = rgb.hex == hex
                button.layer.borderWidth = active ? 2 : 0; button.layer.borderColor = UIColor.label.cgColor
                button.accessibilityTraits = active ? [.button, .selected] : .button
            }
        }
    }
}
