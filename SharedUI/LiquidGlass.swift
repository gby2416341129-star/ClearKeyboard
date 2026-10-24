import UIKit
import SwiftUI
import CoreHaptics

/// Each instance owns exactly one control's bounds. There is no keyboard-wide
/// backdrop, noncontiguous material mask, or frozen intensity animator.
final class LiquidGlassView: UIVisualEffectView {
    private let radius: CGFloat
    private let tintFilm = UIView()
    private var signature = ""
    init(radius: CGFloat) {
        self.radius = radius
        super.init(effect: nil)
        isUserInteractionEnabled = false
        layer.cornerRadius = radius; layer.cornerCurve = .continuous; clipsToBounds = true
        contentView.addSubview(tintFilm); tintFilm.isUserInteractionEnabled = false
        configure(tint: nil, strength: 0.55, fallback: .secondarySystemBackground)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() { super.layoutSubviews(); tintFilm.frame = contentView.bounds }
    func configure(tint: UIColor?, strength: Double, fallback: UIColor, reduced: Bool = UIAccessibility.isReduceTransparencyEnabled) {
        let strength = min(1, max(0, strength))
        let key = "\(tint?.description ?? "auto")-\(strength)-\(reduced)-\(traitCollection.userInterfaceStyle.rawValue)"
        guard signature != key else { return }; signature = key
        UIView.performWithoutAnimation {
            if reduced {
                effect = nil; backgroundColor = fallback; tintFilm.backgroundColor = .clear
            } else if #available(iOS 26.0, *) {
                let glass = UIGlassEffect(style: .regular)
                glass.isInteractive = true
                glass.tintColor = tint?.withAlphaComponent(0.30 + strength * 0.45)
                effect = glass; backgroundColor = .clear
                cornerConfiguration = .corners(radius: .fixed(radius))
                // Keep custom key colors legible and make this independent
                // control's transmission adjustable without a shared sheet.
                tintFilm.backgroundColor = (tint ?? .white).withAlphaComponent(tint == nil ? 0.02 + strength * 0.10 : 0.30 + strength * 0.45)
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
