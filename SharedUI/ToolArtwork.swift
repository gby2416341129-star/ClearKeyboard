import UIKit
import SwiftUI
import CoreImage

/// Final user-selected multicolor artwork. Both targets load the same resources;
/// no template tint, gray overlay, or appearance-dependent color replacement.
@MainActor enum ToolArtwork {
    private static var cache: [String: UIImage] = [:]
    private static var edgeCache: [String: UIImage] = [:]
    private static let edgeContext = CIContext(options: [.cacheIntermediates: false])
    static func softEdgeImage(symbol: String) -> UIImage? {
        if let cached = edgeCache[symbol] { return cached }
        let source = image(symbol: symbol, size: 32)
        guard let cg = source.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let radius = 1.7 * source.scale
        let extent = input.extent.insetBy(dx: -ceil(radius * 4), dy: -ceil(radius * 4))
        guard let filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input, kCIInputRadiusKey: radius]),
              let output = filter.outputImage, let blurred = edgeContext.createCGImage(output, from: extent) else { return nil }
        let result = UIImage(cgImage: blurred, scale: source.scale, orientation: .up).withRenderingMode(.alwaysOriginal)
        edgeCache[symbol] = result; return result
    }
    private static let opticalBounds: [String: CGRect] = [
        "add": CGRect(x: 8, y: 8, width: 176, height: 176),
        "appearance": CGRect(x: 17, y: 20, width: 162, height: 156),
        "back": CGRect(x: 35, y: 8, width: 122, height: 176),
        "check": CGRect(x: 0, y: 26, width: 192, height: 136),
        "clipboard": CGRect(x: 18, y: 7, width: 156, height: 176),
        "close": CGRect(x: 8, y: 8, width: 176, height: 176),
        "compatibility": CGRect(x: 8, y: 22, width: 176, height: 154),
        "copy": CGRect(x: 21, y: 8, width: 150, height: 176),
        "emoji": CGRect(x: 15, y: 15, width: 162, height: 162),
        "expand": CGRect(x: 8, y: 29, width: 176, height: 134),
        "fullsize": CGRect(x: 8, y: 8, width: 176, height: 176),
        "globe": CGRect(x: 8, y: 8, width: 176, height: 176),
        "haptic": CGRect(x: 8, y: 8, width: 176, height: 176),
        "height": CGRect(x: 1, y: 36, width: 191, height: 120),
        "home": CGRect(x: 15, y: 17, width: 162, height: 153),
        "input": CGRect(x: 0, y: 36, width: 192, height: 120),
        "keycolor": CGRect(x: 8, y: 8, width: 176, height: 176),
        "keyglass": CGRect(x: 8, y: 24, width: 176, height: 143),
        "language": CGRect(x: 10, y: 10, width: 173, height: 176),
        "leftright": CGRect(x: 9, y: 8, width: 173, height: 176),
        "license": CGRect(x: 24, y: 8, width: 143, height: 176),
        "more": CGRect(x: 0, y: 72, width: 192, height: 47),
        "onehand": CGRect(x: 0, y: 46, width: 190, height: 99),
        "open": CGRect(x: 2, y: 14, width: 176, height: 176),
        "phonetic": CGRect(x: 8, y: 30, width: 176, height: 137),
        "phrases": CGRect(x: 8, y: 23, width: 176, height: 152),
        "privacy": CGRect(x: 29, y: 3, width: 134, height: 176),
        "search": CGRect(x: 14, y: 14, width: 163, height: 164),
        "selection": CGRect(x: 8, y: 13, width: 176, height: 166),
        "settings": CGRect(x: 8, y: 16, width: 176, height: 160),
        "setup": CGRect(x: 1, y: 34, width: 191, height: 128),
        "textcolor": CGRect(x: 32, y: 10, width: 128, height: 176),
        "textsize": CGRect(x: 0, y: 28, width: 189, height: 130),
        "toolbar": CGRect(x: 15, y: 15, width: 162, height: 162),
        "trash": CGRect(x: 20, y: 7, width: 151, height: 176),
        "undo": CGRect(x: 8, y: 15, width: 176, height: 166),
    ]
    private static func asset(_ symbol: String) -> String? {
        switch symbol {
        case "character.bubble.fill": return "language"
        case "doc.on.clipboard.fill", "doc.on.clipboard": return "clipboard"
        case "face.smiling.fill": return "emoji"
        case "keyboard.fill": return "onehand"
        case "paintpalette.fill": return "appearance"
        case "rectangle.3.group.fill", "rectangle.3.group": return "toolbar"
        case "desktopcomputer": return "compatibility"
        case "key.glass": return "keyglass"
        case "key.color": return "keycolor"
        case "candidate.color": return "textcolor"
        case "candidate.size": return "textsize"
        case "slider.horizontal.3": return "settings"
        case "lock.shield": return "privacy"
        case "waveform": return "phonetic"
        case "doc.text": return "license"
        case "house": return "home"
        case "keyboard": return "input"
        case "haptic": return "haptic"
        case "setup": return "setup"
        case "doc.on.doc": return "copy"
        case "plus.bubble": return "phrases"
        case "selection.pin.in.out": return "selection"
        case "trash": return "trash"
        case "arrow.counterclockwise": return "undo"
        case "magnifyingglass": return "search"
        case "plus", "plus.circle": return "add"
        case "checkmark": return "check"
        case "xmark": return "close"
        case "chevron.up", "chevron.left": return "back"
        case "chevron.down": return "expand"
        case "ellipsis": return "more"
        case "arrow.up.left.and.arrow.down.right": return "fullsize"
        case "arrow.left", "arrow.right": return "leftright"
        case "arrow.up.and.down", "key.height": return "height"
        case "shift", "shift.fill", "capslock.fill": return "shift"
        case "delete.left": return "backspace"
        case "arrow.up.right": return "open"
        case "globe": return "globe"
        default: return nil
        }
    }
    static func tint(_ symbol: String) -> UIColor { .systemBlue }
    static func stencil(_ symbol: String, scale: CGFloat = 3) -> UIImage {
        image(symbol: symbol, size: 32, scale: scale).withRenderingMode(.alwaysTemplate)
    }
    static func brand(size: CGFloat = 28) -> UIImage {
        let key = "brand:\(size)"
        if let image = cache[key] { return image }
        guard let url = Bundle.main.url(forResource: "BrandMark", withExtension: "png"),
              let data = try? Data(contentsOf: url), let source = UIImage(data: data) else {
            return image(symbol: "water.waves", size: size)
        }
        let material = brandMaterial(source)
        let format = UIGraphicsImageRendererFormat(); format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size),format: format).image { _ in
            material.draw(in: CGRect(x: 0,y: 0,width: size,height: size))
        }.withRenderingMode(.alwaysOriginal)
        cache[key] = image; return image
    }
    private static func brandMaterial(_ source: UIImage) -> UIImage {
        if let value = cache["brand.material"] { return value }
        guard let bitmap = source.cgImage else { return source }
        guard let image = BrandMaterial.image(bitmap) else { return source }
        let result = UIImage(cgImage: image,scale: source.scale,orientation: .up)
        cache["brand.material"] = result; return result
    }

    static func image(symbol: String, size: CGFloat = 28, scale: CGFloat? = nil, style: UIUserInterfaceStyle? = nil) -> UIImage {
        let scale = scale ?? UIScreen.main.scale
        let key = "selected:\(symbol):\(size):\(scale)"
        if let value = cache[key] { return value }
        let original: UIImage?
        if let name = asset(symbol), let url = Bundle.main.url(forResource: "icon-" + name, withExtension: "png", subdirectory: "ToolIcons") {
            original = UIImage(contentsOfFile: url.path)
        } else {
            original = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.8, weight: .regular))
        }
        // Keep the high-resolution texture. Baking a 32pt image here and then
        // fitting it into 24/28pt views caused an avoidable second downsample.
        let value: UIImage
        if let bitmap = original?.cgImage {
            let crop = asset(symbol).flatMap { opticalBounds[$0] }.flatMap { bitmap.cropping(to: $0) } ?? bitmap
            value = UIImage(cgImage: crop, scale: CGFloat(max(crop.width, crop.height)) / max(1, size), orientation: .up).withRenderingMode(.alwaysOriginal)
        } else {
            value = (original ?? UIImage()).withRenderingMode(.alwaysOriginal)
        }
        cache[key] = value; return value
    }
    static func shift(active _: Bool, capsLocked: Bool, ink _: UIColor) -> UIImage {
        let key = "shift.delete-matched-palette"
        let source: UIImage
        if let cached = cache[key] { source = cached }
        else {
            let original = image(symbol: "shift", size: 28)
            let format = UIGraphicsImageRendererFormat(); format.opaque = false
            source = UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28), format: format).image { renderer in
                let rect = CGRect(x: (28 - original.size.width) / 2, y: (28 - original.size.height) / 2,
                                  width: original.size.width, height: original.size.height)
                original.draw(in: rect)
                renderer.cgContext.setBlendMode(.sourceIn)
                UIColor(red: 49.0/255, green: 139.0/255, blue: 247.0/255, alpha: 1).setFill()
                renderer.cgContext.fill(CGRect(x: 0, y: 0, width: 28, height: 28))
                renderer.cgContext.setBlendMode(.sourceAtop)
                UIColor(red: 105.0/255, green: 204.0/255, blue: 247.0/255, alpha: 1).setFill()
                let facet = UIBezierPath(); facet.move(to: .zero)
                facet.addLine(to: CGPoint(x: 28, y: 0)); facet.addLine(to: CGPoint(x: 28, y: 12))
                facet.addLine(to: CGPoint(x: 0, y: 22)); facet.close(); facet.fill()
            }.withRenderingMode(.alwaysOriginal)
            cache[key] = source
        }
        guard capsLocked else { return source }
        let format = UIGraphicsImageRendererFormat(); format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28), format: format).image { _ in
            source.draw(in: CGRect(x: 1.4, y: 0, width: 25.2, height: 25.2))
            UIColor(red: 105.0/255, green: 204.0/255, blue: 247.0/255, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 8.75, y: 24, width: 10.5, height: 1.8), cornerRadius: 0.9).fill()
        }.withRenderingMode(.alwaysOriginal)
    }

}

