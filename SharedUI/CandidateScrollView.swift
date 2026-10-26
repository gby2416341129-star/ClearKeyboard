import UIKit
import os

/// A paged strip with a bounded pool of visible candidate controls. The whole row is one touch surface;
/// UIKit owns dragging and momentum, independently of the word under a finger.
@MainActor final class CandidateScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private struct Presentation: Equatable {
        let items: [Candidate]
        let context: KeyboardModel.CandidateContext?
        let arithmetic: Bool
        let hasMore: Bool
        let textSize: CandidateTextSize
        let textColor: UIColor?
        let animation: CandidateAnimation
    }
    private var presentation: Presentation?
    private var pending: (Presentation, UIColor)?
    private var frameValue = LatestValue<(Presentation, UIColor)>()
    private let displayFrame = DisplayFrameTask()
    private let frameLog = OSLog(subsystem: "app.clear.keyboard", category: .pointsOfInterest)
    private var ink: UIColor = .systemTeal
    private let strip = UIView()
    private var incomingInk: CandidateInkMotion?
    private var inkAnimator: UIViewPropertyAnimator?
    private var outgoingInk: UIView?
    private var managementActive = false
    private let selectionTap = UITapGestureRecognizer()
    private var tapStoppedScrolling = false
    private var buttons: [CandidateButton] = []
    private var geometry = CandidateStripLayout()
    private var frames: [CGRect] { geometry.frames }
    private var extendingLayout = false
    private var applyingPresentation = false
    private var requestedCount = -1
    private var stripWidth: CGFloat { geometry.width }
    private var viewportSize = CGSize.zero
    private var visibleRange: Range<Int> = 0..<0
    private var accessibleItems: [Any]?
    private var normalFont = UIFont.systemFont(ofSize: 19)
    private var firstFont = UIFont.systemFont(ofSize: 19, weight: .medium)
    private var interactionActive = false
    private var idleScheduled = false
    private var browsed: Presentation?
    private var fingerActive: Bool { isTracking || isDragging || panGestureRecognizer.state == .began || panGestureRecognizer.state == .changed }
    var holdsCandidateUpdates: Bool { fingerActive || isDecelerating || managementActive }
    var onManage: ((Candidate, KeyboardModel.CandidateContext, CGRect) -> Void)?
    var onInteractionChanged: ((Bool) -> Void)?
    var onLoadMore: ((KeyboardModel.CandidateContext?) -> Void)?
    var onSelect: ((Candidate, KeyboardModel.CandidateContext?, Bool) -> Void)?
    override var accessibilityValue: String? {
        get { "offset:\(Int(contentOffset.x));count:\(presentation?.items.count ?? 0)" }
        set {}
    }
    init() {
        super.init(frame: .zero)
        delegate = self
        addSubview(strip)
        strip.isOpaque = false
        // Word faces and their spacing are presentation only. Every contact,
        // including one in a gap, reaches this same scroll view and native pan.
        strip.isUserInteractionEnabled = false
        // The root paints one continuous touch-receiving surface. This row
        // must not add a second rectangular film behind the candidate text.
        backgroundColor = .clear; isOpaque = false
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        delaysContentTouches = false; canCancelContentTouches = true
        alwaysBounceHorizontal = true; alwaysBounceVertical = false
        // Vertical drift must not lock out the next horizontal reversal.
        isDirectionalLockEnabled = false; decelerationRate = .normal
        contentInsetAdjustmentBehavior = .never
        // The strip is inset inside the keyboard shell's curve. A second round
        // mask here cut into the first candidate's highlight independently.
        layer.cornerRadius = 0
        clipsToBounds = true
        scrollsToTop = false
        accessibilityIdentifier = "clear.candidates"
        selectionTap.addTarget(self, action: #selector(candidateTapped(_:)))
        selectionTap.delegate = self
        selectionTap.cancelsTouchesInView = false
        selectionTap.delaysTouchesBegan = false
        selectionTap.delaysTouchesEnded = false
        addGestureRecognizer(selectionTap)
        // Only selection waits for the native pan; dragging never waits for a tap.
        selectionTap.require(toFail: panGestureRecognizer)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(candidateHeld(_:)))
        hold.minimumPressDuration = 0.36; hold.allowableMovement = 9; hold.delegate = self
        addGestureRecognizer(hold)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func update(_ items: [Candidate], context: KeyboardModel.CandidateContext?, arithmetic: Bool,
                accent: UIColor, hasMore: Bool = false, textSize: CandidateTextSize = .standard, textColor: UIColor? = nil, animation: CandidateAnimation = .blur) {
        var next = Presentation(items: items, context: context, arithmetic: arithmetic, hasMore: hasMore, textSize: textSize,
                                textColor: textColor?.resolvedColor(with: traitCollection), animation: animation)
        let resolved = accent.resolvedColor(with: traitCollection)
        if UIAccessibility.isReduceMotionEnabled || UIAccessibility.isVoiceOverRunning {
            buttons.forEach { $0.finishTransition() }
        }
        if sameQuery(browsed, next), let current = presentation, sameQuery(current, next) {
            // Keep every visible target at the same x coordinate, while allowing
            // unseen alternatives to extend the tail during native momentum.
            var seen = Set(current.items.map(\.text))
            let appended = current.items + items.filter { seen.insert($0.text).inserted }
            next = Presentation(items: appended, context: current.context,
                                arithmetic: arithmetic, hasMore: hasMore, textSize: textSize, textColor: next.textColor, animation: next.animation)
            pending = nil; schedule(next, accent: resolved); return
        }
        if holdsCandidateUpdates { pending = (next, resolved); return }
        pending = nil; schedule(next, accent: resolved)
    }
    private func schedule(_ next: Presentation, accent: UIColor) {
        // Word lookup and sentence decoding can both finish within one frame.
        // Measure, lay out and paint only their latest valid row, not both rows.
        if next == presentation, ink.isEqual(accent) {
            frameValue.discard(); displayFrame.cancel(); return
        }
        // A new spelling's first result is already on the main thread. Publish
        // it in this turn instead of waiting for a remote-view display callback.
        // Same-query decoder refinements still share one presentation per frame.
        if presentation == nil || !sameQuery(presentation, next) {
            frameValue.discard(); displayFrame.cancel()
            apply(next, accent: accent)
            return
        }
        frameValue.replace(with: (next, accent))
        displayFrame.schedule(in: self, maximumFramesPerSecond: window?.screen.maximumFramesPerSecond ?? 60) { [weak self] in
            guard let self, let (next, color) = self.frameValue.take() else { return }
            // A finger may have landed after submission but before this frame.
            // Preserve its visible targets; only appending the same query is safe.
            if self.holdsCandidateUpdates && !self.sameQuery(self.browsed, next) {
                self.pending = (next, color); return
            }
            // Browsing can also start between submission and this callback.
            // Recheck the append-only rule at the actual presentation boundary.
            if self.sameQuery(self.browsed, next), let current = self.presentation, self.sameQuery(current, next) {
                var seen = Set(current.items.map(\.text))
                let merged = current.items + next.items.filter { seen.insert($0.text).inserted }
                self.apply(Presentation(items: merged, context: current.context, arithmetic: next.arithmetic,
                    hasMore: next.hasMore, textSize: next.textSize, textColor: next.textColor, animation: next.animation), accent: color)
            } else { self.apply(next, accent: color) }
        }
    }
    private func inkSnapshot() -> UIImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.opaque = false; format.scale = 2
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { renderer in
            for button in buttons where !button.isHidden { button.drawInk(in: renderer.cgContext, relativeTo: self) }
        }
    }
    private func finishIncomingInk() {
        incomingInk?.finish(); incomingInk = nil
        buttons.forEach { $0.setInkOpacity(1) }
    }
    private func transitionInk(_ animation: CandidateAnimation, disappearing: Bool, appearing: Bool) {
        guard window != nil, !UIAccessibility.isReduceMotionEnabled, !UIAccessibility.isVoiceOverRunning else { return }
        if disappearing, let host = superview, let image = inkSnapshot() {
            outgoingInk?.removeFromSuperview()
            if animation == .blur {
                let old = CandidateInkMotion(image: image); outgoingInk = old
                old.frame = convert(bounds, to: host); host.addSubview(old)
                old.run(appearing: false) { [weak self, weak old] in
                    if self?.outgoingInk === old { self?.outgoingInk = nil }
                }
            } else {
                let old = UIImageView(image: image); outgoingInk = old
                old.frame = convert(bounds, to: host); host.addSubview(old)
                UIView.animate(withDuration: 0.15, animations: {
                    old.alpha = 0
                    if animation == .bounce { old.transform = CGAffineTransform(scaleX: 0.96, y: 0.96) }
                }, completion: { [weak self, weak old] _ in
                    old?.removeFromSuperview(); if self?.outgoingInk === old { self?.outgoingInk = nil }
                })
            }
        }
        guard appearing else { return }
        finishIncomingInk()
        guard animation != .bounce else { return }
        finishIncomingInk(); inkAnimator?.stopAnimation(true); inkAnimator = nil
        strip.alpha = 1
        if animation == .blur, let image = inkSnapshot() {
            let effect = CandidateInkMotion(image: image)
            effect.frame = bounds; addSubview(effect); incomingInk = effect
            buttons.forEach { $0.setInkOpacity(0) }
            effect.run(appearing: true) { [weak self, weak effect] in
                guard self?.incomingInk === effect else { return }
                self?.incomingInk = nil; self?.buttons.forEach { $0.setInkOpacity(1) }
            }
        } else {
            buttons.forEach { $0.setInkOpacity(0.86) }
            let animator = UIViewPropertyAnimator(duration: 0.16, curve: .easeOut) { [weak self] in self?.buttons.forEach { $0.setInkOpacity(1) } }
            inkAnimator = animator; animator.startAnimation()
        }
    }
    func prepareToDisappear() {
        guard presentation?.items.isEmpty == false else { return }
        transitionInk(presentation?.animation ?? .blur, disappearing: true, appearing: false)
        finishIncomingInk(); inkAnimator?.stopAnimation(true); inkAnimator = nil
        strip.alpha = 1
        displayFrame.cancel(); frameValue.discard(); pending = nil
        presentation = nil; geometry.reset(); visibleRange = 0..<0
        buttons.forEach { $0.finishTransition(); $0.isHidden = true; $0.tag = -1 }
    }
    func dismissManagement() { managementActive = false; scheduleIdle() }
    @objc private func candidateHeld(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let current = presentation, !current.arithmetic, let context = current.context else { return }
        let point = strip.convert(gesture.location(in: self), from: self)
        let index = firstIndex(at: point.x)
        guard current.items.indices.contains(index), frames.indices.contains(index), frames[index].contains(point) else { return }
        beginBrowsing(); managementActive = true
        KeyboardVibration.shared.pulseInterface()
        onManage?(current.items[index], context, convert(frames[index], from: strip))
    }
    private func selectionFeedback(_ index: Int) {
        guard let host = superview, frames.indices.contains(index) else { return }
        let flash = LiquidGlassView(radius: 8, clear: true)
        let rect = strip.convert(frames[index], to: host).insetBy(dx: 1, dy: 6)
        flash.frame = rect
        flash.configure(tint: ink, strength: 0.65, fallback: ink.withAlphaComponent(0.18))
        host.addSubview(flash)
        flash.transform = CGAffineTransform(scaleX: 0.98, y: 0.96)
        KeyboardVibration.shared.pulseInterface()
        UIView.animate(withDuration: 0.22, delay: 0.025, usingSpringWithDamping: 0.82, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState], animations: {
            flash.transform = .identity; flash.alpha = 0
        }, completion: { _ in flash.removeFromSuperview() })
    }
    func inputChanged() {
        // Only an actual edit may interrupt a coasting row. A decoder result
        // arriving after finger-up is never a reason to stop native momentum.
        guard !fingerActive else { return }
        if isDecelerating { setContentOffset(contentOffset, animated: false) }
        setInteraction(false)
    }
    private func sameQuery(_ lhs: Presentation?, _ rhs: Presentation) -> Bool {
        guard let lhs else { return false }
        guard lhs.arithmetic == rhs.arithmetic, lhs.context?.raw == rhs.context?.raw,
              lhs.context?.document == rhs.context?.document,
              lhs.context?.characters == rhs.context?.characters,
              lhs.context?.language == rhs.context?.language else { return false }
        // Empty-spelling predictions belong to the surrounding text.
        return rhs.context?.raw.isEmpty == false || lhs.context == rhs.context
    }
    private func apply(_ next: Presentation, accent: UIColor) {
        guard next != presentation || !ink.isEqual(accent) else { return }
        applyingPresentation = true
        defer { applyingPresentation = false }
        let event = OSSignpostID(log: frameLog)
        os_signpost(.begin, log: frameLog, name: "CandidateFrame", signpostID: event, "count=%d", next.items.count)
        defer { os_signpost(.end, log: frameLog, name: "CandidateFrame", signpostID: event) }
        let changedQuery = !sameQuery(presentation, next)
        let previous = presentation?.items ?? []
        let changedItems = previous.map(\.text) != next.items.map(\.text)
        let changedColor = !ink.isEqual(accent) || presentation?.textColor != next.textColor
        let changedFont = presentation?.textSize != next.textSize
        let changedAnimation = presentation?.animation != next.animation
        if changedItems {
            finishIncomingInk(); outgoingInk?.removeFromSuperview(); outgoingInk = nil
        }
        if changedAnimation {
            finishIncomingInk(); inkAnimator?.stopAnimation(true); inkAnimator = nil
            strip.alpha = 1
            buttons.forEach { $0.finishTransition() }
        }
        if changedFont {
            normalFont = .systemFont(ofSize: CGFloat(next.textSize.points))
            firstFont = .systemFont(ofSize: CGFloat(next.textSize.points), weight: .medium)
        }
        let appendOnly = next.items.count >= previous.count &&
            zip(previous, next.items).allSatisfy { $0.text == $1.text }
        if changedQuery { browsed = nil; requestedCount = -1 }
        if changedItems, !holdsCandidateUpdates {
            let deleting = next.items.isEmpty || (next.context?.raw.count ?? 0) < (presentation?.context?.raw.count ?? 0)
            transitionInk(next.animation, disappearing: deleting && !previous.isEmpty, appearing: false)
        }
        presentation = next; ink = accent
        if changedItems || changedFont {
            if !appendOnly || changedFont { geometry.reset() }
            extendLayout(offset: changedQuery ? 0 : contentOffset.x)
        }
        if changedQuery { setContentOffset(.zero, animated: false) }
        // Browsing outlives the physical drag. An appended same-query page can
        // arrive just after finger-up, when UIKit no longer reports tracking;
        // its newly pooled words must still appear at rest beside stable targets.
        updateVisible(force: changedColor || changedFont || changedAnimation || (changedItems && !appendOnly),
                      animateChanges: changedItems && (!changedFont || previous.isEmpty) &&
                          !holdsCandidateUpdates && !sameQuery(browsed, next),
                      firstAppearance: previous.isEmpty && !next.items.isEmpty)
        if changedItems || changedAnimation, !holdsCandidateUpdates, !next.items.isEmpty {
            transitionInk(next.animation, disappearing: false, appearing: true)
        }
        if changedItems || changedQuery { updateAccessibility() }
        requestMoreIfNeeded()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if viewportSize != bounds.size {
            viewportSize = bounds.size
            geometry.resize(height: bounds.height)
            extendLayout()
            updateStripSize()
            updateVisible(force: true)
        } else { updateVisible() }
    }
    private func updateStripSize() {
        let size = CGSize(width: max(bounds.width, stripWidth), height: bounds.height)
        if strip.frame.size != size { strip.frame = CGRect(origin: .zero, size: size) }
        if contentSize != size { contentSize = size }
    }
    private func extendLayout(offset: CGFloat? = nil, through index: Int? = nil) {
        guard !extendingLayout, let current = presentation else { return }
        extendingLayout = true
        defer { extendingLayout = false }
        let measured = geometry.extend(count: current.items.count,
            viewport: CGRect(x: offset ?? contentOffset.x, y: 0, width: bounds.width, height: bounds.height),
            through: index) { candidateIndex in
                CandidateButton.width(current.items[candidateIndex],
                    font: candidateIndex == 0 ? firstFont : normalFont) + 4
            }
        if measured > 0 || geometry.frames.isEmpty { updateStripSize() }
    }
    private func firstIndex(at x: CGFloat) -> Int {
        geometry.firstIndex(at: x)
    }
    private func updateVisible(force: Bool = false, animateChanges: Bool = false, firstAppearance: Bool = false) {
        guard let current = presentation else { return }
        let first = firstIndex(at: max(0, contentOffset.x - bounds.width * 0.5))
        var end = first
        while end < frames.count && frames[end].minX <= contentOffset.x + bounds.width * 1.5 { end += 1 }
        let range = first..<end
        // UIScrollView may call both its delegate and layout in the same frame.
        guard force || range != visibleRange else { return }
        visibleRange = range
        while buttons.count < range.count {
            let button = CandidateButton(); button.tag = -1; button.isHidden = true
            button.addTarget(self, action: #selector(candidateUp(_:)), for: .touchUpInside)
            strip.addSubview(button); buttons.append(button)
        }
        // Keep the controls that remain visible. A word entering at one edge
        // should configure one cell, not move and relabel the entire pool.
        for button in buttons where !range.contains(button.tag) {
            button.tag = -1
            button.finishTransition()
            if !button.isHidden { button.isHidden = true }
        }
        var existing = Dictionary(uniqueKeysWithValues: buttons.filter { $0.tag >= 0 }.map { ($0.tag, $0) })
        var unused = buttons.filter { $0.tag < 0 }.makeIterator()
        for index in range {
            let old = existing.removeValue(forKey: index)
            guard let button = old ?? unused.next() else { continue }
            if force || old == nil {
                button.configure(current.items[index], first: index == 0, accent: ink,
                                 font: index == 0 ? firstFont : normalFont,
                                 animate: current.animation == .bounce && animateChanges && window != nil, normalColor: current.textColor,
                                 firstAppearance: firstAppearance)
                button.tag = index
                button.move(to: frames[index], animated: current.animation == .bounce && animateChanges && old != nil && window != nil)
            }
            if button.isHidden { button.isHidden = false }
            button.isAccessibilityElement = false
        }
    }
    private func updateAccessibility() { accessibleItems = nil }
    override var accessibilityElements: [Any]? {
        get {
            // Build virtual offscreen elements only when an accessibility client
            // asks for them, not on every appended candidate page.
            if accessibleItems == nil, let current = presentation {
                accessibleItems = current.items.indices.map {
                    CandidateAccessibility(owner: self, index: $0, text: current.items[$0].text)
                }
            }
            return accessibleItems
        }
        set { accessibleItems = newValue }
    }
    fileprivate func accessibilityFrame(at index: Int) -> CGRect {
        // VoiceOver may explicitly query a distant candidate. Resolve its exact
        // frame on demand, rather than paying for all words on every key press.
        if let current = presentation, current.items.indices.contains(index), !frames.indices.contains(index) {
            extendLayout(through: index)
        }
        guard frames.indices.contains(index) else { return .zero }
        return UIAccessibility.convertToScreenCoordinates(frames[index], in: strip)
    }
    fileprivate func focusCandidate(_ index: Int) {
        if let current = presentation, current.items.indices.contains(index) { extendLayout(through: index) }
        guard frames.indices.contains(index) else { return }
        beginBrowsing(); scrollRectToVisible(frames[index], animated: false)
        requestMoreIfNeeded(); scheduleIdle()
    }
    private func requestMoreIfNeeded() {
        guard let current = presentation, current.hasMore, !current.arithmetic,
              frames.count == current.items.count,
              sameQuery(browsed, current),
              current.context?.raw.isEmpty == false, bounds.width > 0,
              contentOffset.x + bounds.width * 3 >= stripWidth,
              requestedCount != current.items.count else { return }
        requestedCount = current.items.count
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sameQuery(self.presentation, current) else { return }
            self.onLoadMore?(current.context)
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === selectionTap else { return true }
        tapStoppedScrolling = isDecelerating || isScrollAnimating
        if tapStoppedScrolling {
            // A new contact anywhere in the row takes over old momentum.
            // Do not reset the native pan or consume the new drag to stop it.
            stopScrollingAndZooming()
        }
        beginBrowsing()
        return true
    }
    @objc private func candidateTapped(_ recognizer: UITapGestureRecognizer) {
        defer { scheduleIdle() }
        guard recognizer.state == .ended, !tapStoppedScrolling else { return }
        selectCandidate(at: recognizer.location(in: self))
    }
    /// `point` uses this scroll view's bounds coordinates, including its offset.
    func selectCandidate(at point: CGPoint) {
        guard !isDragging, !isDecelerating, bounds.contains(point) else { return }
        let local = strip.convert(point, from: self)
        let index = firstIndex(at: local.x)
        guard frames.indices.contains(index) else { return }
        var face = frames[index]; face.size.width = max(0, face.width - 4)
        guard face.contains(local) else { return }
        activate(index)
    }
    @objc private func candidateUp(_ sender: CandidateButton) {
        // Accessibility activation keeps the same snapshot as a physical tap.
        if !isDragging && !isDecelerating { activate(sender.tag) }
        scheduleIdle()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        scheduleIdle()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        scheduleIdle()
    }
    fileprivate func activate(_ index: Int) {
        guard let current = presentation, current.items.indices.contains(index) else { return }
        buttons.forEach { $0.finishTransition() }
        selectionFeedback(index)
        onSelect?(current.items[index], current.context, current.arithmetic)
    }
    private func setInteraction(_ active: Bool) {
        guard interactionActive != active else { return }
        interactionActive = active; onInteractionChanged?(active)
    }
    private func beginBrowsing() {
        // Touches select the latest actual row. End any visual blend at contact
        // down; native scrolling and selection never chase an animated target.
        buttons.forEach { $0.finishTransition() }
        finishIncomingInk(); inkAnimator?.stopAnimation(true); inkAnimator = nil
        strip.alpha = 1; outgoingInk?.removeFromSuperview(); outgoingInk = nil
        browsed = presentation
        setInteraction(true)
        if let (next, color) = pending, sameQuery(browsed, next) {
            pending = nil
            update(next.items, context: next.context, arithmetic: next.arithmetic,
                   accent: color, hasMore: next.hasMore, textSize: next.textSize, textColor: next.textColor, animation: next.animation)
        }
        requestedCount = -1; requestMoreIfNeeded()
    }
    private func scheduleIdle() {
        guard !idleScheduled else { return }; idleScheduled = true
        // Native tracking wins even if another contact starts in this turn.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.idleScheduled = false
                guard !self.holdsCandidateUpdates else { return }
                self.setInteraction(false)
                if let (next, color) = self.pending {
                    self.pending = nil
                    // Recheck the browsing lock after finger-up as well.
                    self.update(next.items, context: next.context, arithmetic: next.arithmetic, accent: color, hasMore: next.hasMore, textSize: next.textSize, textColor: next.textColor, animation: next.animation)
                }
            }
        }
    }
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !applyingPresentation else { return }
        extendLayout()
        updateVisible()
        requestMoreIfNeeded()
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        beginBrowsing()
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scheduleIdle() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { scheduleIdle() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            displayFrame.cancel(); frameValue.discard()
            finishIncomingInk(); inkAnimator?.stopAnimation(true); inkAnimator = nil
            strip.alpha = 1
            outgoingInk?.removeFromSuperview(); outgoingInk = nil
            buttons.forEach { $0.finishTransition() }
            pending = nil; browsed = nil; setInteraction(false)
        }
    }
}

