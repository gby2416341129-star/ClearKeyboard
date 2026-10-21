import UIKit

final class GlassBackdrop: UIView {
    private let material = UIVisualEffectView()
    private let wash = UIView()
    private var effectSignature = ""
    private let materialMask = UIView()
    private let materialGradient = CAGradientLayer()
    private let washGradient = CAGradientLayer()
    private var strength: CGFloat = -1
    private var maskSize = CGSize.zero
    private var systemBacked = false
    private var masksNeedUpdate = true
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(material); addSubview(wash)
        materialMask.layer.addSublayer(materialGradient)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews(); material.frame = bounds; wash.frame = bounds
        updateMasks()
    }
    private func updateMasks() {
        guard masksNeedUpdate || materialMask.alpha != strength || maskSize != material.bounds.size || material.mask == nil else { return }
        masksNeedUpdate = false
        maskSize = material.bounds.size
        UIView.performWithoutAnimation {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            materialMask.frame = material.bounds
            materialMask.alpha = min(1, max(0, strength))
            if systemBacked {
                // Our primary view sits inside a system-owned keyboard shell.
                // Blend only inside our bounds so its top cap and globe region
                // meet transparent edges rather than a second flat color rim.
                // These are optical ramps, not extra host insets or key padding.
                let height = max(1, material.bounds.height)
                let clearEdge = min(3, height * 0.1)
                let topRamp = min(32, height * 0.45)
                let bottomRamp = min(24, height * 0.45)
                let locations = [CGFloat(0), clearEdge / height, topRamp / height,
                                 1 - bottomRamp / height, 1 - clearEdge / height, 1]
                    .map { NSNumber(value: Double($0)) }
                let clear = UIColor.clear.cgColor, opaque = UIColor.black.cgColor
                let colors = [clear, clear, opaque, opaque, clear, clear]
                materialMask.backgroundColor = .clear; materialGradient.isHidden = false
                for gradient in [materialGradient, washGradient] {
                    gradient.frame = material.bounds
                    gradient.startPoint = CGPoint(x: 0.5, y: 0)
                    gradient.endPoint = CGPoint(x: 0.5, y: 1)
                    gradient.colors = colors; gradient.locations = locations
                }
                wash.layer.mask = washGradient
            } else {
                // Standalone previews or embedded surfaces retain their full
                // original material; only system-backed edges need this blend.
                materialMask.backgroundColor = .black; materialGradient.isHidden = true
                wash.layer.mask = nil
            }
            // UIVisualEffectView copies its mask. Reassign it after a size or
            // strength change. Keep this mask on the effect itself; a mask on
            // its parent would not reliably mask UIKit's backdrop sampling.
            material.mask = nil; material.mask = materialMask
            CATransaction.commit()
        }
    }
    func apply(_ settings: KeyboardSettings, systemBacked: Bool = false) {
        let reduced = UIAccessibility.isReduceTransparencyEnabled || ProcessInfo.processInfo.isLowPowerModeEnabled || settings.glass == .solid
        self.systemBacked = systemBacked
        // All visible fill, including the opaque accessibility fallback, lives
        // in wash. An unmasked root color would reveal the same rectangular seam.
        isOpaque = false; backgroundColor = .clear
        let signature = "\(settings.glass)-\(reduced)-\(systemBacked)"
        if signature != effectSignature {
            effectSignature = signature; masksNeedUpdate = true
            let target: UIVisualEffect? = reduced ? nil : UIBlurEffect(style:
                settings.glass == .clear ? .systemUltraThinMaterial : .systemMaterial)
            // Use the same maskable material in the preview and the keyboard.
            // On iOS 26, UIGlassEffect ignores the intensity mask here and draws
            // its own rim. UIInputView already supplies the outer native glass.
            UIView.performWithoutAnimation { material.effect = target }
        }
        // Modulate the effect's own mask, keeping the effect view opaque and
        // avoiding an indefinitely paused animator that prevents UI quiescence.
        strength = CGFloat(settings.resolvedBackgroundGlassStrength)
        wash.backgroundColor = reduced ? (settings.backgroundTintColor ?? .secondarySystemBackground)
            : settings.backgroundTintColor?.withAlphaComponent(settings.backgroundTintOpacity)
        updateMasks()
    }
}

