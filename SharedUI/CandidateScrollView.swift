import UIKit

/// UIKit owns the entire touch stream, selection and interruption of momentum.
/// Once a row is being browsed, keep that query's visible choices stationary.
@MainActor final class CandidateScrollView: UICollectionView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private struct Presentation: Equatable {
        let items: [Candidate]
        let context: KeyboardModel.CandidateContext?
        let arithmetic: Bool
    }
    private var presentation: Presentation?
    private var pending: (Presentation, UIColor)?
    private var ink: UIColor = .systemTeal
    private var widths: [CGFloat] = []
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
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 12; layout.minimumInteritemSpacing = 0
        layout.estimatedItemSize = .zero
        layout.sectionInset = UIEdgeInsets(top: 0, left: 2, bottom: 0, right: 12)
        super.init(frame: .zero, collectionViewLayout: layout)
        dataSource = self; delegate = self
        register(CandidateCell.self, forCellWithReuseIdentifier: CandidateCell.reuseID)
        backgroundColor = .clear; isOpaque = false
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        delaysContentTouches = false; canCancelContentTouches = true
        alwaysBounceHorizontal = true; alwaysBounceVertical = false
        // Vertical drift must not lock out the next horizontal reversal.
        isDirectionalLockEnabled = false; decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        isPrefetchingEnabled = false
        accessibilityIdentifier = "clear.candidates"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func update(_ items: [Candidate], context: KeyboardModel.CandidateContext?, arithmetic: Bool, accent: UIColor) {
        let next = Presentation(items: items, context: context, arithmetic: arithmetic)
        let resolved = accent.resolvedColor(with: traitCollection)
        let newSpelling = !sameQuery(presentation, next)
        if !newSpelling, sameQuery(browsed, next) {
            // A decoder finishing between two opposite flicks must not replace
            // cells, move the selected target or reset the offset. This lock is
            // released by the next spelling, not by a timer after finger-up.
            return
        }
        if newSpelling, !fingerActive {
            if isDecelerating { setContentOffset(contentOffset, animated: false) }
            setInteraction(false)
        }
        if holdsCandidateUpdates { pending = (next, resolved); return }
        pending = nil; apply(next, accent: resolved)
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
            // Size each item once per result, never on a scrolling frame.
            widths = next.items.enumerated().map { index, candidate in
                let font = UIFont.systemFont(ofSize: 19, weight: index == 0 ? .medium : .regular)
                return max(42, ceil((candidate.text as NSString).size(withAttributes: [.font: font]).width) + 20)
            }
            reloadData()
        }
        if changedQuery { setContentOffset(.zero, animated: false) }
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        presentation?.items.count ?? 0
    }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = dequeueReusableCell(withReuseIdentifier: CandidateCell.reuseID, for: indexPath) as! CandidateCell
        if let current = presentation, current.items.indices.contains(indexPath.item) {
            cell.configure(current.items[indexPath.item], first: indexPath.item == 0, accent: ink)
            cell.onActivation = { [weak self] in self?.activate(indexPath.item) }
        }
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        activate(indexPath.item); deselectItem(at: indexPath, animated: false)
        scheduleIdle()
    }
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        beginBrowsing(); return true
    }
    func collectionView(_ collectionView: UICollectionView, didUnhighlightItemAt indexPath: IndexPath) {
        scheduleIdle()
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: widths.indices.contains(indexPath.item) ? widths[indexPath.item] : 22, height: 44)
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
                if let (next, color) = self.pending { self.pending = nil; self.apply(next, accent: color) }
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

@MainActor private final class CandidateCell: UICollectionViewCell {
    static let reuseID = "clear.candidate.cell"
    private let label = UILabel()
    var onActivation: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(label); backgroundColor = .clear
        label.isUserInteractionEnabled = false; label.isAccessibilityElement = false
        label.numberOfLines = 1; label.lineBreakMode = .byClipping
        contentView.layer.cornerRadius = 8; contentView.clipsToBounds = true
        isAccessibilityElement = true; accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() { super.layoutSubviews(); label.frame = contentView.bounds.insetBy(dx: 10, dy: 0) }
    func configure(_ candidate: Candidate, first: Bool, accent: UIColor) {
        label.font = .systemFont(ofSize: 19, weight: first ? .medium : .regular)
        label.text = candidate.text; label.textColor = first ? accent : .label
        contentView.backgroundColor = first ? .secondarySystemFill : .clear
        accessibilityLabel = "候选：" + candidate.text; accessibilityIdentifier = "candidate." + candidate.text
    }
    override func accessibilityActivate() -> Bool { onActivation?(); return true }
    override func prepareForReuse() {
        super.prepareForReuse(); onActivation = nil
    }
}
