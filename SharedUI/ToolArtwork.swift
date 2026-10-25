import UIKit
import SwiftUI

/// Final user-selected multicolor artwork. Both targets load the same resources;
/// no template tint, gray overlay, or appearance-dependent color replacement.
@MainActor enum ToolArtwork {
    private static var cache: [String: UIImage] = [:]
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
        let source = image(symbol: "shift", size: 28)
        // Keep the same blue facets as Delete. The key face indicates a single
        // capital; Caps Lock adds its own bar without cropping or tinting ink.
        guard capsLocked else { return source }
        let format = UIGraphicsImageRendererFormat(); format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28), format: format).image { renderer in
            source.draw(in: CGRect(x: 1.4, y: 0, width: 25.2, height: 25.2))
            UIColor(red: 105.0/255, green: 204.0/255, blue: 247.0/255, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 8.75, y: 24, width: 10.5, height: 1.8), cornerRadius: 0.9).fill()
        }.withRenderingMode(.alwaysOriginal)
    }
}

@MainActor final class ToolIconView: UIView {
    private let ink = UIImageView()
    private let compatibilityCheck = CAShapeLayer()
    private var compatibilityEnabled = false
    private var symbol = ""
    init(symbol: String) {
        super.init(frame: .zero)
        isOpaque = false; backgroundColor = .clear
        isUserInteractionEnabled = false; isAccessibilityElement = false
        ink.contentMode = .scaleAspectFit; addSubview(ink); setSymbol(symbol)
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
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let wide = symbol == "keyboard.fill" || symbol == "key.height"
        let side = min(34, bounds.width + (wide ? 4 : 0))
        ink.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: side * 0.35, y: side * 0.36))
        path.addLine(to: CGPoint(x: side * 0.46, y: side * 0.47))
        path.addLine(to: CGPoint(x: side * 0.67, y: side * 0.25))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        compatibilityCheck.frame = ink.bounds; compatibilityCheck.path = path.cgPath
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
    var pendingOffset: CGFloat?
    var expectedContentWidth: CGFloat = 0
    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(contentSize.width - expectedContentWidth) > 0.5 {
            contentSize = CGSize(width: expectedContentWidth, height: bounds.height)
        }
        if let saved = pendingOffset, bounds.width > 0, expectedContentWidth > 0 {
            pendingOffset = nil
            setContentOffset(CGPoint(x: alignedOffset(saved), y: 0), animated: false)
        }
    }
    func alignedOffset(_ proposed: CGFloat) -> CGFloat {
        min(max(0, (proposed / Self.itemPitch).rounded() * Self.itemPitch), max(0, expectedContentWidth - bounds.width))
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
        let motion = UIViewPropertyAnimator(duration: pressed ? 0.09 : 0.28, dampingRatio: 0.86) {
            content.transform = pressed && !UIAccessibility.isReduceMotionEnabled
                ? CGAffineTransform(scaleX: 0.90, y: 0.90) : .identity
            content.alpha = pressed ? 0.82 : 1
        }
        feedbackAnimator = motion; motion.startAnimation()
    }
    func playActivationFeedback() {
        if feedbackAnimator?.isRunning != true && !UIAccessibility.isReduceMotionEnabled {
            feedbackContent.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
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
    private let artwork: ToolIconView
    private let caption = UILabel()
    private let badge = UILabel()
    init(title: String, symbol: String, action: @escaping () -> Void) {
        artwork = ToolIconView(symbol: symbol)
        super.init(frame: .zero)
        addSubview(lens); addSubview(artwork); addSubview(caption)
        caption.text = title; caption.textColor = .label; caption.font = .systemFont(ofSize: 12,weight: .medium)
        caption.textAlignment = .center; caption.adjustsFontSizeToFitWidth = true; caption.minimumScaleFactor = 0.9
        for view in [artwork,caption] { view.isUserInteractionEnabled = false }
        isAccessibilityElement = true; accessibilityLabel = title
        addAction(UIAction { _ in action() }, for: .touchUpInside)
        badge.textAlignment = .center; badge.font = .systemFont(ofSize: 13, weight: .semibold)
        badge.textColor = .label; badge.backgroundColor = .tertiarySystemFill
        badge.layer.cornerRadius = 8; badge.clipsToBounds = true; badge.isHidden = true
        badge.isUserInteractionEnabled = false; addSubview(badge)
        lens.configure(tint: nil,strength: 0.25,fallback: .secondarySystemBackground)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        lens.frame = bounds
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
        didSet { lens.alpha = isHighlighted ? 0.72 : 1 }
    }
}
