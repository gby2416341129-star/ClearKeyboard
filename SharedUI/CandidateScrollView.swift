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
    private var contact = false
    private var candidatePanActive = false
    private var momentumActive = false
    private var interactionActive = false
    private var settleScheduled = false
    var holdsCandidateUpdates: Bool { contact || candidatePanActive || momentumActive || isTracking || isDragging || isDecelerating }
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
        isDirectionalLockEnabled = true; decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        accessibilityIdentifier = "clear.candidates"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func update(_ items: [Candidate], context: KeyboardModel.CandidateContext?, arithmetic: Bool, accent: UIColor) {
        let next = Presentation(items: items, context: context, arithmetic: arithmetic)
        let resolved = accent.resolvedColor(with: traitCollection)
        let newSpelling = presentation?.context?.raw != context?.raw ||
            presentation?.context?.document != context?.document || presentation?.arithmetic != arithmetic
        if newSpelling, !contact, !candidatePanActive, !isTracking, !isDragging {
            stopMomentum()
        }
        if holdsCandidateUpdates { pending = (next, resolved); return }
        pending = nil; apply(next, accent: resolved)
    }
    private func apply(_ next: Presentation, accent: UIColor) {
        guard next != presentation || !ink.isEqual(accent) else { return }
        let changedQuery = presentation?.context != next.context || presentation?.arithmetic != next.arithmetic
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
            cell.button.onContact = { [weak self] active in self?.setContact(active) }
            cell.button.onActivation = { [weak self] in self?.activate(indexPath.item) }
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
    private func settled() {
        guard !settleScheduled else { return }
        settleScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settleScheduled = false
            guard !self.holdsCandidateUpdates else { return }
            self.setInteraction(false)
            if let (next, color) = self.pending { self.pending = nil; self.apply(next, accent: color) }
            self.onSettled?()
        }
    }
    private func stopMomentum() {
        momentumActive = false
        if isDecelerating { setContentOffset(contentOffset, animated: false) }
        if !contact, !candidatePanActive { settled() }
    }
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
    private func setContact(_ active: Bool) {
        contact = active
        if active { stopMomentum(); setInteraction(true) }
        else { settled() }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        setContact(true); super.touchesBegan(touches, with: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event); setContact(false)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event); setContact(false)
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        candidatePanActive = true; momentumActive = false; setInteraction(true)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        contact = false; candidatePanActive = false; momentumActive = decelerate
        if !decelerate { settled() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { momentumActive = false; settled() }
}

@MainActor private final class CandidateCell: UICollectionViewCell {
    static let reuseID = "clear.candidate.cell"
    let button = CandidateItemButton(frame: .zero)
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(button); backgroundColor = .clear
        isAccessibilityElement = false
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
    }
    override func prepareForReuse() {
        super.prepareForReuse(); button.onActivation = nil; button.onContact = nil
    }
}

@MainActor private final class CandidateItemButton: UIButton {
    var onActivation: (() -> Void)?
    var onContact: ((Bool) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true; accessibilityTraits = .button
        contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        titleLabel?.lineBreakMode = .byClipping; clipsToBounds = true
        addTarget(self, action: #selector(activate), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { onContact?(true); super.touchesBegan(touches, with: event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { super.touchesEnded(touches, with: event); onContact?(false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { super.touchesCancelled(touches, with: event); onContact?(false) }
    @objc func activate() { onActivation?() }
    override func accessibilityActivate() -> Bool { activate(); return true }
}
