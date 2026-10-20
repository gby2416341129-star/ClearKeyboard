import UIKit

/// A paged strip with a bounded pool of visible candidate controls. The whole row is one touch surface;
/// UIKit owns dragging and momentum, independently of the word under a finger.
@MainActor final class CandidateScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private struct Presentation: Equatable {
        let items: [Candidate]
        let context: KeyboardModel.CandidateContext?
        let arithmetic: Bool
        let hasMore: Bool
    }
    private var presentation: Presentation?
    private var pending: (Presentation, UIColor)?
    private var ink: UIColor = .systemTeal
    private let strip = UIView()
    private let selectionTap = UITapGestureRecognizer()
    private var tapStoppedScrolling = false
    private var buttons: [CandidateButton] = []
    private var frames: [CGRect] = []
    private var requestedCount = -1
    private var stripWidth: CGFloat = 0
    private var viewportSize = CGSize.zero
    private var interactionActive = false
    private var idleScheduled = false
    private var browsed: Presentation?
    private var fingerActive: Bool { isTracking || isDragging || panGestureRecognizer.state == .began || panGestureRecognizer.state == .changed }
    var holdsCandidateUpdates: Bool { fingerActive || isDecelerating }
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
        // Remote keyboard hosts can discard a contact on fully clear pixels
        // before UIKit hit testing. Paint the entire receiving viewport, including
        // word gaps and exposed edges during bounce. Keep the view itself at
        // full alpha so text stays crisp; only this neutral backing is translucent.
        backgroundColor = UIColor(white: 0.5, alpha: 0.01); isOpaque = false
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        delaysContentTouches = false; canCancelContentTouches = true
        alwaysBounceHorizontal = true; alwaysBounceVertical = false
        // Vertical drift must not lock out the next horizontal reversal.
        isDirectionalLockEnabled = false; decelerationRate = .normal
        contentInsetAdjustmentBehavior = .never
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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func update(_ items: [Candidate], context: KeyboardModel.CandidateContext?, arithmetic: Bool,
                accent: UIColor, hasMore: Bool = false) {
        var next = Presentation(items: items, context: context, arithmetic: arithmetic, hasMore: hasMore)
        let resolved = accent.resolvedColor(with: traitCollection)
        if sameQuery(browsed, next), let current = presentation, sameQuery(current, next) {
            // Keep every visible target at the same x coordinate, while allowing
            // unseen alternatives to extend the tail during native momentum.
            var seen = Set(current.items.map(\.text))
            let appended = current.items + items.filter { seen.insert($0.text).inserted }
            next = Presentation(items: appended, context: current.context,
                                arithmetic: arithmetic, hasMore: hasMore)
            pending = nil; apply(next, accent: resolved); return
        }
        if holdsCandidateUpdates { pending = (next, resolved); return }
        pending = nil; apply(next, accent: resolved)
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
              lhs.context?.language == rhs.context?.language else { return false }
        // Empty-spelling predictions belong to the surrounding text.
        return rhs.context?.raw.isEmpty == false || lhs.context == rhs.context
    }
    private func apply(_ next: Presentation, accent: UIColor) {
        guard next != presentation || !ink.isEqual(accent) else { return }
        let changedQuery = !sameQuery(presentation, next)
        let previous = presentation?.items ?? []
        let changedItems = previous.map(\.text) != next.items.map(\.text)
        let changedColor = !ink.isEqual(accent)
        let appendOnly = next.items.count >= previous.count &&
            zip(previous, next.items).allSatisfy { $0.text == $1.text }
        if changedQuery { browsed = nil; requestedCount = -1 }
        presentation = next; ink = accent
        if changedItems {
            if !appendOnly { frames = [] }
            var x = frames.last?.maxX ?? 2
            for index in frames.count..<next.items.count {
                let width = CandidateButton.width(next.items[index], first: index == 0) + 12
                frames.append(CGRect(x: x, y: 0, width: width, height: bounds.height))
                x += width
            }
            stripWidth = x
            updateStripSize()
        }
        if changedQuery { setContentOffset(.zero, animated: false) }
        updateVisible(force: changedColor || (changedItems && !appendOnly))
        if changedItems || changedQuery { updateAccessibility() }
        requestMoreIfNeeded()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if viewportSize != bounds.size {
            viewportSize = bounds.size
            for index in frames.indices { frames[index].size.height = bounds.height }
            updateStripSize()
            updateVisible(force: true)
        } else { updateVisible() }
    }
    private func updateStripSize() {
        let size = CGSize(width: max(bounds.width, stripWidth), height: bounds.height)
        if strip.frame.size != size { strip.frame = CGRect(origin: .zero, size: size) }
        if contentSize != size { contentSize = size }
    }
    private func firstIndex(at x: CGFloat) -> Int {
        var low = 0, high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].maxX < x { low = middle + 1 } else { high = middle }
        }
        return low
    }
    private func updateVisible(force: Bool = false) {
        guard let current = presentation else { return }
        let small = frames.count <= 32
        let first = small ? 0 : firstIndex(at: max(0, contentOffset.x - bounds.width))
        var end = first
        while end < frames.count && (small || frames[end].minX <= contentOffset.x + bounds.width * 2) { end += 1 }
        let needed = min(frames.count, max(32, end - first))
        while buttons.count < needed {
            let button = CandidateButton()
            button.tag = -1
            button.addTarget(self, action: #selector(candidateUp(_:)), for: .touchUpInside)
            strip.addSubview(button); buttons.append(button)
        }
        while buttons.count > needed { buttons.removeLast().removeFromSuperview() }
        for (slot, button) in buttons.enumerated() {
            let index = first + slot
            let visible = index < end
            button.isHidden = !visible
            guard visible else { continue }
            if force || button.tag != index {
                button.configure(current.items[index], first: index == 0, accent: ink)
                button.tag = index; button.frame = frames[index]
            }
            button.isAccessibilityElement = small
        }
    }
    private func updateAccessibility() {
        if frames.count <= 32 {
            accessibilityElements = buttons
        } else {
            accessibilityElements = frames.indices.map { index in
                CandidateAccessibility(owner: self, index: index, text: presentation!.items[index].text)
            }
        }
    }
    fileprivate func accessibilityFrame(at index: Int) -> CGRect {
        guard frames.indices.contains(index) else { return .zero }
        return UIAccessibility.convertToScreenCoordinates(frames[index], in: strip)
    }
    fileprivate func focusCandidate(_ index: Int) {
        guard frames.indices.contains(index) else { return }
        beginBrowsing(); scrollRectToVisible(frames[index], animated: false)
        requestMoreIfNeeded(); scheduleIdle()
    }
    private func requestMoreIfNeeded() {
        guard let current = presentation, current.hasMore, !current.arithmetic,
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
        var face = frames[index]; face.size.width = max(0, face.width - 12)
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
        onSelect?(current.items[index], current.context, current.arithmetic)
    }
    private func setInteraction(_ active: Bool) {
        guard interactionActive != active else { return }
        interactionActive = active; onInteractionChanged?(active)
    }
    private func beginBrowsing() {
        browsed = presentation
        setInteraction(true)
        if let (next, color) = pending, sameQuery(browsed, next) {
            pending = nil
            update(next.items, context: next.context, arithmetic: next.arithmetic,
                   accent: color, hasMore: next.hasMore)
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
                    self.update(next.items, context: next.context, arithmetic: next.arithmetic, accent: color, hasMore: next.hasMore)
                }
            }
        }
    }
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
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
        if window == nil { pending = nil; browsed = nil; setInteraction(false) }
    }
}

