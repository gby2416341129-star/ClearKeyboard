import UIKit
import SwiftUI

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
                if effectMode != "reduced" { lens.effect = nil; effectMode = "reduced" }; lens.alpha = 1; backgroundColor = fallback; tintFilm.backgroundColor = .clear
            } else if #available(iOS 26.0, *) {
                let mode = (clear || keycap) ? "native.clear" : "native.regular"
                if effectMode != mode {
                    let glass = UIGlassEffect(style: (clear || keycap) ? .clear : .regular)
                    glass.isInteractive = !keycap && !clear; glass.tintColor = nil
                    lens.effect = glass; effectMode = mode
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
                if effectMode != "blur" { lens.effect = UIBlurEffect(style: .systemUltraThinMaterial); effectMode = "blur" }; lens.alpha = 1; backgroundColor = .clear
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
#endif
    private var generator: UIImpactFeedbackGenerator?
    private weak var presentationView: UIView?
    private let emit: ((CGFloat) -> Void)?
    init(emit: ((CGFloat) -> Void)? = nil) { self.emit = emit }
    func attach(to view: UIView) {
        guard emit == nil, view.window != nil, presentationView !== view else { return }
        presentationView = view
        if #available(iOS 17.5, *) { generator = UIImpactFeedbackGenerator(style: .light, view: view) }
        else { generator = UIImpactFeedbackGenerator(style: .light) }
        generator?.prepare()
    }
    func prepare() { if emit == nil { generator?.prepare() } }
    func pulse(intensity: Double) {
        guard intensity.isFinite, intensity > 0 else { return }
        let value = CGFloat(min(1, max(0, intensity)))
        if let emit { emit(value); return }
        guard presentationView?.window != nil else { return }
        generator?.impactOccurred(intensity: value)
#if DEBUG
        if generator != nil { submittedPulses += 1 }
#endif
        generator?.prepare()
    }
    func stop() { generator = nil; presentationView = nil }
}
