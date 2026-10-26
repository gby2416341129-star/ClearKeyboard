import UIKit

@MainActor final class KeyboardAppearancePanelView: UIView {
    private let current: () -> KeyboardSettings
    private let save: (KeyboardSettings) -> Void
    private let menu = UIStackView()
    private let workspace = KeyboardAdjustmentWorkspace()
    private var strength: KeyboardVerticalValueControl?
    private var swatches: [(UIButton, String)] = []
    private var colors: [KeyboardRGBControl] = []
    private var options: [(UIButton, (KeyboardSettings) -> Bool)] = []
    private(set) var selected: AppearanceItem?
    var onNavigate: ((AppearanceItem?) -> Void)?
    init(current: @escaping () -> KeyboardSettings, save: @escaping (KeyboardSettings) -> Void) {
        self.current = current; self.save = save; super.init(frame: .zero)
        isOpaque = false; backgroundColor = .clear; accessibilityIdentifier = "keyboard.appearance.panel"
        menu.axis = .vertical; menu.spacing = 10; menu.distribution = .fillEqually
        for rowIndex in 0..<2 {
            let row = UIStackView(); row.spacing = 10; row.distribution = .fillEqually
            for entry in AppearanceItem.allCases[(rowIndex * 2)..<(rowIndex * 2 + 2)] {
                let tile = ToolTileButton(title: entry.title, symbol: entry.symbol) { [weak self] in self?.pulse(); self?.onNavigate?(entry) }
                tile.accessibilityIdentifier = "keyboard.appearance." + entry.rawValue; row.addArrangedSubview(tile)
            }
            menu.addArrangedSubview(row)
        }
        addSubview(menu); addSubview(workspace); workspace.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews(); workspace.frame = bounds
        let side = max(60, min((bounds.width - 34) / 2, (bounds.height - 38) / 2))
        let extent = side * 2 + 10
        menu.frame = CGRect(x: (bounds.width - extent) / 2, y: max(8, (bounds.height - extent) / 2), width: extent, height: extent)
    }
    private func pulse() { KeyboardVibration.shared.attach(to: self); KeyboardVibration.shared.pulseInterface() }
    private func option(_ title: String, selected: @escaping (KeyboardSettings) -> Bool = { _ in false }, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled(); config.title = title; config.cornerStyle = .capsule
        config.baseBackgroundColor = .secondarySystemFill; config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 3)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { values in
            var next = values; next.font = .systemFont(ofSize: 12, weight: .medium); return next
        }
        let button = FeedbackButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.pulse(); action() })
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true; options.append((button, selected)); return button
    }
    func show(_ item: AppearanceItem?) {
        if selected == item, !workspace.isHidden { apply(current()); return }
        selected = item; strength = nil; swatches = []; colors = []; options = []
        menu.isHidden = item != nil; workspace.isHidden = item == nil
        guard let item else { return }
        let reset = option("还原") { [weak self] in self?.edit {
            switch item {
            case .keyGlass: $0.keyGlassStrength = nil
            case .keyColor: $0.keyColorHex = nil
            case .candidateColor: $0.candidateColorHex = nil
            case .candidateSize: $0.candidateTextSize = nil; $0.candidateAnimation = nil
            }
        } }
        reset.accessibilityIdentifier = "keyboard.appearance.reset"
        switch item {
        case .keyGlass:
            workspace.configure(left: "玻璃预设", right: "通透强度"); workspace.right.distribution = .fill
            for (title, value) in [("清透", 0.9), ("均衡", 0.55), ("质感", 0.15)] {
                workspace.left.addArrangedSubview(option(title, selected: { abs($0.resolvedKeyGlassStrength - value) < 0.01 }) { [weak self] in self?.edit { $0.keyGlassStrength = value } })
            }
            workspace.left.addArrangedSubview(reset)
            let control = KeyboardVerticalValueControl(); strength = control
            control.slider.accessibilityIdentifier = "keyboard.appearance.strength"; control.slider.accessibilityLabel = "通透强度"
            control.onChange = { [weak self] value in self?.edit { $0.keyGlassStrength = value } }
            workspace.right.addArrangedSubview(control)
        case .candidateSize:
            workspace.configure(left: "文字大小", right: "候选动画")
            for size in CandidateTextSize.allCases {
                workspace.left.addArrangedSubview(option(size.title, selected: { $0.resolvedCandidateTextSize == size }) { [weak self] in self?.edit { $0.candidateTextSize = size } })
            }
            for animation in CandidateAnimation.allCases {
                workspace.right.addArrangedSubview(option(animation.shortTitle, selected: { $0.resolvedCandidateAnimation == animation }) { [weak self] in self?.edit { $0.candidateAnimation = animation } })
            }
            workspace.right.addArrangedSubview(reset)
        case .keyColor, .candidateColor:
            workspace.configure(left: "预设颜色", right: "RGB")
            let palette = ["#F2F3F8", "#292C39", "#7573F5", "#558DF2", "#D799BC", "#E3AC72"]
            for start in stride(from: 0, to: palette.count, by: 2) {
                let row = UIStackView(); row.spacing = 5; row.distribution = .fillEqually
                for hex in palette[start..<start + 2] {
                    let button = FeedbackButton(type: .custom); button.backgroundColor = KeyboardSettings.color(hex: hex); button.layer.cornerRadius = 9
                    button.heightAnchor.constraint(equalToConstant: 28).isActive = true
                    button.accessibilityLabel = hex; button.accessibilityIdentifier = "keyboard.swatch." + hex
                    button.addAction(UIAction { [weak self] _ in self?.pulse(); self?.setColor(hex) }, for: .touchUpInside)
                    row.addArrangedSubview(button); swatches.append((button, hex))
                }
                workspace.left.addArrangedSubview(row)
            }
            workspace.left.addArrangedSubview(reset)
            for (index, name) in ["R", "G", "B"].enumerated() {
                let control = KeyboardRGBControl(name: name); control.heightAnchor.constraint(equalToConstant: 44).isActive = true
                control.onChange = { [weak self] value in
                    guard let self else { return }; var rgb = self.color()
                    if index == 0 { rgb.red = value }; if index == 1 { rgb.green = value }; if index == 2 { rgb.blue = value }
                    self.setColor(rgb.hex)
                }
                colors.append(control); workspace.right.addArrangedSubview(control)
            }
        }
        apply(current()); setNeedsLayout()
    }
    private func edit(_ change: (inout KeyboardSettings) -> Void) {
        var value = current(); change(&value); guard value != current() else { return }; save(value); apply(value)
    }
    private func setColor(_ hex: String) { guard let path = selected?.colorPath else { return }; edit { $0[keyPath: path] = hex } }
    private func color() -> RGBColor {
        let value = selected?.colorPath.flatMap { current()[keyPath: $0] }
        let dark = traitCollection.userInterfaceStyle == .dark
        let fallback = selected == .keyColor ? (dark ? "#BFC4D6" : "#FFFFFF") : (dark ? "#F4F4F8" : "#20212A")
        return RGBColor(hex: value ?? fallback)!
    }
    func apply(_ settings: KeyboardSettings) {
        guard selected != nil else { return }; workspace.preview.apply(settings)
        for (button, matches) in options {
            let active = matches(settings); button.configuration?.baseBackgroundColor = active ? tintColor.withAlphaComponent(0.22) : .secondarySystemFill
            button.accessibilityTraits = active ? [.button, .selected] : .button
        }
        strength?.configure(value: settings.resolvedKeyGlassStrength)
        if selected?.colorPath != nil {
            let rgb = color(), values = [rgb.red, rgb.green, rgb.blue]
            for (index, control) in colors.enumerated() { control.configure(values[index]) }
            for (button, hex) in swatches {
                let active = rgb.hex == hex; button.layer.borderWidth = active ? 2 : 0; button.layer.borderColor = UIColor.label.cgColor
                button.accessibilityTraits = active ? [.button, .selected] : .button
            }
        }
    }
}

@MainActor private final class KeyboardRGBControl: UIView {
    private let name = UILabel(), amount = UILabel(), slider = UISlider()
    var onChange: ((Double) -> Void)?
    init(name title: String) {
        super.init(frame: .zero); name.text = title
        name.font = .monospacedSystemFont(ofSize: 11, weight: .medium); amount.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        amount.textAlignment = .right; amount.textColor = .secondaryLabel
        [name, amount, slider].forEach(addSubview); slider.accessibilityIdentifier = "keyboard.color." + title; slider.accessibilityLabel = "自定义颜色 " + title
        slider.addAction(UIAction { [weak self] _ in guard let self else { return }; self.updateAmount(); self.onChange?(Double(self.slider.value)) }, for: .valueChanged)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews(); name.frame = CGRect(x: 0, y: 0, width: 16, height: 14)
        amount.frame = CGRect(x: 18, y: 0, width: max(0, bounds.width - 18), height: 14)
        slider.frame = CGRect(x: 0, y: 15, width: bounds.width, height: 28)
    }
    func configure(_ value: Double) { if !slider.isTracking { slider.value = Float(value) }; updateAmount() }
    private func updateAmount() { amount.text = String(Int((slider.value * 255).rounded())) }
}
