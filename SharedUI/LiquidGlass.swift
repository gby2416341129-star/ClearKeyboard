import UIKit
import SwiftUI

/// Each instance owns exactly one control's bounds. There is no keyboard-wide
/// backdrop, noncontiguous material mask, or frozen intensity animator.
final class LiquidGlassView: UIView {
    private let lens = UIVisualEffectView(effect: nil)
    private var installedEffect: UIVisualEffect?
    var effect: UIVisualEffect? { installedEffect }
    private func installEffect(_ value: UIVisualEffect?) {
        installedEffect = value; lens.effect = value
    }
    private let radius: CGFloat
    private let tintFilm = UIView()
    private let keycap: Bool
    private let clear: Bool
    private var signature = ""
    private var effectMode = ""
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
        let physicalKey = keycap && !clear
        let defaultOpacity = physicalKey
            ? (tint == nil ? 0.075 * (1 - strength) : 0.62 - strength * 0.26)
            : (tint == nil ? 0.20 * (1 - strength) : 0.82 - strength * 0.16)
        let opacity = min(1, max(0, colorOpacity ?? defaultOpacity))
        let key = "\(tint?.description ?? "auto")-\(strength)-\(opacity)-\(reduced)-\(traitCollection.userInterfaceStyle.rawValue)"
        guard signature != key else { return }; signature = key
        UIView.performWithoutAnimation {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            if reduced {
                if effectMode != "reduced" { installEffect(nil); effectMode = "reduced" }; lens.alpha = 1; backgroundColor = fallback; tintFilm.backgroundColor = .clear
            } else if #available(iOS 26.0, *) {
                let mode = (clear || keycap) ? "native.clear" : "native.regular"
                if effectMode != mode {
                    let glass = UIGlassEffect(style: (clear || keycap) ? .clear : .regular)
                    glass.isInteractive = !keycap && !clear; glass.tintColor = nil
                    installEffect(glass); effectMode = mode
                }
                backgroundColor = .clear
                // Physical keys repeat across the entire keyboard. Attenuate the
                // native lens itself so its rim and white reflection stay quiet.
                // Other glass surfaces and all foreground artwork keep their strength.
                lens.alpha = physicalKey ? CGFloat(0.40 - 0.22 * strength)
                    : (keycap ? CGFloat(0.62 - 0.22 * strength) : (clear ? 0.50 : 0.62))
                lens.cornerConfiguration = .corners(radius: .fixed(radius))
                // The native lens owns its edge and reflections. Higher
                // transmission removes the face film; never add a dark veil.
                tintFilm.backgroundColor = clear ? .clear : (tint ?? .white).withAlphaComponent(CGFloat(opacity))
            } else {
                if effectMode != "blur" { installEffect(UIBlurEffect(style: .systemUltraThinMaterial)); effectMode = "blur" }; lens.alpha = 1; backgroundColor = .clear
                tintFilm.backgroundColor = clear ? .clear : (tint ?? .white).withAlphaComponent(CGFloat(opacity))
            }
        }
    }
}

struct LiquidCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var radius: CGFloat = 24
    var interactive = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.background {
                RoundedRectangle(cornerRadius: radius).fill(Color.clear)
                    .glassEffect(.clear.interactive(interactive), in: RoundedRectangle(cornerRadius: radius))
                    .opacity(colorScheme == .dark ? 0.28 : 0.52)
            }
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

