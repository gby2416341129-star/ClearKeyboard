import UIKit
import SwiftUI
import CoreHaptics

/// Each instance owns exactly one control's bounds. There is no keyboard-wide
/// backdrop, noncontiguous material mask, or frozen intensity animator.
final class LiquidGlassView: UIView {
    private let lens = UIVisualEffectView(effect: nil)
    var effect: UIVisualEffect? { lens.effect }
    private let radius: CGFloat
    private let tintFilm = UIView()
    private let keycap: Bool
    private let clear: Bool
    private var signature = ""
    init(radius: CGFloat, keycap: Bool = false, clear: Bool = false) {
        self.radius = radius; self.keycap = keycap; self.clear = clear
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.cornerRadius = radius; layer.cornerCurve = .continuous; clipsToBounds = true
        addSubview(lens); addSubview(tintFilm); tintFilm.isUserInteractionEnabled = false
        lens.isUserInteractionEnabled = false
        configure(tint: nil, strength: 0.55, fallback: .secondarySystemBackground)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        lens.frame = rect; tintFilm.frame = rect
        CATransaction.commit()
    }
    func configure(tint: UIColor?, strength: Double, fallback: UIColor, reduced: Bool = UIAccessibility.isReduceTransparencyEnabled, colorOpacity: Double? = nil) {
        let strength = min(1, max(0, strength))
        let opacity = min(1, max(0, colorOpacity ?? (tint == nil ? 0.20 * (1 - strength) : 0.82 - strength * 0.16)))
        let key = "\(tint?.description ?? "auto")-\(strength)-\(opacity)-\(reduced)-\(traitCollection.userInterfaceStyle.rawValue)"
        guard signature != key else { return }; signature = key
        UIView.performWithoutAnimation {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            lens.effect = nil; lens.alpha = 1
            backgroundColor = .clear
            let dark = traitCollection.userInterfaceStyle == .dark
            let base = tint ?? (dark ? UIColor(red: keycap && !clear ? 0.22 : 0.12, green: keycap && !clear ? 0.24 : 0.14, blue: keycap && !clear ? 0.28 : 0.18, alpha: 1) : .white)
            let faceOpacity: CGFloat = reduced ? 1 : (tint == nil ? CGFloat(0.96-strength*0.36) : CGFloat(opacity))
            tintFilm.backgroundColor = base.withAlphaComponent(faceOpacity)
            layer.borderWidth = keycap ? 0 : 0.5
            layer.borderColor = UIColor.separator.withAlphaComponent(0.18).cgColor

        }
    }
}

struct LiquidCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var radius: CGFloat = 20
    var interactive = false
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: min(radius, 20), style: .continuous)
                .fill(colorScheme == .dark ? Color(red: 0.075, green: 0.090, blue: 0.125) : .white)
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
