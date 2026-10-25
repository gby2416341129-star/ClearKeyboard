import UIKit

@MainActor final class KeyboardHapticPanel: UIView {
    private let enabled = UISwitch()
    private let modes = UISegmentedControl(items: VibrationMode.allCases.map(\.title))
    private let strength = ValueSliderView()
    private let stack = UIStackView()
    private let current: () -> KeyboardSettings
    private let save: (KeyboardSettings) -> Void
    init(current: @escaping () -> KeyboardSettings, save: @escaping (KeyboardSettings) -> Void) {
        self.current = current; self.save = save
        super.init(frame: .zero)
        accessibilityIdentifier = "keyboard.vibration.panel"
        let title = UILabel(); title.text = "按键震动"; title.font = .systemFont(ofSize: 16, weight: .medium)
        enabled.accessibilityIdentifier = "keyboard.vibration.enabled"
        let row = UIStackView(arrangedSubviews: [title, enabled]); row.alignment = .center
        stack.axis = .vertical; stack.spacing = 18; stack.addArrangedSubview(row)
        modes.accessibilityIdentifier = "keyboard.vibration.mode"
        stack.addArrangedSubview(modes); stack.addArrangedSubview(strength)
        strength.heightAnchor.constraint(equalToConstant: 76).isActive = true
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: topAnchor, constant: 8)])
        enabled.addAction(UIAction { [weak self] _ in self?.edit { $0.vibrationEnabled = self?.enabled.isOn } }, for: .valueChanged)
        modes.addAction(UIAction { [weak self] _ in
            guard let self, VibrationMode.allCases.indices.contains(self.modes.selectedSegmentIndex) else { return }
            self.edit { $0.vibrationMode = VibrationMode.allCases[self.modes.selectedSegmentIndex] }
        }, for: .valueChanged)
        strength.onCommit = { [weak self] value in self?.edit { $0.vibrationIntensity = value } }
        apply(current())
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func apply(_ settings: KeyboardSettings) {
        enabled.isOn = settings.usesVibration
        modes.selectedSegmentIndex = VibrationMode.allCases.firstIndex(of: settings.resolvedVibrationMode) ?? 0
        modes.isEnabled = settings.usesVibration; strength.isUserInteractionEnabled = settings.usesVibration
        strength.alpha = settings.usesVibration ? 1 : 0.4
        strength.configure(title: "震动力度", value: settings.resolvedVibrationIntensity, range: 0...1,
                           defaultValue: 0.45, identifier: "keyboard.vibration.strength", percent: true)
    }
    private func edit(_ change: (inout KeyboardSettings) -> Void) {
        var settings = current(); change(&settings); save(settings); apply(settings)
        guard settings.usesVibration else { return }
        KeyboardVibration.shared.attach(to: self)
        KeyboardVibration.shared.pulse(intensity: settings.resolvedVibrationIntensity, mode: settings.resolvedVibrationMode)
    }
}