@MainActor final class ToolIconView: UIView {
    private let ink = UIImageView()
    private let edgeInk = UIImageView()
    private let compatibilityCheck = CAShapeLayer()
    private var compatibilityEnabled = false
    private var symbol = ""
    init(symbol: String) {
        super.init(frame: .zero)
        isOpaque = false; backgroundColor = .clear
        isUserInteractionEnabled = false; isAccessibilityElement = false
        ink.contentMode = .scaleAspectFit; edgeInk.contentMode = .scaleAspectFit
        ink.backgroundColor = .clear; edgeInk.backgroundColor = .clear
        edgeInk.layer.opacity = 0; addSubview(edgeInk); addSubview(ink); setSymbol(symbol)
        compatibilityCheck.fillColor = UIColor.clear.cgColor
        compatibilityCheck.strokeColor = UIColor.systemGreen.cgColor
        compatibilityCheck.lineWidth = 2.3
        compatibilityCheck.lineCap = .round; compatibilityCheck.lineJoin = .round
        compatibilityCheck.opacity = 0; ink.layer.addSublayer(compatibilityCheck)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func setSymbol(_ value: String) {
        guard symbol != value else { return }; symbol = value
        ink.image = ToolArtwork.image(symbol: value, size: 32)
        edgeInk.image = ToolArtwork.softEdgeImage(symbol: value)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let wide = symbol == "keyboard.fill" || symbol == "key.height"
        let side = min(34, bounds.width + (wide ? 4 : 0))
        ink.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        if let original = ink.image, let blurred = edgeInk.image {
            let scale = min(ink.bounds.width / original.size.width, ink.bounds.height / original.size.height)
            edgeInk.bounds = CGRect(origin: .zero, size: CGSize(width: blurred.size.width * scale, height: blurred.size.height * scale))
            edgeInk.center = ink.center
        } else { edgeInk.frame = ink.frame }
        let path = UIBezierPath()
        path.move(to: CGPoint(x: side * 0.35, y: side * 0.36))
        path.addLine(to: CGPoint(x: side * 0.46, y: side * 0.47))
        path.addLine(to: CGPoint(x: side * 0.67, y: side * 0.25))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        compatibilityCheck.frame = ink.bounds; compatibilityCheck.path = path.cgPath
        CATransaction.commit()
    }
    func softenEdge(_ amount: CGFloat) {
        let blend = Float(min(1, max(0, amount)))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ink.layer.opacity = 1 - blend; edgeInk.layer.opacity = blend
        CATransaction.commit()
    }
    func setCompatibilityEnabled(_ enabled: Bool) {
        guard symbol == "desktopcomputer", compatibilityEnabled != enabled else { return }
        compatibilityEnabled = enabled
        accessibilityValue = enabled ? "已开启" : "已关闭"
        let oldOpacity = compatibilityCheck.presentation()?.opacity ?? compatibilityCheck.opacity
        compatibilityCheck.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        compatibilityCheck.opacity = enabled ? 1 : 0
        CATransaction.commit()
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = oldOpacity; fade.toValue = enabled ? 1 : 0; fade.duration = 0.18
        compatibilityCheck.add(fade, forKey: "compatibility.fade")
        if enabled {
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0; draw.toValue = 1; draw.duration = 0.24
            draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
            compatibilityCheck.add(draw, forKey: "compatibility.check")
        }
    }
}

struct ToolIcon: UIViewRepresentable {
    let symbol: String
    func makeUIView(context: Context) -> ToolIconView { ToolIconView(symbol: symbol) }
    func updateUIView(_ view: ToolIconView, context: Context) { view.setSymbol(symbol) }
}

@MainActor final class ToolbarScrollView: UIScrollView {
    static let itemPitch: CGFloat = 44
    var pendingOffset: CGFloat? { didSet { if pendingOffset != nil { setNeedsLayout() } } }
    var expectedContentWidth: CGFloat = 0 { didSet { if expectedContentWidth != oldValue { setNeedsLayout() } } }
    var edgeIcons: [ToolIconView] = []
    private let edgeMask = CAGradientLayer()
    private let verticalMask = CAGradientLayer()
    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(contentSize.width - expectedContentWidth) > 0.5 || contentSize.height != bounds.height {
            contentSize = CGSize(width: expectedContentWidth, height: bounds.height)
        }
        if let saved = pendingOffset, bounds.width > 0, expectedContentWidth > 0, !isTracking, !isDecelerating {
            pendingOffset = nil
            setContentOffset(CGPoint(x: clampedOffset(saved), y: 0), animated: false)
        }
        updateEdges()
    }
    func clampedOffset(_ proposed: CGFloat) -> CGFloat {
        min(max(0, proposed), max(0, expectedContentWidth - bounds.width))
    }
    func refreshEdgeAppearance() { updateEdges() }
    private func updateEdges() {
        let overflow = max(0, expectedContentWidth - bounds.width)
        let left = contentOffset.x > 0.5, right = contentOffset.x < overflow - 0.5 || contentOffset.x < -0.5
        let fade = min(26, bounds.width / 3)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if bounds.width > 0 {
            if layer.mask !== edgeMask { layer.mask = edgeMask }
            edgeMask.frame = bounds
            verticalMask.frame = edgeMask.bounds
            verticalMask.startPoint = CGPoint(x: 0.5, y: 0); verticalMask.endPoint = CGPoint(x: 0.5, y: 1)
            let margin = min(0.15, 3 / max(1, bounds.height))
            verticalMask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
            verticalMask.locations = [0, NSNumber(value: Double(margin)), NSNumber(value: Double(1 - margin)), 1]
            edgeMask.mask = verticalMask
            edgeMask.startPoint = CGPoint(x: 0, y: 0.5); edgeMask.endPoint = CGPoint(x: 1, y: 0.5)
            edgeMask.colors = [UIColor.black.withAlphaComponent(left ? 0 : 1).cgColor, UIColor.black.cgColor,
                               UIColor.black.cgColor, UIColor.black.withAlphaComponent(right ? 0 : 1).cgColor]
            edgeMask.locations = [0, NSNumber(value: Double(fade / bounds.width)),
                                  NSNumber(value: Double(1 - fade / bounds.width)), 1]
        } else { layer.mask = nil }
        CATransaction.commit()
        for icon in edgeIcons {
            let rect: CGRect
            if let visible = icon.layer.presentation(), let viewport = layer.presentation() {
                rect = visible.convert(visible.bounds, to: viewport)
            } else { rect = icon.convert(icon.bounds, to: self) }
            let distance = min(left ? rect.midX - bounds.minX : fade, right ? bounds.maxX - rect.midX : fade)
            icon.softenEdge(1 - min(fade, max(0, distance)) / max(1, fade))
        }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point), !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
        return super.hitTest(point, with: event) ?? self
    }
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

