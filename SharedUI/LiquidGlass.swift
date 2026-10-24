import UIKit
import SwiftUI
import CoreHaptics

/// Each instance owns exactly one control's bounds. There is no keyboard-wide
/// backdrop, noncontiguous material mask, or frozen intensity animator.
final class LiquidGlassView: UIVisualEffectView {
    private let radius: CGFloat
    private let tintFilm = UIView()
    private let keycap: Bool
    private let clear: Bool
    private let glint = CAGradientLayer()
    private let rim = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private var signature = ""
    init(radius: CGFloat, keycap: Bool = false, clear: Bool = false) {
        self.radius = radius; self.keycap = keycap; self.clear = clear
        super.init(effect: nil)
        isUserInteractionEnabled = false
        layer.cornerRadius = radius; layer.cornerCurve = .continuous; clipsToBounds = true
        contentView.addSubview(tintFilm); tintFilm.isUserInteractionEnabled = false
        if keycap {
            for light in [glint, rim] { contentView.layer.addSublayer(light) }
            glint.startPoint = CGPoint(x: 0, y: 0); glint.endPoint = CGPoint(x: 0.85, y: 1)
            glint.locations = [0, 0.23, 0.50, 0.85, 1]
            rim.startPoint = .zero; rim.endPoint = CGPoint(x: 0.75, y: 1)
            rim.locations = [0, 0.20, 0.55, 0.83, 1]; rim.mask = rimMask
            rimMask.fillColor = UIColor.clear.cgColor; rimMask.strokeColor = UIColor.white.cgColor; rimMask.lineWidth = 0.75
        }
        configure(tint: nil, strength: 0.55, fallback: .secondarySystemBackground)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = contentView.bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tintFilm.frame = rect
        if keycap, glint.frame != rect {
            glint.frame = rect; rim.frame = rect; rimMask.frame = rect
            rimMask.path = rect.width > 1 && rect.height > 1 ? UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: max(0, radius - 0.5)).cgPath : nil
        }
        CATransaction.commit()
    }
    func configure(tint: UIColor?, strength: Double, fallback: UIColor, reduced: Bool = UIAccessibility.isReduceTransparencyEnabled) {
        let strength = min(1, max(0, strength))
        let key = "\(tint?.description ?? "auto")-\(strength)-\(reduced)-\(traitCollection.userInterfaceStyle.rawValue)"
        guard signature != key else { return }; signature = key
        UIView.performWithoutAnimation {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            if keycap {
                glint.isHidden = reduced; rim.isHidden = reduced
                let light = CGFloat(0.5 + strength * 0.5)
                glint.colors = [UIColor.white.withAlphaComponent(0.24 * light).cgColor,
                                UIColor.white.withAlphaComponent(0.09 * light).cgColor,
                                UIColor.white.withAlphaComponent(0.015).cgColor,
                                UIColor.clear.cgColor,
                                UIColor(red: 0.72, green: 0.84, blue: 1, alpha: 0.10 * light).cgColor]
                rim.colors = [UIColor.white.withAlphaComponent(0.66 * light).cgColor,
                              UIColor.white.withAlphaComponent(0.24 * light).cgColor,
                              UIColor.white.withAlphaComponent(0.035).cgColor,
                              UIColor.white.withAlphaComponent(0.10 * light).cgColor,
                              UIColor.white.withAlphaComponent(0.34 * light).cgColor]
            }
            if reduced {
                effect = nil; backgroundColor = fallback; tintFilm.backgroundColor = .clear
            } else if #available(iOS 26.0, *) {
                let glass = UIGlassEffect(style: clear ? .clear : .regular)
                glass.isInteractive = true
                glass.tintColor = tint?.withAlphaComponent(0.30 + strength * 0.45)
                effect = glass; backgroundColor = .clear
                cornerConfiguration = .corners(radius: .fixed(radius))
                // Keep custom key colors legible and make this independent
                // control's transmission adjustable without a shared sheet.
                tintFilm.backgroundColor = clear ? .clear : (tint ?? .white).withAlphaComponent(tint == nil ? 0.02 + strength * 0.10 : 0.30 + strength * 0.45)
            } else {
                effect = UIBlurEffect(style: .systemThinMaterial); backgroundColor = .clear
                tintFilm.backgroundColor = (tint ?? .white).withAlphaComponent(0.08 + strength * 0.25)
            }
        }
    }
}

struct LiquidCard: ViewModifier {
    var radius: CGFloat = 24
    var interactive = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(interactive), in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

/// One prepared actuator per keyboard process. Direct, ordered main-thread
/// calls only: no delayed tasks, extra release pulses, or per-key generators.
@MainActor final class KeyboardVibration {
    static let shared = KeyboardVibration()
    private let generator = UIImpactFeedbackGenerator(style: .soft)
    private let emit: ((CGFloat) -> Void)?
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    private var starting = false
    private var ready = false
    private var generation = 0
    init(emit: ((CGFloat) -> Void)? = nil) { self.emit = emit }
    func prepare() {
        guard emit == nil else { return }
        generator.prepare()
        guard !starting, !ready, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            if engine == nil {
                let value = try CHHapticEngine()
                value.playsHapticsOnly = true; value.isAutoShutdownEnabled = true
                value.stoppedHandler = { [weak self] _ in
                    Task { @MainActor in self?.ready = false }
                }
                value.resetHandler = { [weak self] in
                    Task { @MainActor in self?.ready = false; self?.player = nil; self?.prepare() }
                }
                engine = value
            }
            if player == nil, let engine {
                // One short rounded impact: no delayed second hit to overlap
                // the next letter. Intensity stays continuously adjustable.
                let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35)
                ], relativeTime: 0)
                player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            }
            starting = true; let revision = generation
            engine?.start { [weak self] error in
                Task { @MainActor in
                    guard let self, self.generation == revision else { return }
                    self.starting = false; self.ready = error == nil
                    // Never replay a key pressed during engine startup.
                }
            }
        } catch { starting = false; ready = false }
    }
    func pulse(intensity: Double) {
        guard intensity.isFinite, intensity > 0 else { return }
        let value = CGFloat(min(1, max(0, intensity)))
        if let emit { emit(value); return }
        if ready, let player {
            do {
                try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: Float(value), relativeTime: 0)], atTime: CHHapticTimeImmediate)
                try player.start(atTime: CHHapticTimeImmediate)
                return
            } catch { ready = false }
        }
        generator.impactOccurred(intensity: value)
        prepare()
    }
    func stop() {
        generation += 1; ready = false; starting = false
        engine?.stop(completionHandler: nil)
    }
}
