import UIKit

@MainActor final class KeyboardHapticPanel: UIView {
    private let workspace = KeyboardAdjustmentWorkspace()
    private let enabled = UISwitch()
    private let strength = KeyboardVerticalValueControl()
    private var interactionSwitches: [(UISwitch, WritableKeyPath<KeyboardSettings, Bool?>)] = []
    private var modes: [(VibrationMode, UIButton)] = []
    private let current: () -> KeyboardSettings
    private let save: (KeyboardSettings) -> Void
    init(current: @escaping () -> KeyboardSettings, save: @escaping (KeyboardSettings) -> Void) {
        self.current = current; self.save = save; super.init(frame: .zero)
        isOpaque = false; backgroundColor = .clear; accessibilityIdentifier = "keyboard.vibration.panel"
        addSubview(workspace); workspace.configure(left: "按键触感", right: "震动力度")
        workspace.right.distribution = .fill
        let switchRow = UIView(); switchRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 31).isActive = true
        enabled.onTintColor = UIColor(red: 0.43, green: 0.40, blue: 0.91, alpha: 1)
        enabled.translatesAutoresizingMaskIntoConstraints = false; switchRow.addSubview(enabled)
        NSLayoutConstraint.activate([enabled.centerXAnchor.constraint(equalTo: switchRow.centerXAnchor), enabled.centerYAnchor.constraint(equalTo: switchRow.centerYAnchor)])
        enabled.accessibilityIdentifier = "keyboard.vibration.enabled"; enabled.accessibilityLabel = "按键震动"
        enabled.addAction(UIAction { [weak self] _ in guard let self else { return }; self.edit { $0.vibrationEnabled = self.enabled.isOn } }, for: .valueChanged)
        workspace.left.addArrangedSubview(switchRow)
        for mode in VibrationMode.allCases {
            let button = option(mode.title) { [weak self] in self?.edit { $0.vibrationMode = mode } }
            button.accessibilityIdentifier = "keyboard.vibration.mode." + mode.rawValue
            modes.append((mode, button)); workspace.left.addArrangedSubview(button)
        }
        let reset = option("还原") { [weak self] in self?.edit { $0.vibrationIntensity = nil } }
        reset.accessibilityIdentifier = "keyboard.vibration.reset"; workspace.left.addArrangedSubview(reset)
        strength.slider.accessibilityIdentifier = "keyboard.vibration.strength"; strength.slider.accessibilityLabel = "震动力度"
        strength.onChange = { [weak self] value in self?.edit { $0.vibrationIntensity = value } }
        workspace.right.addArrangedSubview(strength)
        let interactions = UIStackView(); interactions.axis = .horizontal; interactions.spacing = 8; interactions.distribution = .fillEqually
        workspace.footerHeight = 65; workspace.footer.addSubview(interactions)
        interactions.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([interactions.leadingAnchor.constraint(equalTo: workspace.footer.leadingAnchor), interactions.trailingAnchor.constraint(equalTo: workspace.footer.trailingAnchor), interactions.topAnchor.constraint(equalTo: workspace.footer.topAnchor), interactions.bottomAnchor.constraint(equalTo: workspace.footer.bottomAnchor)])
        let fields: [(String, String, WritableKeyPath<KeyboardSettings, Bool?>)] = [
            ("Logo 点击", "logo", \.logoVibrationEnabled), ("小图标点击", "toolbarTap", \.toolbarTapVibrationEnabled), ("小图标滑动", "toolbarScroll", \.toolbarScrollVibrationEnabled), ("选词", "candidate", \.candidateVibrationEnabled)]
        for (title, identifier, path) in fields {
            let card = UIStackView(); card.axis = .vertical; card.alignment = .center; card.spacing = 7
            let label = UILabel(); label.text = title; label.font = .systemFont(ofSize: 12, weight: .medium); label.textColor = .secondaryLabel
            let toggle = UISwitch(); toggle.onTintColor = enabled.onTintColor
            toggle.accessibilityLabel = title + "震动"; toggle.accessibilityIdentifier = "keyboard.vibration." + identifier
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self, let toggle else { return }
                // Interaction preferences are independent of typing feedback.
                var settings = self.current(); settings[keyPath: path] = toggle.isOn
                self.save(settings); self.apply(settings)
            }, for: .valueChanged)
            card.addArrangedSubview(label); card.addArrangedSubview(toggle); interactions.addArrangedSubview(card)
            interactionSwitches.append((toggle, path))
        }
        apply(current())
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() { super.layoutSubviews(); workspace.frame = bounds }
    private func option(_ title: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled(); config.title = title; config.cornerStyle = .capsule
        config.baseBackgroundColor = .secondarySystemFill; config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 3)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { values in
            var next = values; next.font = .systemFont(ofSize: 12, weight: .medium); return next
        }
        let button = FeedbackButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true; return button
    }
    func apply(_ settings: KeyboardSettings) {
        enabled.isOn = settings.usesVibration
        for (toggle, path) in interactionSwitches { toggle.isOn = settings[keyPath: path] ?? true }
        workspace.preview.apply(settings)
        for (mode, button) in modes {
            let active = settings.resolvedVibrationMode == mode
            button.isEnabled = settings.usesVibration
            button.configuration?.baseBackgroundColor = active ? tintColor.withAlphaComponent(0.22) : .secondarySystemFill
            button.accessibilityTraits = active ? [.button, .selected] : .button
        }
        strength.configure(value: settings.resolvedVibrationIntensity, enabled: settings.usesVibration)
    }
    private func edit(_ change: (inout KeyboardSettings) -> Void) {
        var settings = current(); change(&settings); save(settings); apply(settings)
        guard settings.usesVibration else { return }; KeyboardVibration.shared.attach(to: self)
        KeyboardVibration.shared.pulse(intensity: settings.resolvedVibrationIntensity, mode: settings.resolvedVibrationMode)
    }
}