/// One prepared actuator per keyboard process. Direct, ordered main-thread
/// calls only: no delayed tasks, extra release pulses, or per-key generators.
@MainActor final class KeyboardVibration {
    static let shared = KeyboardVibration()
#if DEBUG
    private(set) var submittedPulses = 0
    private(set) var requestedStyle: UIImpactFeedbackGenerator.FeedbackStyle?
#endif
    private var scrollGenerator: UISelectionFeedbackGenerator?
    private var generators: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]
    private weak var presentationView: UIView?
    private weak var presentationWindow: UIWindow?
    private let emit: ((CGFloat) -> Void)?
    init(emit: ((CGFloat) -> Void)? = nil) { self.emit = emit }
    private func generator(for style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        if let generator = generators[style] { return generator }
        // Bind feedback to the active keyboard's view, as in the working
        // Build 65 path. An unassociated generator can target the extension
        // process instead of the hosted, interactive keyboard scene.
        let generator: UIImpactFeedbackGenerator
        if let view = presentationView, view.window != nil {
            generator = UIImpactFeedbackGenerator(style: style, view: view)
        } else { generator = UIImpactFeedbackGenerator(style: style) }
        generators[style] = generator
        generator.prepare()
        return generator
    }
    func attach(to view: UIView) {
        guard emit == nil else { return }
        var anchor = view
        var ancestor: UIView? = view
        while let current = ancestor {
            if current is KeyboardSurface { anchor = current; break }
            ancestor = current.superview
        }
        // A transient detached callback must not replace the last live host.
        guard let window = anchor.window else { return }
        guard presentationView !== anchor || presentationWindow !== window || generators.isEmpty else { return }
        presentationView = anchor; presentationWindow = window; generators.removeAll(); scrollGenerator = nil
        for style in [UIImpactFeedbackGenerator.FeedbackStyle.rigid, .soft, .heavy, .medium] {
            generator(for: style).prepare()
        }
    }
    func prepare(mode: VibrationMode = .crisp) {
        if emit == nil { generator(for: mode == .crisp ? .rigid : .soft).prepare() }
    }
    // Keep the attack characteristic independent of strength. Switching among
    // soft/light/heavy while moving the slider changed the whole sensation.
    // Each touch submits one transient, with no delayed tail or release pulse.
    static func profile(intensity: Double, mode: VibrationMode) -> (style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        guard intensity.isFinite, intensity > 0 else { return (mode == .crisp ? .rigid : .soft, 0) }
        let strength = min(1, intensity)
        return mode == .crisp ? (.rigid, CGFloat(0.22 + 0.78 * strength))
            : (.soft, CGFloat(0.14 + 0.58 * strength))
    }
    func pulse(intensity: Double, mode: VibrationMode = .crisp) {
        guard intensity.isFinite, intensity > 0 else { return }
        let profile = Self.profile(intensity: intensity, mode: mode)
        let value = profile.intensity, style = profile.style
#if DEBUG
        requestedStyle = style
#endif
        if let emit { emit(value); return }
        let generator = generator(for: style)
        generator.impactOccurred(intensity: value)
#if DEBUG
        submittedPulses += 1
#endif
        generator.prepare()
    }
    func prepareCursorActivation() {
        if emit == nil { generator(for: .medium).prepare() }
    }
    func pulseCursorActivation() {
        // One system transient on entering caret mode; no drag or release pulses.
#if DEBUG
        requestedStyle = .medium
#endif
        if let emit { emit(0.7); return }
        let feedback = generator(for: .medium)
        feedback.impactOccurred()
#if DEBUG
        submittedPulses += 1
#endif
        feedback.prepare()
    }
    func pulseInterface() {
#if DEBUG
        requestedStyle = .heavy
#endif
        if let emit { emit(1); return }
        let generator = generator(for: .heavy)
        generator.impactOccurred(intensity: 1)
#if DEBUG
        submittedPulses += 1
#endif
        generator.prepare()
    }
    private func selectionGenerator() -> UISelectionFeedbackGenerator {
        if let scrollGenerator { return scrollGenerator }
        let feedback: UISelectionFeedbackGenerator
        if let view = presentationView, view.window != nil { feedback = UISelectionFeedbackGenerator(view: view) }
        else { feedback = UISelectionFeedbackGenerator() }
        scrollGenerator = feedback; return feedback
    }
    func prepareScroll() { if emit == nil { selectionGenerator().prepare() } }
    func pulseScroll(speed: CGFloat) {
        // Selection ticks replace the dense rigid impacts. Cadence follows
        // scroll travel; the feedback generator stays attached to the host.
        if let emit { emit(0.25); return }
        let feedback = selectionGenerator(); feedback.selectionChanged(); feedback.prepare()
#if DEBUG
        submittedPulses += 1
#endif
    }
    func stop() { scrollGenerator = nil; generators = [:]; presentationView = nil; presentationWindow = nil }
}
