import UIKit

/// Production views are laid out once at the real keyboard's logical size, then
/// the whole canvas is scaled uniformly. The preview never compresses row pitch
/// independently of the text, symbols, insets or key faces.
final class KeyboardAppearancePreview: UIView {
    private let canvas = UIView()
    private let keyArea = UIView()
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
        canvas.backgroundColor = .secondarySystemBackground
        canvas.addSubview(first); canvas.addSubview(second); canvas.addSubview(keyArea)
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
        settings = value
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
        let layout = KeyboardGeometry.layout(size: size, metrics: metrics, hand: .full, fitHeight: false)
        keyArea.frame = layout.keys
        for (button, row, start, units) in keys {
            button.frame = CGRect(x: CGFloat(start) * layout.unitWidth, y: CGFloat(row) * layout.rowPitch,
                                  width: CGFloat(units) * layout.unitWidth, height: layout.rowPitch)
        }
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
        guard !(view is UIVisualEffectView), !(view is UIImageView) else { return }
        view.contentScaleFactor = scale; view.layer.contentsScale = scale; view.setNeedsDisplay()
        for child in view.subviews { updateOwnedDisplayScale(child, scale: scale) }
    }
}
