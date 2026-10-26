import UIKit

@MainActor final class CandidateActionsOverlay: UIControl {
    var onDismiss: (() -> Void)?
    private let card = UIView()
    private let glass = LiquidGlassView(radius: 18, clear: true)
    init(anchor: CGRect, in host: UIView, pin: @escaping () -> Void, remove: @escaping () -> Void) {
        super.init(frame: host.bounds)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .clear
        accessibilityIdentifier = "candidate.actions"
        addTarget(self, action: #selector(close), for: .touchUpInside)
        card.frame = CGRect(x: min(max(8, anchor.midX - 119), max(8, host.bounds.width - 246)),
                            y: min(anchor.maxY + 5, max(0, host.bounds.height - 57)), width: 238, height: 50)
        card.layer.cornerRadius = 18; card.clipsToBounds = true
        glass.frame = card.bounds; glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.configure(tint: nil, strength: 0.70, fallback: .secondarySystemBackground)
        card.addSubview(glass); addSubview(card)
        let actions: [(String, String, () -> Void)] = [("固定首位", "pin", pin), ("删除该词", "trash", remove)]
        for (index, action) in actions.enumerated() {
            var config = UIButton.Configuration.plain(); config.title = action.0
            config.image = UIImage(systemName: action.1); config.imagePadding = 6
            config.baseForegroundColor = index == 0 ? .label : .systemRed
            let button = FeedbackButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                KeyboardVibration.shared.pulseInterface(); action.2(); self?.close()
            })
            button.frame = CGRect(x: CGFloat(index) * 119, y: 0, width: 119, height: 50)
            button.accessibilityIdentifier = index == 0 ? "candidate.pinFirst" : "candidate.deleteWord"
            card.addSubview(button)
        }
        card.alpha = 0; card.transform = CGAffineTransform(translationX: 0, y: -3).scaledBy(x: 0.97, y: 0.97)
        UIView.animate(withDuration: 0.24, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) { self.card.alpha = 1; self.card.transform = .identity }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    @objc func close() { onDismiss?(); onDismiss = nil; removeFromSuperview() }
}
