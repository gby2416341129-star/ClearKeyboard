import UIKit

@MainActor final class KeyboardHapticPanel: UIView {
    private let workspace = KeyboardAdjustmentWorkspace()
    private let enabled = UISwitch()
    private let strength = KeyboardVerticalValueControl()
    private var modes: [(VibrationMode, UIButton)] = []
    private let current: () -> KeyboardSettings
    private let save: (KeyboardSettings) -> Void
    init(current: @escaping () -> KeyboardSettings, save: @escaping (KeyboardSettings) -> Void) {
        self.current = current; self.save = save; super.init(frame: .zero)
        isOpaque = false; backgroundColor = .clear; accessibilityIdentifier = "keyboard.vibration.panel"
        addSubview(workspace); workspace.configure(left: "按键触感", right: "震动力度")
        workspace.right.distribution = .fill
        let switchRow = UIView(); switchRow.heightAnchor.constraint(equalToConstant: 31).isActive = true
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
        workspace.right.addArrangedSubview(strength); apply(current())
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
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true; return button
    }
    func apply(_ settings: KeyboardSettings) {
        enabled.isOn = settings.usesVibration
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
