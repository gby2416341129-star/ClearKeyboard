import UIKit

final class GlassBackdrop: UIView {
    private let gradient = CAGradientLayer()
    private let material = UIVisualEffectView()
    private let wash = UIView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(gradient); addSubview(material); addSubview(wash)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() { super.layoutSubviews(); gradient.frame = bounds; material.frame = bounds; wash.frame = bounds }
    func apply(_ settings: KeyboardSettings, systemBacked: Bool = false) {
        let reduced = UIAccessibility.isReduceTransparencyEnabled || ProcessInfo.processInfo.isLowPowerModeEnabled || settings.glass == .solid
        isOpaque = false; backgroundColor = reduced ? .secondarySystemBackground : .clear
        gradient.isHidden = true
        if reduced || systemBacked { material.effect = nil }
        else if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: settings.glass == .clear ? .clear : .regular)
            glass.isInteractive = false; material.effect = glass
            material.cornerConfiguration = .corners(radius: .fixed(28))
        } else { material.effect = UIBlurEffect(style: settings.glass == .clear ? .systemUltraThinMaterial : .systemMaterial) }
        wash.backgroundColor = reduced ? .clear : settings.accentColor.withAlphaComponent(settings.glassOpacity * (systemBacked ? 0.025 : 0.06))
    }
}

final class KeyButton: UIButton {
    let key: KeyboardKey
    private let plate = UIVisualEffectView()
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
    var onCursor: ((CGPoint) -> Void)?
    var onCursorBegan: (() -> Void)?
    var onCursorEnded: (() -> Void)?
    var onDeleteSwipe: ((Bool) -> Void)?
    var onDeleteHint: ((Int?) -> Void)?
    var accent = UIColor.systemTeal
    var haptics = false
    private var feedback: UIImpactFeedbackGenerator?

    init(key: KeyboardKey) {
        self.key = key; super.init(frame: .zero)
        addSubview(plate); plate.isUserInteractionEnabled = false; plate.layer.cornerRadius = 7
        plate.layer.borderWidth = 0.5
        plate.contentView.addSubview(caption); caption.isUserInteractionEnabled = false; caption.contentMode = .redraw
        plate.contentView.addSubview(icon); icon.isUserInteractionEnabled = false; icon.contentMode = .center
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
    override func layoutSubviews() {
        super.layoutSubviews(); plate.frame = KeyboardGeometry.keyPlate(in: bounds)
        let base: CGFloat = key.action == .language ? 15 : key.label.count == 1 ? 23 : 16
        let fontSize = min(base, max(10, min(plate.bounds.width * 0.88, plate.bounds.height * 0.65)))
        if abs(caption.font.pointSize - fontSize) > 0.1 { caption.font = .systemFont(ofSize: fontSize) }
        caption.frame = plate.bounds; icon.frame = plate.bounds
        plate.layer.shadowPath = plate.bounds.isEmpty ? nil : UIBezierPath(roundedRect: plate.bounds, cornerRadius: 7).cgPath
    }
    func apply(_ settings: KeyboardSettings, title: String? = nil, active: Bool = false, capsLocked: Bool = false) {
        accent = settings.accentColor; haptics = settings.haptics
        let utility: Bool
        switch key.action { case .text, .space: utility = false; default: utility = true }
        let reduced = settings.glass == .solid || UIAccessibility.isReduceTransparencyEnabled || ProcessInfo.processInfo.isLowPowerModeEnabled
        let base = settings.glass == .clear ? (utility ? 0.22 : 0.30) : (utility ? 0.40 : 0.48)
        let alpha = reduced ? 1.0 : base + settings.glassOpacity * 0.40
        plate.backgroundColor = active ? accent.withAlphaComponent(0.22) : (utility ? UIColor.tertiarySystemFill : UIColor.systemBackground).withAlphaComponent(alpha)
        plate.layer.borderColor = UIColor.label.withAlphaComponent(0.06).cgColor
        plate.layer.shadowColor = UIColor.black.cgColor; plate.layer.shadowOpacity = reduced ? 0 : 0.09
        plate.layer.shadowRadius = 0.6; plate.layer.shadowOffset = CGSize(width: 0, height: 1)
        if #available(iOS 26.0, *), !reduced {
            let glass = UIGlassEffect(style: settings.glass == .clear ? .clear : .regular)
            glass.tintColor = settings.accentColor.withAlphaComponent(key.action == .enter ? 0.24 : 0.035)
            glass.isInteractive = !UIAccessibility.isReduceMotionEnabled
            plate.cornerConfiguration = .corners(radius: .fixed(8))
            plate.effect = glass; plate.backgroundColor = .clear
            plate.layer.borderWidth = 0; plate.layer.shadowOpacity = 0
        } else {
            plate.effect = nil; plate.layer.borderWidth = 0.5
        }
        caption.textColor = key.action == .enter || key.action == .language ? settings.accentInkColor : .label
        icon.tintColor = .label
        if key.action == .shift { icon.image = UIImage(systemName: capsLocked ? "capslock.fill" : (active ? "shift.fill" : "shift")) }
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
        didRepeat = false; suppressTap = false; plate.alpha = 0.70
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
        cancelPress()
        if shouldFire { onAction?(key.action) }
    }
    @objc func cancelPress() { repeatStart?.cancel(); repeatTimer?.invalidate(); repeatTimer = nil; plate.alpha = cursorMode ? 0.1 : 1 }
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
