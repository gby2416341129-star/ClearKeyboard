import UIKit

final class GlassBackdrop: UIView {
    private let material = UIVisualEffectView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(material)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() { super.layoutSubviews(); material.frame = bounds }
    func apply(_ settings: KeyboardSettings, systemBacked: Bool = false) {
        let reduced = UIAccessibility.isReduceTransparencyEnabled || ProcessInfo.processInfo.isLowPowerModeEnabled || settings.glass == .solid
        isOpaque = false; backgroundColor = reduced ? .secondarySystemBackground : .clear
        if reduced || systemBacked { material.effect = nil }
        else if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: settings.glass == .clear ? .clear : .regular)
            glass.isInteractive = false; material.effect = glass
            material.cornerConfiguration = .corners(radius: .fixed(28))
        } else { material.effect = UIBlurEffect(style: settings.glass == .clear ? .systemUltraThinMaterial : .systemMaterial) }
    }
}

final class KeyButton: UIButton {
    let key: KeyboardKey
    private let plate = UIVisualEffectView()
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

    init(key: KeyboardKey) {
        self.key = key; super.init(frame: .zero)
        addSubview(plate); plate.isUserInteractionEnabled = false; plate.layer.cornerRadius = 8
        plate.layer.cornerCurve = .continuous
        plate.layer.borderWidth = 0.5
        plate.contentView.addSubview(pressWash); pressWash.isUserInteractionEnabled = false
        pressWash.layer.cornerRadius = 8; pressWash.layer.cornerCurve = .continuous
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
        plate.layer.shadowPath = plate.bounds.isEmpty ? nil : UIBezierPath(roundedRect: plate.bounds, cornerRadius: 8).cgPath
    }
    func apply(_ settings: KeyboardSettings, title: String? = nil, active: Bool = false, capsLocked: Bool = false) {
        accent = settings.accentColor; haptics = settings.haptics
        let dark = traitCollection.userInterfaceStyle == .dark
        let utility = key.action == .shift || key.action == .delete || (key.units == 1.5 && key.label.count > 1)
        let reduced = settings.glass == .solid || UIAccessibility.isReduceTransparencyEnabled || ProcessInfo.processInfo.isLowPowerModeEnabled
        // A continuous system glass sheet supplies the backdrop. Key faces transmit
        // that material instead of stacking 30 separate refracting lenses on top.
        plate.effect = nil
        if reduced {
            plate.backgroundColor = UIColor(white: dark ? (utility ? 0.19 : 0.30) : (utility ? 0.82 : 0.97), alpha: 1)
            plate.layer.borderWidth = 0
        } else {
            let base = settings.glass == .clear ? (dark ? 0.14 : 0.62) : (dark ? 0.25 : 0.78)
            let alpha = min(0.92, base + settings.glassOpacity * 0.12)
            plate.backgroundColor = UIColor.white.withAlphaComponent(utility ? alpha * 0.58 : alpha)
            plate.layer.borderWidth = 0.5
        }
        plate.layer.borderColor = UIColor.white.withAlphaComponent(dark ? 0.18 : 0.65).cgColor
        plate.layer.shadowColor = UIColor.black.cgColor; plate.layer.shadowOpacity = reduced ? 0 : 0.10
        plate.layer.shadowRadius = 0.5; plate.layer.shadowOffset = CGSize(width: 0, height: 0.5)
        pressWash.backgroundColor = active ? UIColor.label.withAlphaComponent(0.10) : .clear
        caption.textColor = .label
        icon.tintColor = .label
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
        didRepeat = false; suppressTap = false; pressWash.backgroundColor = UIColor.label.withAlphaComponent(0.10)
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
    @objc func cancelPress() {
        repeatStart?.cancel(); repeatTimer?.invalidate(); repeatTimer = nil
        pressWash.backgroundColor = .clear; plate.alpha = cursorMode ? 0.1 : 1
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