final class KeyButton: UIButton {
    let key: KeyboardKey
    private let plate = UIView()
    private let pressWash = UIView()
    private let caption = CenteredKeyLabel()
    private let icon = UIImageView()
    private var repeatTimer: Timer?
    private var repeatStart: DispatchWorkItem?
    private var didRepeat = false
    private var draggingCursor = false
    private var suppressTap = false
    private var cursorMode = false
    private var cursorOrigin = CGPoint.zero
    private var pendingCursor: CGPoint?
    private var cursorDisplayLink: CADisplayLink?
    private var deletionDirection = 0
    var onAction: ((KeyAction) -> Void)?
    var onPrepare: ((KeyAction) -> Void)?
    var onInteractionChanged: ((Bool) -> Void)?
    var onCursor: ((CGPoint) -> Void)?
    var onCursorBegan: (() -> Void)?
    var onCursorEnded: (() -> Void)?
    var onDeleteSwipe: ((Bool) -> Void)?
    var onDeleteHint: ((Int?) -> Void)?
    var accent = UIColor.systemTeal
    var haptics = false
    private var feedback: UIImpactFeedbackGenerator?
    private var interactionActive = false
    private var shiftSymbol = ""
    private var shadowSize = CGSize.zero

    init(key: KeyboardKey) {
        self.key = key; super.init(frame: .zero)
        // Keep the entire non-overlapping key cell eligible for remote-host
        // touch delivery, including its transparent margins and rounded corners.
        backgroundColor = UIColor(white: 0.5, alpha: 0.01); isOpaque = false
        addSubview(plate); plate.isUserInteractionEnabled = false; plate.layer.cornerRadius = 8
        plate.accessibilityIdentifier = "key.face"
        plate.layer.cornerCurve = .continuous
        plate.layer.borderWidth = 0.5
        plate.addSubview(pressWash); pressWash.isUserInteractionEnabled = false
        pressWash.alpha = 0
        pressWash.layer.cornerRadius = 8; pressWash.layer.cornerCurve = .continuous
        plate.addSubview(caption); caption.isUserInteractionEnabled = false; caption.contentMode = .redraw
        plate.addSubview(icon); icon.isUserInteractionEnabled = false; icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 21, weight: .regular)
        caption.textAlignment = .center; caption.text = key.label
        caption.font = .systemFont(ofSize: key.label.count == 1 ? 23 : 16)
        switch key.action {
        case .shift: icon.image = UIImage(systemName: "shift")
        case .delete: icon.image = UIImage(systemName: "delete.left")
        case .globe: icon.image = UIImage(systemName: "globe")
        default: break
        }
        caption.isHidden = icon.image != nil
        isAccessibilityElement = true; accessibilityTraits = .keyboardKey
        accessibilityLabel = key.label
        switch key.action {
        case .text(let value): accessibilityIdentifier = "key.text." + value.lowercased()
        default: accessibilityIdentifier = "key." + key.label
        }
        switch key.action {
        case .shift: accessibilityLabel = "切换大小写"
        case .delete: accessibilityLabel = "删除"
        case .space: accessibilityLabel = "空格，按住并拖动以移动光标"
        case .enter: accessibilityLabel = "回车"
        case .globe: accessibilityLabel = "下一个键盘，按住选择键盘"
        case .language: accessibilityLabel = "切换中文和英文"
        default: break
        }
        addTarget(self, action: #selector(down), for: .touchDown)
        addTarget(self, action: #selector(up), for: .touchUpInside)
        addTarget(self, action: #selector(cancelPress), for: [.touchUpOutside, .touchCancel, .touchDragExit])
        if key.action == .space {
            let cursor = UILongPressGestureRecognizer(target: self, action: #selector(cursorGesture(_:)))
            cursor.minimumPressDuration = 0.35; cursor.allowableMovement = 14; addGestureRecognizer(cursor)
        }
        if key.action == .delete {
            let swipe = UIPanGestureRecognizer(target: self, action: #selector(deletionGesture(_:)))
            swipe.maximumNumberOfTouches = 1; addGestureRecognizer(swipe)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Once this key owns a finger, tolerate the small release drift of fast
        // taps. Initial hit testing still uses the original, non-overlapping cells.
        if isTracking, case .text = key.action { return bounds.insetBy(dx: -7, dy: -10).contains(point) }
        return super.point(inside: point, with: event)
    }
    func updateShift(active: Bool, capsLocked: Bool) {
        guard key.action == .shift else { return }
        let symbol = capsLocked ? "capslock.fill" : active ? "shift.fill" : "shift"
        guard shiftSymbol != symbol else { return }
        shiftSymbol = symbol; icon.image = UIImage(systemName: symbol)
        accessibilityValue = capsLocked ? "大写锁定" : active ? "大写" : "小写"
    }
    override func layoutSubviews() {
        super.layoutSubviews(); plate.frame = KeyboardGeometry.keyPlate(in: bounds, action: key.action, units: key.units)
        let base: CGFloat = key.action == .language ? 14 : key.label.count == 1 ? 23 : 16
        let fontSize = min(base, max(10, min(plate.bounds.width * 0.88, plate.bounds.height * 0.65)))
        if abs(caption.font.pointSize - fontSize) > 0.1 { caption.font = .systemFont(ofSize: fontSize) }
        caption.frame = plate.bounds; icon.frame = plate.bounds; pressWash.frame = plate.bounds
        if shadowSize != plate.bounds.size {
            shadowSize = plate.bounds.size
            plate.layer.shadowPath = plate.bounds.isEmpty ? nil : UIBezierPath(roundedRect: plate.bounds, cornerRadius: 8).cgPath
        }
    }
    func apply(_ settings: KeyboardSettings, title: String? = nil, active: Bool = false, capsLocked: Bool = false) {
        accent = settings.accentColor; haptics = settings.haptics
        let dark = traitCollection.userInterfaceStyle == .dark
        let utility = key.action == .shift || key.action == .delete || (key.units == 1.5 && key.label.count > 1)
        let reduced = settings.glass == .solid || UIAccessibility.isReduceTransparencyEnabled || ProcessInfo.processInfo.isLowPowerModeEnabled
        // A continuous system glass sheet supplies the backdrop. Key faces transmit
        // that material instead of stacking 30 separate refracting lenses on top.
        if reduced {
            plate.backgroundColor = settings.keyTintColor ?? UIColor(white: dark ? (utility ? 0.19 : 0.30) : (utility ? 0.82 : 0.97), alpha: 1)
            plate.layer.borderWidth = 0
        } else {
            let alpha = settings.keyFaceOpacity(dark: dark, utility: utility)
            plate.backgroundColor = (settings.keyTintColor ?? .white).withAlphaComponent(alpha)
            plate.layer.borderWidth = 0.5
        }
        plate.layer.borderColor = UIColor.white.withAlphaComponent(dark ? 0.18 : 0.65).cgColor
        plate.layer.shadowColor = UIColor.black.cgColor; plate.layer.shadowOpacity = reduced ? 0 : 0.10
        plate.layer.shadowRadius = 0.5; plate.layer.shadowOffset = CGSize(width: 0, height: 0.5)
        pressWash.backgroundColor = active ? UIColor.label.withAlphaComponent(0.10) : .clear
        let ink = settings.keyInkColor(utility: utility)
        caption.textColor = ink
        icon.tintColor = ink
        updateShift(active: active, capsLocked: capsLocked)
        if let title { updateTitle(title) }
    }
    func updateTitle(_ title: String) {
        if caption.text != title { caption.text = title; accessibilityLabel = title }
    }
    func setCursorMode(_ active: Bool) {
        cursorMode = active
        if key.action != .space { isUserInteractionEnabled = !active }
        caption.isHidden = active || icon.image != nil; icon.isHidden = active
        plate.alpha = active ? 0.1 : 1
    }
    @objc private func down() {
        if !interactionActive { interactionActive = true; onInteractionChanged?(true) }
        didRepeat = false; suppressTap = false
        pressWash.layer.removeAnimation(forKey: "keyRelease"); pressWash.alpha = 1
        pressWash.backgroundColor = UIColor.label.withAlphaComponent(0.10)
        onPrepare?(key.action)
        if haptics { if feedback == nil { feedback = UIImpactFeedbackGenerator(style: .light) }; feedback?.impactOccurred(intensity: 0.35) }
        guard key.action == .delete else { return }
        let start = DispatchWorkItem { [weak self] in
            guard let self, self.isHighlighted else { return }
            self.didRepeat = true; self.onAction?(.delete)
            let timer = Timer(timeInterval: 0.065, repeats: true) { [weak self] _ in self?.onAction?(.delete) }
            self.repeatTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        repeatStart = start; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: start)
    }
    @objc private func up() {
        let shouldFire = !didRepeat && !suppressTap && !draggingCursor
        // Keep the contact active through the write and its synchronous host
        // notifications. Releasing first scheduled idle reads that the very
        // same key immediately cancelled and re-created.
        if shouldFire { onAction?(key.action) }
        cancelPress()
    }
    @objc func cancelPress() {
        repeatStart?.cancel(); repeatTimer?.invalidate(); repeatTimer = nil
        let opacity = pressWash.layer.presentation()?.opacity ?? Float(pressWash.alpha)
        pressWash.alpha = 0; plate.alpha = cursorMode ? 0.1 : 1
        pressWash.layer.removeAnimation(forKey: "keyRelease")
        if opacity > 0, !UIAccessibility.isReduceMotionEnabled {
            let release = CABasicAnimation(keyPath: "opacity")
            let maximum = Float(window?.screen.maximumFramesPerSecond ?? 60)
            release.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
            release.fromValue = opacity; release.toValue = 0; release.duration = 0.06
            release.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pressWash.layer.add(release, forKey: "keyRelease")
        }
        if interactionActive { interactionActive = false; onInteractionChanged?(false) }
    }
    @objc private func cursorGesture(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: window)
        switch gesture.state {
        case .began:
            draggingCursor = true; suppressTap = true; cursorOrigin = point; pendingCursor = nil
            onCursorBegan?()
            let link = CADisplayLink(target: self, selector: #selector(flushCursor))
            let rate = Float(window?.screen.maximumFramesPerSecond ?? 60)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
            link.add(to: .main, forMode: .common); cursorDisplayLink = link
            if haptics { feedback?.impactOccurred(intensity: 0.5) }
        case .changed:
            pendingCursor = CGPoint(x: point.x - cursorOrigin.x, y: point.y - cursorOrigin.y)
        default:
            if gesture.state == .ended { flushCursor() }
            cursorDisplayLink?.invalidate(); cursorDisplayLink = nil; pendingCursor = nil
            if draggingCursor { draggingCursor = false; onCursorEnded?() }
            cancelPress()
        }
    }
    @objc private func flushCursor() {
        guard let translation = pendingCursor else { return }
        pendingCursor = nil; onCursor?(translation)
    }
    @objc private func deletionGesture(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            suppressTap = true; repeatStart?.cancel(); repeatTimer?.invalidate(); repeatTimer = nil
            let y = gesture.translation(in: window).y
            deletionDirection = y < -24 ? 1 : y > 24 ? -1 : 0
            onDeleteHint?(deletionDirection)
        case .ended:
            if deletionDirection != 0 { onDeleteSwipe?(deletionDirection == 1) }
            onDeleteHint?(nil); deletionDirection = 0; cancelPress()
        default: onDeleteHint?(nil); deletionDirection = 0; cancelPress()
        }
    }
    func stopTracking() {
        suppressTap = true
        cursorDisplayLink?.invalidate(); cursorDisplayLink = nil; pendingCursor = nil
        onDeleteHint?(nil)
        if draggingCursor { draggingCursor = false; onCursorEnded?() }
        cancelPress()
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { stopTracking() } }
    deinit { repeatTimer?.invalidate(); repeatStart?.cancel(); cursorDisplayLink?.invalidate() }
}
