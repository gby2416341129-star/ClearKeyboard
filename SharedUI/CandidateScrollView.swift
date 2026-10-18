import UIKit

/// Native collection-cell reuse and selection, informed by Hamster (MIT).
/// Candidate snapshots stay fixed through tracking AND deceleration; a new
/// spelling can interrupt old momentum without waiting for a scroll animation.
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
    private var settleTimer: Timer?
    private lazy var contactObserver: CandidateContactObserver = {
        let observer = CandidateContactObserver(target: nil, action: nil)
        observer.cancelsTouchesInView = false; observer.delaysTouchesBegan = false; observer.delaysTouchesEnded = false
        observer.changed = { [weak self] active in
            guard let self else { return }
            if active { self.cancelSettlement(); self.setInteraction(true) }
            else { self.scheduleSettlement() }
        }
        return observer
    }()
    private var panActive: Bool { panGestureRecognizer.state == .began || panGestureRecognizer.state == .changed }
    private var fingerActive: Bool { contactObserver.hasContacts || panActive || isTracking || isDragging }
    var holdsCandidateUpdates: Bool { fingerActive || isDecelerating || settleTimer != nil }
    var onSettled: (() -> Void)?
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
        accessibilityIdentifier = "clear.candidates"
        addGestureRecognizer(contactObserver)
        panGestureRecognizer.addTarget(self, action: #selector(panChanged))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func update(_ items: [Candidate], context: KeyboardModel.CandidateContext?, arithmetic: Bool, accent: UIColor) {
        let next = Presentation(items: items, context: context, arithmetic: arithmetic)
        let resolved = accent.resolvedColor(with: traitCollection)
        let newSpelling = presentation?.context?.raw != context?.raw ||
            presentation?.context?.document != context?.document ||
            presentation?.context?.language != context?.language || presentation?.arithmetic != arithmetic
        if newSpelling, !fingerActive {
            // Typing another spelling may replace an old, coasting row. Finger
            // contact itself never writes contentOffset or stops the native pan.
            cancelSettlement()
            if isDecelerating { setContentOffset(contentOffset, animated: false) }
            setInteraction(false)
        }
        if holdsCandidateUpdates { pending = (next, resolved); return }
        pending = nil; apply(next, accent: resolved)
    }
    private func apply(_ next: Presentation, accent: UIColor) {
        guard next != presentation || !ink.isEqual(accent) else { return }
        let changedQuery = presentation?.context?.raw != next.context?.raw ||
            presentation?.context?.document != next.context?.document ||
            presentation?.context?.language != next.context?.language || presentation?.arithmetic != next.arithmetic
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
    private func cancelSettlement() { settleTimer?.invalidate(); settleTimer = nil }
    private func scheduleSettlement() {
        cancelSettlement()
        // A button cancellation or a gap between reverse flicks is not a safe
        // time to reload the row. Apply only after native scrolling has ended
        // and a short idle interval; the default mode excludes tracking frames.
        let timer = Timer(timeInterval: 0.08, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settleTimer = nil
                guard !self.fingerActive, !self.isDecelerating else { return }
                self.setInteraction(false)
                if let (next, color) = self.pending { self.pending = nil; self.apply(next, accent: color) }
                self.onSettled?()
            }
        }
        settleTimer = timer; RunLoop.main.add(timer, forMode: .default)
    }
    @objc private func panChanged() {
        if panActive { cancelSettlement(); setInteraction(true) }
        else { scheduleSettlement() }
    }
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelSettlement(); setInteraction(true)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scheduleSettlement() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { scheduleSettlement() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelSettlement(); pending = nil; setInteraction(false) }
    }
    deinit { settleTimer?.invalidate() }
}

@MainActor private final class CandidateCell: UICollectionViewCell {
    static let reuseID = "clear.candidate.cell"
    let button = CandidateItemButton(frame: .zero)
    var onActivation: (() -> Void)? { didSet { button.onActivation = onActivation } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(button); backgroundColor = .clear
        // The collection owns physical taps and pans. Its visual control never
        // consumes, cancels, or hands a touch back to the scrolling recognizer.
        button.isUserInteractionEnabled = false; button.isAccessibilityElement = false
        isAccessibilityElement = true; accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() { super.layoutSubviews(); button.frame = contentView.bounds }
    func configure(_ candidate: Candidate, first: Bool, accent: UIColor) {
        button.titleLabel?.font = .systemFont(ofSize: 19, weight: first ? .medium : .regular)
        button.setTitle(candidate.text, for: .normal)
        button.setTitleColor(first ? accent : .label, for: .normal)
        button.backgroundColor = first ? .secondarySystemFill : .clear; button.layer.cornerRadius = 8
        button.accessibilityLabel = "候选：" + candidate.text
        button.accessibilityIdentifier = "candidate." + candidate.text
        accessibilityLabel = button.accessibilityLabel; accessibilityIdentifier = button.accessibilityIdentifier
    }
    override func accessibilityActivate() -> Bool { onActivation?(); return true }
    override func prepareForReuse() {
        super.prepareForReuse(); onActivation = nil
    }
}

@MainActor private final class CandidateItemButton: UIButton {
    var onActivation: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true; accessibilityTraits = .button
        contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        titleLabel?.lineBreakMode = .byClipping; clipsToBounds = true
        addTarget(self, action: #selector(activate), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    @objc func activate() { onActivation?() }
    override func accessibilityActivate() -> Bool { activate(); return true }
}

/// Observes contact lifetime without recognizing or preventing any gesture.
/// Unlike child-button cancellations, these contacts survive native pan takeover.
@MainActor private final class CandidateContactObserver: UIGestureRecognizer {
    private var contacts = Set<UITouch>()
    var changed: (Bool) -> Void = { _ in }
    var hasContacts: Bool { !contacts.isEmpty }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let wasActive = hasContacts; contacts.formUnion(touches)
        if !wasActive { changed(true) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
    private func finish(_ touches: Set<UITouch>) {
        let wasActive = hasContacts; contacts.subtract(touches)
        if wasActive && !hasContacts { changed(false); state = .failed }
    }
    override func reset() {
        let wasActive = hasContacts; contacts.removeAll(); super.reset()
        if wasActive { changed(false) }
    }
}