@MainActor class FeedbackButton: UIButton {
    private var feedbackAnimator: UIViewPropertyAnimator?
    private var feedbackContent: UIView {
        subviews.first(where: { $0 is ToolIconView }) ?? imageView ?? self
    }
    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            animateFeedback(pressed: isHighlighted)
        }
    }
    private func animateFeedback(pressed: Bool) {
        let content = feedbackContent
        if let feedbackAnimator, feedbackAnimator.state == .active {
            feedbackAnimator.stopAnimation(false); feedbackAnimator.finishAnimation(at: .current)
        }
        let motion = UIViewPropertyAnimator(duration: pressed ? 0.07 : 0.16, curve: .easeOut) {
            content.transform = pressed && !UIAccessibility.isReduceMotionEnabled
                ? CGAffineTransform(scaleX: 0.95, y: 0.95) : .identity
            content.alpha = pressed ? 0.88 : 1
        }
        feedbackAnimator = motion; motion.startAnimation()
    }
    func playActivationFeedback() {
        if feedbackAnimator?.isRunning != true && !UIAccessibility.isReduceMotionEnabled {
            feedbackContent.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }
        animateFeedback(pressed: false)
    }
    func setEditingMotion(_ enabled: Bool) {
        let target = subviews.first(where: { $0 is ToolIconView })?.layer ?? imageView?.layer ?? layer
        guard enabled, !UIAccessibility.isReduceMotionEnabled else { target.removeAnimation(forKey: "toolbar.edit"); return }
        guard target.animation(forKey: "toolbar.edit") == nil else { return }
        let motion = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        motion.values = [-0.025, 0.025, -0.025]; motion.duration = 0.46
        motion.repeatCount = .infinity; motion.isAdditive = true
        motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        target.add(motion, forKey: "toolbar.edit")
    }
}

