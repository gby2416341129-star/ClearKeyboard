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
            // A refractive glass panel outlines its entire rectangle before a
            // noncontiguous mask is applied. Diffuse material can follow the key
            // faces without drawing a second rim around the whole key area.
            else { target = UIBlurEffect(style: settings.glass == .clear ? .systemUltraThinMaterial : .systemMaterial) }
            UIView.performWithoutAnimation { effect = target }
        }
        let nextStrength = CGFloat(settings.resolvedKeyGlassStrength)
        if strength != nextStrength || mask == nil { strength = nextStrength; updateMask() }
    }
}

/// Production views are laid out once at the real keyboard's logical size, then
/// the whole canvas is scaled uniformly. The preview never compresses row pitch
/// independently of the text, symbols, insets or key faces.
final class KeyboardAppearancePreview: UIView {
    private let canvas = UIView()
    // A local material approximates the host's neutral keyboard base. An
    // ordinary UIInputView subview does not receive the responder's automatic
    // backdrop. The extension itself uses the actual host-owned base.
    private let nativeBase = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let keyArea = UIView()
    private let glass = KeyGlassMaterial(effect: nil)
    private let first = CandidateButton(), second = CandidateButton()
    private var keys: [(KeyButton, Int, Double, Double)] = []
    private var settings = KeyboardSettings()
    private var appliedSettings: KeyboardSettings?
    private var appliedStyle = UIUserInterfaceStyle.unspecified
    private var appliedReducedTransparency: Bool?
    private var renderedScale: CGFloat = 0
    private var nativeCanvasWidth: CGFloat {
        let width = window?.bounds.width ?? UIScreen.main.bounds.width
        return width.isFinite && width > 0 ? width : max(1, bounds.width)
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; backgroundColor = .clear
        canvas.accessibilityIdentifier = "appearance.keyboard-canvas"
        // The preview has one descriptive accessibility element. Its rendered
        // keys are not live controls and must not masquerade as an input view.
        canvas.accessibilityElementsHidden = true
        canvas.layer.cornerRadius = 22; canvas.layer.cornerCurve = .continuous; canvas.clipsToBounds = true
        addSubview(canvas)
        nativeBase.isUserInteractionEnabled = false
        nativeBase.accessibilityIdentifier = "appearance.native-base"
        canvas.addSubview(nativeBase)
        canvas.addSubview(first); canvas.addSubview(second); canvas.addSubview(keyArea); keyArea.addSubview(glass)
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
    func fittingSize(forWidth width: CGFloat) -> CGSize {
        let width = width.isFinite ? max(0, width) : 0
        let height = KeyboardGeometry.Metrics(keyHeight: settings.keyHeight).contentHeight
        return CGSize(width: width, height: width / nativeCanvasWidth * height)
    }
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: fittingSize(forWidth: bounds.width).height)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        renderedScale = 0; invalidateIntrinsicContentSize(); setNeedsLayout()
    }
    static func accessibilityDescription(of value: KeyboardSettings) -> String {
        "keys:\(value.resolvedKeyGlassStrength);keyColor:\(value.keyColorHex ?? "auto");candidateColor:\(value.candidateColorHex ?? "auto");font:\(value.resolvedCandidateTextSize.rawValue)"
    }
    func apply(_ value: KeyboardSettings) {
        let reduced = UIAccessibility.isReduceTransparencyEnabled || ProcessInfo.processInfo.isLowPowerModeEnabled
        guard appliedSettings != value || appliedStyle != traitCollection.userInterfaceStyle || appliedReducedTransparency != reduced else { return }
        appliedSettings = value; appliedStyle = traitCollection.userInterfaceStyle
        appliedReducedTransparency = reduced
        settings = value; glass.apply(value)
        for (key, _, _, _) in keys { key.apply(value) }
        let font = UIFont.systemFont(ofSize: CGFloat(value.resolvedCandidateTextSize.points))
        let firstFont = UIFont.systemFont(ofSize: CGFloat(value.resolvedCandidateTextSize.points), weight: .medium)
        first.configure(Candidate(text: "今天", consumed: 0), first: true, accent: value.accentInkColor,
                        font: firstFont, normalColor: value.candidateTintColor)
        second.configure(Candidate(text: "你好", consumed: 0), first: false, accent: value.accentInkColor,
                         font: font, normalColor: value.candidateTintColor)
        accessibilityValue = Self.accessibilityDescription(of: value)
        invalidateIntrinsicContentSize(); setNeedsLayout()
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true { apply(settings) }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return }
        let metrics = KeyboardGeometry.Metrics(keyHeight: settings.keyHeight)
        let size = CGSize(width: nativeCanvasWidth, height: metrics.contentHeight)
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        UIView.performWithoutAnimation {
            canvas.bounds = CGRect(origin: .zero, size: size)
            canvas.center = CGPoint(x: bounds.midX, y: bounds.midY)
            canvas.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        nativeBase.frame = canvas.bounds
        let layout = KeyboardGeometry.layout(size: size, metrics: metrics, hand: .full, fitHeight: false)
        keyArea.frame = layout.keys; glass.frame = keyArea.bounds
        var faces: [CGRect] = []
        for (button, row, start, units) in keys {
            button.frame = CGRect(x: CGFloat(start) * layout.unitWidth, y: CGFloat(row) * layout.rowPitch,
                                  width: CGFloat(units) * layout.unitWidth, height: layout.rowPitch)
            faces.append(KeyboardGeometry.keyPlate(in: button.bounds, action: button.key.action, units: units).offsetBy(dx: button.frame.minX, dy: button.frame.minY))
        }
        glass.setFaces(faces)
        let font = UIFont.systemFont(ofSize: CGFloat(settings.resolvedCandidateTextSize.points))
        let firstFont = UIFont.systemFont(ofSize: CGFloat(settings.resolvedCandidateTextSize.points), weight: .medium)
        let firstWidth = CandidateButton.width(Candidate(text: "今天", consumed: 0), font: firstFont) + 4
        let secondWidth = CandidateButton.width(Candidate(text: "你好", consumed: 0), font: font) + 4
        first.frame = CGRect(x: layout.header.minX, y: 0, width: firstWidth, height: KeyboardGeometry.headerHeight)
        second.frame = CGRect(x: first.frame.maxX, y: 0, width: secondWidth, height: KeyboardGeometry.headerHeight)
        // Keep native text/symbol layers at the number of pixels they occupy
        // after the canvas transform, rather than scaling a captured keyboard.
        let displayScale = (window?.screen.scale ?? traitCollection.displayScale) * scale
        if renderedScale != displayScale {
            renderedScale = displayScale
            updateOwnedDisplayScale(canvas, scale: displayScale)
        }
    }
    private func updateOwnedDisplayScale(_ view: UIView, scale: CGFloat) {
        // UIKit manages a visual effect's internal render surfaces itself.
        guard !(view is UIVisualEffectView) else { return }
        view.contentScaleFactor = scale; view.layer.contentsScale = scale; view.setNeedsDisplay()
        for child in view.subviews { updateOwnedDisplayScale(child, scale: scale) }
    }
}
