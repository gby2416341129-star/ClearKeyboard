import UIKit

final class KeyButton: UIButton {
    let key: KeyboardKey
    private let plate = UIView()
    private let lens = LiquidGlassView(radius: 8, keycap: true)
    private let pressWash = UIView()
    private var shiftStateWash: UIView?
    private let caption = CenteredKeyLabel()
    private let icon = UIImageView()
    private var repeatTimer: Timer?
    private var repeatStart: DispatchWorkItem?
    private var didRepeat = false
    private var draggingCursor = false
    private var suppressTap = false
    private var cursorMode = false
    private var cursorOrigin = CGPoint.zero
    private var deletionDirection = 0
    private var choiceGesture: UILongPressGestureRecognizer?
    private var choicePopup: KeyChoicePopup?
    private weak var choiceHost: UIView?
    private var choices: [String] = []
    private let punctuationHint = CenteredKeyLabel()
    var onAlternateBegan: (() -> Void)?
    var onAction: ((KeyAction) -> Void)?
    var onPrepare: ((KeyAction) -> Void)?
    var onInteractionChanged: ((Bool) -> Void)?
    var onCursor: ((CGPoint) -> Void)?
    var onCursorBegan: (() -> Void)?
    var onCursorEnded: (() -> Void)?
    var onDeleteSwipe: ((Bool) -> Void)?
    var onDeleteHint: ((Int?) -> Void)?
    var accent = UIColor.systemTeal
    private var vibrationEnabled = false
    private var vibrationIntensity: Double = 0.45
    private var vibrationMode: VibrationMode = .crisp
    private let vibration: KeyboardVibration
    private var interactionActive = false
    private var pressBeganAt: CFTimeInterval = 0
    private var pressRelease: DispatchWorkItem?
    private var releaseScheduled = false
    private var shiftSymbol = ""
    private var appearanceSettings: KeyboardSettings?

