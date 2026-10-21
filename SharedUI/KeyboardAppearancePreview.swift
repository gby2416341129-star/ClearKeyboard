import UIKit

/// One shared material pass, clipped to the key faces. Geometry is rebuilt only
/// when keys move, rather than creating a blur/refraction view for every letter.
final class KeyGlassMaterial: UIVisualEffectView {
    private let shape = CAShapeLayer()
    private let effectMask = UIView()
    private var signature = ""
    private var faces: [CGRect] = []
    private var maskSize = CGSize.zero
    private var strength: CGFloat = -1
    override init(effect: UIVisualEffect?) {
        super.init(effect: effect); isUserInteractionEnabled = false
        effectMask.layer.addSublayer(shape); shape.fillColor = UIColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func setFaces(_ value: [CGRect]) {
        guard faces != value || maskSize != bounds.size || mask == nil else { return }
        faces = value; updateMask()
    }
    private func updateMask() {
        maskSize = bounds.size
        let path = UIBezierPath()
        for face in faces { path.append(UIBezierPath(roundedRect: face, cornerRadius: 8)) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectMask.frame = bounds; effectMask.alpha = max(0, strength)
        shape.frame = bounds; shape.path = path.cgPath
        // Assign the mask to the visual-effect view itself, not a superview.
        // UIKit then applies it to both the effect and the content.
        mask = nil; mask = effectMask
        CATransaction.commit()
    }
    func apply(_ settings: KeyboardSettings) {
        let reduced = UIAccessibility.isReduceTransparencyEnabled || ProcessInfo.processInfo.isLowPowerModeEnabled || settings.glass == .solid
        let next = "\(settings.glass)-\(reduced)"
        if next != signature {
            signature = next
            var target: UIVisualEffect?
            if reduced { target = nil }
            else if #available(iOS 26.0, *) {
                let glass = UIGlassEffect(style: settings.glass == .clear ? .clear : .regular)
                glass.isInteractive = false; target = glass
            } else { target = UIBlurEffect(style: settings.glass == .clear ? .systemUltraThinMaterial : .systemMaterial) }
            UIView.performWithoutAnimation { effect = target }
        }
        let nextStrength = CGFloat(settings.resolvedKeyGlassStrength)
        if strength != nextStrength || mask == nil { strength = nextStrength; updateMask() }
    }
}

/// The preview uses the production key, text and material views at their final
/// logical sizes. It does not create an input engine or scale a keyboard bitmap.
final class KeyboardAppearancePreview: UIView {
    private let scenery = CAGradientLayer()
    private let backdrop = GlassBackdrop()
    private let keyArea = UIView()
    private let glass = KeyGlassMaterial(effect: nil)
    private let first = CandidateButton(), second = CandidateButton()
    private var keys: [(KeyButton, Int, Double, Double)] = []
    private var settings = KeyboardSettings()
    private var appliedSettings: KeyboardSettings?
    private var appliedStyle = UIUserInterfaceStyle.unspecified
    private var appliedReducedTransparency: Bool?
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 22; layer.cornerCurve = .continuous; clipsToBounds = true
        scenery.colors = [UIColor(red: 0.30, green: 0.38, blue: 0.65, alpha: 1).cgColor,
                          UIColor(red: 0.58, green: 0.40, blue: 0.64, alpha: 1).cgColor]
        scenery.startPoint = CGPoint(x: 0, y: 0); scenery.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(scenery); addSubview(backdrop)
        addSubview(first); addSubview(second); addSubview(keyArea); keyArea.addSubview(glass)
        for (index, row) in KeyboardLayout.rows(page: .letters, uppercase: true, globe: false).enumerated() {
            var start = row.insetUnits
            for key in row.keys {
                let button = KeyButton(key: key); keyArea.addSubview(button)
                keys.append((button, index, start, key.units)); start += key.units
            }
        }
        isUserInteractionEnabled = false; isAccessibilityElement = true
        accessibilityLabel = "键盘效果预览"; accessibilityIdentifier = "appearance.preview"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func apply(_ value: KeyboardSettings) {
        let reduced = UIAccessibility.isReduceTransparencyEnabled || ProcessInfo.processInfo.isLowPowerModeEnabled
        guard appliedSettings != value || appliedStyle != traitCollection.userInterfaceStyle || appliedReducedTransparency != reduced else { return }
        appliedSettings = value; appliedStyle = traitCollection.userInterfaceStyle
        appliedReducedTransparency = reduced
        settings = value; backdrop.apply(value); glass.apply(value)
        for (key, _, _, _) in keys { key.apply(value) }
        let font = UIFont.systemFont(ofSize: CGFloat(value.resolvedCandidateTextSize.points))
        first.configure(Candidate(text: "今天", consumed: 0), first: true, accent: value.accentInkColor,
                        font: font, normalColor: value.candidateTintColor)
        second.configure(Candidate(text: "你好", consumed: 0), first: false, accent: value.accentInkColor,
                         font: font, normalColor: value.candidateTintColor)
        accessibilityValue = "background:\(value.resolvedBackgroundGlassStrength);keys:\(value.resolvedKeyGlassStrength);backgroundColor:\(value.backgroundColorHex ?? "auto");keyColor:\(value.keyColorHex ?? "auto");candidateColor:\(value.candidateColorHex ?? "auto");font:\(value.resolvedCandidateTextSize.rawValue)"
        setNeedsLayout()
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true { apply(settings) }
    }
    override func layoutSubviews() {
        super.layoutSubviews(); scenery.frame = bounds; backdrop.frame = bounds
        let metrics = KeyboardGeometry.Metrics(keyHeight: settings.keyHeight)
        let layout = KeyboardGeometry.layout(size: bounds.size, metrics: metrics, hand: .full, fitHeight: true)
        keyArea.frame = layout.keys; glass.frame = keyArea.bounds
        var faces: [CGRect] = []
        for (button, row, start, units) in keys {
            button.frame = CGRect(x: CGFloat(start) * layout.unitWidth, y: CGFloat(row) * layout.rowPitch,
                                  width: CGFloat(units) * layout.unitWidth, height: layout.rowPitch)
            faces.append(KeyboardGeometry.keyPlate(in: button.bounds, action: button.key.action, units: units).offsetBy(dx: button.frame.minX, dy: button.frame.minY))
        }
        glass.setFaces(faces)
        first.frame = CGRect(x: 10, y: 1, width: 90, height: 43)
        second.frame = CGRect(x: 104, y: 1, width: 90, height: 43)
    }
}
