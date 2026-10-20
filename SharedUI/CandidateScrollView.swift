import UIKit

/// A small, fixed strip of candidates. UIKit owns dragging and momentum; no
/// collection layout, cell recycling or selection recognizer runs while scrolling.
@MainActor final class CandidateScrollView: UIScrollView, UIScrollViewDelegate {
    private struct Presentation: Equatable {
        let items: [Candidate]
        let context: KeyboardModel.CandidateContext?
        let arithmetic: Bool
    }
    private var presentation: Presentation?
    private var pending: (Presentation, UIColor)?
    private var ink: UIColor = .systemTeal
    private let strip = UIView()
    private var buttons: [CandidateButton] = []
    private var stripWidth: CGFloat = 0
    private var viewportSize = CGSize.zero
    private var interactionActive = false
    private var idleScheduled = false
    private var browsed: Presentation?
    private var fingerActive: Bool { isTracking || isDragging || panGestureRecognizer.state == .began || panGestureRecognizer.state == .changed }
    var holdsCandidateUpdates: Bool { fingerActive || isDecelerating }
    var onInteractionChanged: ((Bool) -> Void)?
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
        backgroundColor = .clear; isOpaque = false
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        delaysContentTouches = false; canCancelContentTouches = true
        alwaysBounceHorizontal = true; alwaysBounceVertical = false
        // Vertical drift must not lock out the next horizontal reversal.
        isDirectionalLockEnabled = false; decelerationRate = .normal
        contentInsetAdjustmentBehavior = .never
        scrollsToTop = false
        accessibilityIdentifier = "clear.candidates"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func update(_ items: [Candidate], context: KeyboardModel.CandidateContext?, arithmetic: Bool, accent: UIColor) {
        let next = Presentation(items: items, context: context, arithmetic: arithmetic)
        let resolved = accent.resolvedColor(with: traitCollection)
        let newSpelling = !sameQuery(presentation, next)
        if !newSpelling, sameQuery(browsed, next) {
            // A decoder finishing between two opposite flicks must not replace
            // controls, move the selected target or reset the offset. This lock is
            // released by the next spelling, not by a timer after finger-up.
            return
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
        if changedQuery { browsed = nil }
        let changedItems = presentation?.items.map(\.text) != next.items.map(\.text) || !ink.isEqual(accent)
        presentation = next; ink = accent
        if changedItems {
            // The engine returns at most 24 choices. Keep their controls alive
            // for this query so a direction change needs no creation or sizing.
            while buttons.count < next.items.count {
                let button = CandidateButton()
                button.addTarget(self, action: #selector(candidateDown), for: .touchDown)
                button.addTarget(self, action: #selector(candidateUp(_:)), for: .touchUpInside)
                button.addTarget(self, action: #selector(candidateCancelled), for: [.touchCancel, .touchUpOutside])
                strip.addSubview(button); buttons.append(button)
            }
            while buttons.count > next.items.count { buttons.removeLast().removeFromSuperview() }
            var x: CGFloat = 2
            for (index, candidate) in next.items.enumerated() {
                let button = buttons[index]
                let width = button.configure(candidate, first: index == 0, accent: accent)
                button.tag = index
                // Include the inter-word spacing in the control's hit area.
                button.frame = CGRect(x: x, y: 0, width: width + 12, height: bounds.height)
                x += width + 12
            }
            stripWidth = x
            updateStripSize()
        }
        if changedQuery { setContentOffset(.zero, animated: false) }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        // A scroll changes bounds.origin every frame. Only a viewport resize
        // may touch content geometry; ordinary scrolling has no app layout work.
        guard viewportSize != bounds.size else { return }
        viewportSize = bounds.size
        for button in buttons {
            var frame = button.frame; frame.size.height = bounds.height
            button.frame = frame
        }
        updateStripSize()
    }
    private func updateStripSize() {
        let size = CGSize(width: max(bounds.width, stripWidth), height: bounds.height)
        if strip.frame.size != size { strip.frame = CGRect(origin: .zero, size: size) }
        if contentSize != size { contentSize = size }
    }
    @objc private func candidateDown() { beginBrowsing() }
    @objc private func candidateCancelled() { scheduleIdle() }
    @objc private func candidateUp(_ sender: CandidateButton) {
        // UIScrollView cancels the control as soon as its native pan wins.
        // The explicit guard also rejects activation during momentum.
        if !isDragging && !isDecelerating { activate(sender.tag) }
        scheduleIdle()
    }
    private func activate(_ index: Int) {
        guard let current = presentation, current.items.indices.contains(index) else { return }
        onSelect?(current.items[index], current.context, current.arithmetic)
    }
    private func setInteraction(_ active: Bool) {
        guard interactionActive != active else { return }
        interactionActive = active; onInteractionChanged?(active)
    }
    private func beginBrowsing() {
        browsed = presentation
        if let next = pending?.0, sameQuery(browsed, next) { pending = nil }
        setInteraction(true)
    }
    private func scheduleIdle() {
        guard !idleScheduled else { return }; idleScheduled = true
        // No recognizer, failure dependency, hold threshold or settlement timer.
        // Native tracking wins even if another finger starts in this turn.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.idleScheduled = false
                guard !self.holdsCandidateUpdates else { return }
                self.setInteraction(false)
                if let (next, color) = self.pending {
                    self.pending = nil
                    // Recheck the browsing lock after finger-up as well.
                    self.update(next.items, context: next.context, arithmetic: next.arithmetic, accent: color)
                }
            }
        }
    }
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
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
    func configure(_ candidate: Candidate, first: Bool, accent: UIColor) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 19, weight: first ? .medium : .regular)
        label.font = font
        label.text = candidate.text; label.textColor = first ? accent : .label
        plate.backgroundColor = first ? .secondarySystemFill : .clear
        accessibilityLabel = "候选：" + candidate.text; accessibilityIdentifier = "candidate." + candidate.text
        return max(42, ceil((candidate.text as NSString).size(withAttributes: [.font: font]).width) + 20)
    }
    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside); return true
    }
}