@MainActor final class ToolTileButton: FeedbackButton {
    private let lens = LiquidGlassView(radius: 16, keycap: true, clear: true)
    private let pressWash = UIView()
    private let artwork: ToolIconView
    private let caption = UILabel()
    private let badge = UILabel()
    init(title: String, symbol: String, action: @escaping () -> Void) {
        artwork = ToolIconView(symbol: symbol)
        super.init(frame: .zero)
        addSubview(lens); addSubview(pressWash); addSubview(artwork); addSubview(caption)
        pressWash.isUserInteractionEnabled = false; pressWash.alpha = 0
        pressWash.backgroundColor = UIColor.label.withAlphaComponent(0.10)
        pressWash.layer.cornerRadius = 16; pressWash.layer.cornerCurve = .continuous
        caption.text = title; caption.textColor = .label; caption.font = .systemFont(ofSize: 12,weight: .medium)
        caption.textAlignment = .center; caption.adjustsFontSizeToFitWidth = true; caption.minimumScaleFactor = 0.9
        for view in [artwork,caption] { view.isUserInteractionEnabled = false }
        isAccessibilityElement = true; accessibilityLabel = title
        addAction(UIAction { [weak self] _ in
            self?.playActivationFeedback()
            self?.pressWash.alpha = 1
            UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self?.pressWash.alpha = 0 }
            action()
        }, for: .touchUpInside)
        badge.textAlignment = .center; badge.font = .systemFont(ofSize: 13, weight: .semibold)
        badge.textColor = .label; badge.backgroundColor = .tertiarySystemFill
        badge.layer.cornerRadius = 8; badge.clipsToBounds = true; badge.isHidden = true
        badge.isUserInteractionEnabled = false; addSubview(badge)
        lens.configure(tint: nil,strength: 0.25,fallback: .secondarySystemBackground)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        lens.frame = bounds; pressWash.frame = bounds
        artwork.frame = CGRect(x: bounds.midX-14,y: 7,width: 28,height: 28)
        caption.frame = CGRect(x: 5,y: 40,width: max(0,bounds.width-10),height: 16)
        badge.frame = CGRect(x: bounds.midX + 7, y: 4, width: 16, height: 16)
    }
    func configureManagement(title: String, pinned: Bool) {
        caption.text = title; badge.isHidden = false
        let text = pinned ? "−" : "+"
        if badge.text != text {
            UIView.transition(with: badge, duration: 0.16, options: [.transitionCrossDissolve, .allowUserInteraction]) { self.badge.text = text }
        }
        accessibilityLabel = (pinned ? "移除" : "添加") + title
    }
    func updateCaption(_ title: String) { caption.text = title; accessibilityLabel = title }
    override var isHighlighted: Bool {
        didSet {
            lens.alpha = isHighlighted ? 0.72 : 1
            UIView.animate(withDuration: isHighlighted ? 0.06 : 0.18, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) { self.pressWash.alpha = self.isHighlighted ? 1 : 0 }
        }
    }
}