    init(key: KeyboardKey, vibration: KeyboardVibration? = nil) {
        self.key = key; self.vibration = vibration ?? .shared; super.init(frame: .zero)
        // Touch coverage belongs to the continuous keyboard root. Individual
        // cell backings left rectangular blocks visible between glass keys.
        backgroundColor = .clear; isOpaque = false
        addSubview(plate); plate.isUserInteractionEnabled = false; plate.layer.cornerRadius = 8
        plate.accessibilityIdentifier = "key.face"
        plate.layer.cornerCurve = .continuous
        plate.layer.borderWidth = 0
        plate.insertSubview(lens, at: 0)
        plate.addSubview(pressWash); pressWash.isUserInteractionEnabled = false
        pressWash.alpha = 0
        pressWash.layer.cornerRadius = 8; pressWash.layer.cornerCurve = .continuous
        plate.addSubview(caption); caption.isUserInteractionEnabled = false; caption.contentMode = .redraw
        plate.addSubview(icon); icon.isUserInteractionEnabled = false; icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 21, weight: .regular)
        caption.textAlignment = .center; caption.text = key.label
        caption.font = .systemFont(ofSize: key.label.count == 1 ? 23 : 16)
        switch key.action {
        case .shift:
            let state = UIView(); state.isUserInteractionEnabled = false
            state.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.16)
            state.layer.cornerRadius = 8; state.layer.cornerCurve = .continuous; state.isHidden = true
            plate.insertSubview(state, belowSubview: pressWash); shiftStateWash = state
            icon.image = ToolArtwork.shift(active: false, capsLocked: false, ink: .label)
        case .delete: icon.image = ToolArtwork.image(symbol: "delete.left", size: 28)
        case .globe: icon.image = ToolArtwork.image(symbol: "globe", size: 32)
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
        if case .text = key.action {
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(alternativeGesture(_:)))
            hold.minimumPressDuration = 0.35; hold.allowableMovement = 14
            hold.cancelsTouchesInView = false
            addGestureRecognizer(hold); choiceGesture = hold
        }
        if key.alternatives.count == 2, ["，", ","].contains(key.label) {
            punctuationHint.text = key.alternatives[1]; punctuationHint.textColor = .secondaryLabel
            punctuationHint.font = .systemFont(ofSize: 11); punctuationHint.isUserInteractionEnabled = false
            plate.addSubview(punctuationHint)
            accessibilityHint = "长按后向右滑动输入句号"
        }
        addTarget(self, action: #selector(down), for: .touchDown)
        addTarget(self, action: #selector(up), for: .touchUpInside)
        addTarget(self, action: #selector(cancelPress), for: [.touchUpOutside, .touchCancel, .touchDragExit])
        if key.action == .space {
            let cursor = UILongPressGestureRecognizer(target: self, action: #selector(cursorGesture(_:)))
            cursor.minimumPressDuration = 0.22; cursor.allowableMovement = 14; addGestureRecognizer(cursor)
        }
        if key.action == .delete {
            let swipe = UIPanGestureRecognizer(target: self, action: #selector(deletionGesture(_:)))
            swipe.maximumNumberOfTouches = 1; addGestureRecognizer(swipe)
        }
        // A parent's trait callback can run before this key inherits the new
        // traits. Recompute its fixed face on the key's own transition so the
        // dynamic legend cannot change to white over a stale light face.
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (key: KeyButton, _: UITraitCollection) in
            if let settings = key.appearanceSettings { key.applyAppearance(settings) }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopTracking() }
        else if let settings = appearanceSettings { applyAppearance(settings) }
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Once this key owns a finger, tolerate the small release drift of fast
        // taps. Initial hit testing still uses the original, non-overlapping cells.
        if isTracking, case .text = key.action { return bounds.insetBy(dx: -7, dy: -10).contains(point) }
        return super.point(inside: point, with: event)
    }
    func updateShift(active: Bool, capsLocked: Bool) {
        guard key.action == .shift else { return }
        shiftStateWash?.isHidden = !active && !capsLocked
        let symbol = capsLocked ? "capslock.fill" : active ? "shift.fill" : "shift"
        guard shiftSymbol != symbol else { return }
        shiftSymbol = symbol; icon.image = ToolArtwork.shift(active: active, capsLocked: capsLocked, ink: (appearanceSettings?.keyInkColor(utility: true) ?? .label).resolvedColor(with: traitCollection))
        accessibilityValue = capsLocked ? "大写锁定" : active ? "大写" : "小写"
    }
    override func layoutSubviews() {
        super.layoutSubviews(); plate.frame = KeyboardGeometry.keyPlate(in: bounds, action: key.action, units: key.units)
        let base: CGFloat = key.action == .language ? 14 : key.label.count == 1 ? 23 : 16
        let fontSize = min(base, max(10, min(plate.bounds.width * 0.88, plate.bounds.height * 0.65)))
        if abs(caption.font.pointSize - fontSize) > 0.1 { caption.font = .systemFont(ofSize: fontSize) }
        lens.bounds = plate.bounds; lens.center = CGPoint(x: plate.bounds.midX, y: plate.bounds.midY)
        caption.frame = plate.bounds; icon.frame = plate.bounds; pressWash.frame = plate.bounds
        shiftStateWash?.frame = plate.bounds
        if icon.image != nil {
            let limit: CGFloat = key.action == .globe ? 32 : key.action == .shift ? 25 : 28
            let side = max(0, min(limit, min(plate.bounds.width - 4, plate.bounds.height - 6)))
            icon.contentMode = .scaleAspectFit
            icon.frame = CGRect(x: (plate.bounds.width - side) / 2, y: (plate.bounds.height - side) / 2, width: side, height: side)
        }
        if punctuationHint.superview != nil {
            punctuationHint.frame = CGRect(x: 0, y: 2, width: plate.bounds.width, height: 14)
            caption.frame = plate.bounds.offsetBy(dx: 0, dy: 3)
        }
    }
    func apply(_ settings: KeyboardSettings, title: String? = nil, active: Bool = false, capsLocked: Bool = false) {
        accent = settings.accentColor; vibrationEnabled = settings.usesVibration; vibrationIntensity = settings.resolvedVibrationIntensity
        vibrationMode = settings.resolvedVibrationMode
        choices = KeyAlternatives.choices(for: key, language: settings.language)
        choiceGesture?.isEnabled = choices.count > 1
        accessibilityCustomActions = choices.map { value in
            UIAccessibilityCustomAction(name: "输入 " + value) { [weak self] _ in self?.onAction?(.literal(value)); return true }
        }
        if vibrationEnabled && !suppressTypingVibration { vibration.prepare(mode: vibrationMode) }
        appearanceSettings = settings; applyAppearance(settings)
        pressWash.backgroundColor = UIColor.label.withAlphaComponent(0.24)
        updateShift(active: active, capsLocked: capsLocked)
        if let title { updateTitle(title) }
    }
    private func applyAppearance(_ settings: KeyboardSettings) {
        let dark = traitCollection.userInterfaceStyle == .dark
        let utility = key.action == .shift || key.action == .delete || (key.units == 1.5 && key.label.count > 1)
        let reduced = UIAccessibility.isReduceTransparencyEnabled || ProcessInfo.processInfo.isLowPowerModeEnabled
        let fallback = settings.keyTintColor ?? UIColor(white: dark ? (utility ? 0.19 : 0.30) : (utility ? 0.82 : 0.97), alpha: 1)
        lens.configure(tint: settings.keyTintColor, strength: settings.resolvedKeyGlassStrength, fallback: fallback, reduced: reduced,
                       colorOpacity: settings.keyFaceOpacity(dark: dark, utility: utility))
        plate.backgroundColor = .clear
        plate.layer.borderWidth = 0
        plate.layer.shadowOpacity = 0
        let ink = settings.keyInkColor(utility: utility)
        caption.textColor = ink
        icon.tintColor = ink
        if key.action == .shift { icon.image = ToolArtwork.shift(active: shiftSymbol != "shift" && !shiftSymbol.isEmpty, capsLocked: shiftSymbol == "capslock.fill", ink: ink.resolvedColor(with: traitCollection)) }
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
    var suppressTypingVibration = false
    @objc private func down() {
        if !interactionActive { interactionActive = true; onInteractionChanged?(true) }
        didRepeat = false; suppressTap = false
        pressRelease?.cancel(); pressRelease = nil; releaseScheduled = false
        pressBeganAt = CACurrentMediaTime()
        pressWash.layer.removeAnimation(forKey: "keyRelease"); pressWash.alpha = 1
        pressWash.backgroundColor = UIColor.label.withAlphaComponent(0.24)
        plate.layer.removeAnimation(forKey: "keySpring")
        plate.transform = UIAccessibility.isReduceMotionEnabled ? .identity
            : CGAffineTransform(translationX: 0, y: 1.3).scaledBy(x: 0.945, y: 0.945)
        onPrepare?(key.action)
        if key.action == .space { vibration.attach(to: self); vibration.prepareCursorActivation() }
        if vibrationEnabled && !suppressTypingVibration {
            var host: UIView = self
            while let parent = host.superview, !(host is KeyboardSurface) { host = parent }
            vibration.attach(to: host); vibration.pulse(intensity: vibrationIntensity, mode: vibrationMode)
        }
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
        schedulePressRelease()
        // Keep the contact active through the write and its synchronous host
        // notifications. Releasing first scheduled idle reads that the very
        // same key immediately cancelled and re-created.
        if shouldFire { onAction?(key.action) }
        cancelPress()
    }
    @objc func cancelPress() {
        // Dragging away from the original key belongs to the choice picker.
        // Do not prematurely cancel its ordered input contact on touchDragExit.
        guard choicePopup == nil else { return }
        repeatStart?.cancel(); repeatTimer?.invalidate(); repeatTimer = nil
        schedulePressRelease()
        if interactionActive { interactionActive = false; onInteractionChanged?(false) }
    }
    private func schedulePressRelease() {
        guard !releaseScheduled else { return }
        releaseScheduled = true
        let delay = window == nil ? 0 : max(0, 0.045 - (CACurrentMediaTime() - pressBeganAt))
        if delay == 0 { releasePressAppearance(); return }
        let release = DispatchWorkItem { [weak self] in self?.releasePressAppearance() }
        pressRelease = release; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: release)
    }
    private func releasePressAppearance() {
        pressRelease = nil
        let displayed = plate.layer.presentation()?.transform ?? plate.layer.transform
        plate.transform = .identity; plate.layer.removeAnimation(forKey: "keySpring")
        if (displayed.m11 < 0.999 || abs(displayed.m42) > 0.01), window != nil, !UIAccessibility.isReduceMotionEnabled {
            let scale = CASpringAnimation(keyPath: "transform.scale")
            scale.fromValue = displayed.m11; scale.toValue = 1
            let depth = CASpringAnimation(keyPath: "transform.translation.y")
            depth.fromValue = displayed.m42; depth.toValue = 0
            for spring in [scale, depth] {
                spring.mass = 1; spring.stiffness = 1100; spring.damping = 40; spring.duration = 0.12
            }
            let spring = CAAnimationGroup(); spring.animations = [scale, depth]; spring.duration = 0.12
            let rate = Float(window?.screen.maximumFramesPerSecond ?? 60)
            spring.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
            plate.layer.add(spring, forKey: "keySpring")
        }
        let opacity = pressWash.layer.presentation()?.opacity ?? Float(pressWash.alpha)
        pressWash.alpha = 0; plate.alpha = cursorMode ? 0.1 : 1
        pressWash.layer.removeAnimation(forKey: "keyRelease")
        if opacity > 0, !UIAccessibility.isReduceMotionEnabled {
            let release = CABasicAnimation(keyPath: "opacity")
            let maximum = Float(window?.screen.maximumFramesPerSecond ?? 60)
            release.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
            release.fromValue = opacity; release.toValue = 0; release.duration = 0.07
            release.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pressWash.layer.add(release, forKey: "keyRelease")
        }
    }
    @objc private func alternativeGesture(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard choices.count > 1 else { return }
            suppressTap = true; onAlternateBegan?()
            var ancestor = superview
            while let value = ancestor, !(value is KeyboardSurface) { ancestor = value.superview }
            guard let host = ancestor ?? superview else { return }
            choiceHost = host
            let origin = gesture.location(in: host)
            let initial = KeyAlternatives.initialIndex(for: key, choices: choices, language: appearanceSettings?.language ?? .chinese, displayedLabel: caption.text)
            let popup = KeyChoicePopup(choices: choices, initial: initial, origin: origin,
                anchor: convert(bounds, to: host), host: host, accent: accent)
            choicePopup = popup; host.addSubview(popup)
        case .changed:
            if let host = choiceHost { choicePopup?.update(at: gesture.location(in: host)) }
        case .ended:
            if let host = choiceHost { choicePopup?.update(at: gesture.location(in: host)) }
            let value = choicePopup?.selectedValue
            choicePopup?.removeFromSuperview(); choicePopup = nil; choiceHost = nil
            if let value { onAction?(.literal(value)) }
            cancelPress()
        case .cancelled, .failed:
            choicePopup?.removeFromSuperview(); choicePopup = nil; choiceHost = nil; cancelPress()
        default: break
        }
    }
    @objc private func cursorGesture(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: window)
        switch gesture.state {
        case .began:
            draggingCursor = true; suppressTap = true; cursorOrigin = point
            // Trackpad entry is a mode-change acknowledgement, independent of typing vibration.
            vibration.attach(to: self); vibration.pulseCursorActivation()
            onCursorBegan?()
        case .changed:
            // The remote editor paints its own caret. Waiting for this keyboard
            // to redraw can stall movement while the blank keys are static.
            onCursor?(CGPoint(x: point.x - cursorOrigin.x, y: point.y - cursorOrigin.y))
        default:
            if gesture.state == .ended, draggingCursor {
                onCursor?(CGPoint(x: point.x - cursorOrigin.x, y: point.y - cursorOrigin.y))
            }
            if draggingCursor { draggingCursor = false; onCursorEnded?() }
            cancelPress()
        }
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
        choicePopup?.removeFromSuperview(); choicePopup = nil; choiceHost = nil
        suppressTap = true
        onDeleteHint?(nil)
        if draggingCursor { draggingCursor = false; onCursorEnded?() }
        cancelPress()
    }
    deinit { repeatTimer?.invalidate(); repeatStart?.cancel(); pressRelease?.cancel() }
}
