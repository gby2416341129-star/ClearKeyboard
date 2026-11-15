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
        addSubview(workspace); workspace.configure(left: "触感模式", right: "震动力度")
        workspace.right.distribution = .fill
        enabled.onTintColor = UIColor(red: 0.43, green: 0.40, blue: 0.91, alpha: 1)
        enabled.accessibilityIdentifier = "keyboard.vibration.enabled"; enabled.accessibilityLabel = "按键震动"
        enabled.addAction(UIAction { [weak self] _ in guard let self else { return }; self.edit { $0.vibrationEnabled = self.enabled.isOn } }, for: .valueChanged)
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
        // All five independent feedback switches share one card and one row
        // geometry. Typing mode/strength remain specific to typing feedback.
        let card = UIStackView(); card.axis = .vertical; card.distribution = .fillEqually
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        card.backgroundColor = UIColor.secondarySystemGroupedBackground.withAlphaComponent(0.7)
        card.layer.cornerRadius = 16; card.accessibilityIdentifier = "keyboard.vibration.controls"
        workspace.footerHeight = 236; workspace.footer.addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([card.leadingAnchor.constraint(equalTo: workspace.footer.leadingAnchor), card.trailingAnchor.constraint(equalTo: workspace.footer.trailingAnchor), card.topAnchor.constraint(equalTo: workspace.footer.topAnchor), card.bottomAnchor.constraint(equalTo: workspace.footer.bottomAnchor)])
        func addRow(_ title: String, toggle: UISwitch, separator: Bool) {
            let row = UIView(); let label = UILabel()
            label.text = title; label.font = .systemFont(ofSize: 14, weight: .medium); label.textColor = .label
            label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.9
            row.addSubview(label); row.addSubview(toggle)
            label.translatesAutoresizingMaskIntoConstraints = false; toggle.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: row.leadingAnchor), label.centerYAnchor.constraint(equalTo: row.centerYAnchor), label.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -10), toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor), toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor)])
            if separator {
                let line=UIView(); line.backgroundColor = .separator; line.translatesAutoresizingMaskIntoConstraints=false; row.addSubview(line)
                NSLayoutConstraint.activate([line.leadingAnchor.constraint(equalTo: row.leadingAnchor),line.trailingAnchor.constraint(equalTo: row.trailingAnchor),line.bottomAnchor.constraint(equalTo: row.bottomAnchor),line.heightAnchor.constraint(equalToConstant: 0.5)])
            }
            card.addArrangedSubview(row)
        }
        addRow("按键震动", toggle: enabled, separator: true)
        let fields: [(String, String, WritableKeyPath<KeyboardSettings, Bool?>)] = [
            ("Logo 点击震动", "logo", \.logoVibrationEnabled), ("小图标点击震动", "toolbarTap", \.toolbarTapVibrationEnabled), ("小图标滑动震动", "toolbarScroll", \.toolbarScrollVibrationEnabled), ("选词震动", "candidate", \.candidateVibrationEnabled)]
        for (index, field) in fields.enumerated() {
            let (title, identifier, path) = field
            let toggle = UISwitch(); toggle.onTintColor = enabled.onTintColor
            toggle.accessibilityLabel = title; toggle.accessibilityIdentifier = "keyboard.vibration." + identifier
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self, let toggle else { return }
                var settings = self.current(); settings[keyPath: path] = toggle.isOn
                self.save(settings); self.apply(settings)
            }, for: .valueChanged)
            addRow(title, toggle: toggle, separator: index < fields.count - 1)
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