@MainActor private final class CandidateButton: UIButton {
    private let plate = UIView()
    private let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(plate); plate.addSubview(label)
        plate.isUserInteractionEnabled = false
        backgroundColor = .clear
        label.isUserInteractionEnabled = false; label.isAccessibilityElement = false
        label.numberOfLines = 1; label.lineBreakMode = .byClipping
        plate.layer.cornerRadius = 8; plate.clipsToBounds = true
        isAccessibilityElement = true; accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        plate.frame = CGRect(x: 0, y: 0, width: max(0, bounds.width - 12), height: bounds.height)
        label.frame = plate.bounds.insetBy(dx: 10, dy: 0)
    }
    static func width(_ candidate: Candidate, first: Bool) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 19, weight: first ? .medium : .regular)
        return max(42, ceil((candidate.text as NSString).size(withAttributes: [.font: font]).width) + 20)
    }
    func configure(_ candidate: Candidate, first: Bool, accent: UIColor) {
        let font = UIFont.systemFont(ofSize: 19, weight: first ? .medium : .regular)
        label.font = font
        label.text = candidate.text; label.textColor = first ? accent : .label
        plate.backgroundColor = first ? .secondarySystemFill : .clear
        accessibilityLabel = "候选：" + candidate.text; accessibilityIdentifier = "candidate." + candidate.text
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