@MainActor final class CandidateButton: UIButton {
    private static let measuredWidths: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>(); cache.countLimit = 512; return cache
    }()
    private let plate = UIView()
    private let label = UILabel()
    private(set) var transitionDeadline: CFTimeInterval = 0
    private static let transitionDuration: CFTimeInterval = 0.24
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(plate); addSubview(label)
        plate.isUserInteractionEnabled = false
        backgroundColor = .clear
        label.isUserInteractionEnabled = false; label.isAccessibilityElement = false
        label.numberOfLines = 1; label.lineBreakMode = .byClipping
        label.accessibilityIdentifier = "candidate.currentInk"
        plate.layer.cornerRadius = 8; plate.layer.cornerCurve = .continuous; plate.clipsToBounds = true
        isAccessibilityElement = true; accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let height = max(0, min(bounds.height - 12, max(28, ceil(label.font.lineHeight) + 8)))
        plate.frame = CGRect(x: 0, y: (bounds.height - height) / 2,
                             width: max(0, bounds.width - 4), height: height)
        // Ink uses the row's full height, independently of its smaller rounded
        // highlight. Large text must retain headroom during the two-point settle.
        label.frame = CGRect(x: 8, y: 0, width: max(0, bounds.width - 20), height: bounds.height)
    }
    static func width(_ candidate: Candidate, font: UIFont) -> CGFloat {
        let key = "\(font.fontName):\(font.pointSize):\(candidate.text)" as NSString
        if let value = measuredWidths.object(forKey: key) { return CGFloat(value.doubleValue) }
        let width = max(36, ceil((candidate.text as NSString).size(withAttributes: [.font: font]).width) + 16)
        measuredWidths.setObject(NSNumber(value: Double(width)), forKey: key)
        return width
    }
    func setInkOpacity(_ value: CGFloat) { label.alpha = value }
    func drawInk(in context: CGContext, relativeTo view: UIView) {
        layoutIfNeeded()
        let rect = label.convert(label.bounds, to: view).offsetBy(dx: -view.bounds.minX, dy: -view.bounds.minY)
        guard rect.intersects(CGRect(origin: .zero, size: view.bounds.size)) else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        label.drawText(in: CGRect(origin: .zero, size: label.bounds.size))
        context.restoreGState()
    }
    func configure(_ candidate: Candidate, first: Bool, accent: UIColor, font: UIFont, animate: Bool = false,
                   normalColor: UIColor? = nil, reduceMotion: Bool? = nil,
                   voiceOver: Bool? = nil, firstAppearance: Bool = false) {
        let reduceMotion = reduceMotion ?? UIAccessibility.isReduceMotionEnabled
        let voiceOver = voiceOver ?? UIAccessibility.isVoiceOverRunning
        let oldText = label.text
        let changedFont = label.font != font
        if label.font != font { label.font = font }
        if label.text != candidate.text { label.text = candidate.text }
        label.textColor = normalColor ?? (first ? accent : .label)
        plate.backgroundColor = first ? .secondarySystemFill : .clear
        accessibilityLabel = "候选：" + candidate.text; accessibilityIdentifier = "candidate." + candidate.text
        if changedFont || reduceMotion || voiceOver { finishTransition() }
        guard firstAppearance || oldText != candidate.text else {
            // Geometry can refresh immediately after this row was published.
            // Reusing unchanged ink must not cancel its in-flight animation.
            return
        }
        guard animate, !reduceMotion, !voiceOver else { finishTransition(); return }
        // Retarget the currently displayed ink. New words are readable at once;
        // no old bitmap, opacity dip or delayed cleanup competes with later keys.
        let now = CACurrentMediaTime()
        let current = label.layer.presentation()?.transform ?? CATransform3DIdentity
        let room = max(0, (bounds.height - font.lineHeight) / 2 - 1)
        let y = min(room, firstAppearance ? 3 : (abs(current.m42) > 0.01 ? current.m42 : 1.25))
        let scale = firstAppearance ? 0.965 : (abs(current.m11 - 1) > 0.001 ? current.m11 : 0.985)
        transitionDeadline = now + Self.transitionDuration
        label.layer.add(spring("transform.translation.y", from: y, to: CGFloat.zero, layer: label.layer, now: now),
                        forKey: "candidateTextPosition")
        label.layer.add(spring("transform.scale", from: scale, to: CGFloat(1), layer: label.layer, now: now),
                        forKey: "candidateText")
    }
    private func spring(_ key: String, from: Any, to: Any, layer: CALayer, now: CFTimeInterval) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: key)
        animation.mass = 1; animation.stiffness = 560; animation.damping = 32
        animation.initialVelocity = 0
        animation.fromValue = from; animation.toValue = to
        animation.duration = Self.transitionDuration
        animation.beginTime = layer.convertTime(now, from: nil)
        let maximum = Float(window?.screen.maximumFramesPerSecond ?? 60)
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        return animation
    }
    func move(to target: CGRect, animated: Bool) {
        let position = layer.presentation()?.position ?? layer.position
        let previous = frame
        let leading = position.x - bounds.width / 2
        frame = target
        if tag == 0 { layer.removeAnimation(forKey: "candidateCellPosition"); return }
        guard animated, !isHidden,
              !UIAccessibility.isReduceMotionEnabled, !UIAccessibility.isVoiceOverRunning else {
            layer.removeAnimation(forKey: "candidateCellPosition")
            return
        }
        guard previous != target else { return }
        // The latest layout and hit targets are authoritative. Core Animation
        // only carries the visible cell from its current position to that layout.
        let offset = max(-min(18, target.minX), min(18, leading - target.minX))
        let start = CGPoint(x: layer.position.x + offset, y: layer.position.y)
        layer.add(spring("position", from: NSValue(cgPoint: start), to: NSValue(cgPoint: layer.position),
                         layer: layer, now: CACurrentMediaTime()), forKey: "candidateCellPosition")
    }
    func finishTransition(matching deadline: CFTimeInterval) {
        guard transitionDeadline == deadline else { return }
        finishTransition()
    }
    func finishTransition() {
        layer.removeAnimation(forKey: "candidateCellPosition")
        label.layer.removeAnimation(forKey: "candidateText")
        label.layer.removeAnimation(forKey: "candidateTextPosition")
        label.alpha = 1; label.layer.opacity = 1; label.layer.transform = CATransform3DIdentity
        transitionDeadline = 0
    }
    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside); return true
    }
}


@MainActor private final class CandidateAccessibility: UIAccessibilityElement {
    private weak var owner: CandidateScrollView?
    private let index: Int
    init(owner: CandidateScrollView, index: Int, text: String) {
        self.owner = owner; self.index = index
        super.init(accessibilityContainer: owner)
        accessibilityLabel = "候选：" + text
        accessibilityIdentifier = "candidate." + text
        accessibilityTraits = .button
    }
    override var accessibilityFrame: CGRect {
        get { owner?.accessibilityFrame(at: index) ?? .zero }
        set {}
    }
    override func accessibilityElementDidBecomeFocused() { owner?.focusCandidate(index) }
    override func accessibilityActivate() -> Bool { owner?.activate(index); return owner != nil }
}
