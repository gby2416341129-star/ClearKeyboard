import UIKit

/// Native buttons handle taps and UIScrollView cancels them when a pan begins.
/// The visible presentation stays fixed until the current finger lifts.
@MainActor final class CandidateScrollView: UIScrollView, UIScrollViewDelegate {
    private struct Presentation: Equatable {
        let items: [Candidate]
        let context: KeyboardModel.CandidateContext?
        let arithmetic: Bool
    }
    private let content = UIView()
    private var buttons: [CandidateItemButton] = []
    private var presentation: Presentation?
    private var pending: (Presentation, UIColor)?
    private var ink: UIColor = .systemTeal
    private var contentWidth: CGFloat = 0
    private var contact = false
    private var candidatePanActive = false
    var holdsCandidateUpdates: Bool { contact || candidatePanActive || isTracking || isDragging }
    var onSettled: (() -> Void)?
    var onInteractionChanged: ((Bool) -> Void)?
    var onSelect: ((Candidate, KeyboardModel.CandidateContext?, Bool) -> Void)?
    override var accessibilityValue: String? {
        get { "offset:\(Int(contentOffset.x));count:\(presentation?.items.count ?? 0)" }
        set {}
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self; addSubview(content)
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        delaysContentTouches = false; canCancelContentTouches = true
        alwaysBounceHorizontal = true; isDirectionalLockEnabled = true
        decelerationRate = .fast
        accessibilityIdentifier = "clear.candidates"
        panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        content.frame = CGRect(x: 0, y: 0, width: contentWidth, height: bounds.height)
    }
    func update(_ items: [Candidate], context: KeyboardModel.CandidateContext?, arithmetic: Bool, accent: UIColor) {
        let next = Presentation(items: items, context: context, arithmetic: arithmetic)
        let resolved = accent.resolvedColor(with: traitCollection)
        if holdsCandidateUpdates || isTracking || isDragging { pending = (next, resolved); return }
        pending = nil; apply(next, accent: resolved)
    }
    private func apply(_ next: Presentation, accent: UIColor) {
        guard next != presentation || !ink.isEqual(accent) else { return }
        let changedQuery = presentation?.context != next.context || presentation?.arithmetic != next.arithmetic
        presentation = next; ink = accent
        while buttons.count > next.items.count { buttons.removeLast().removeFromSuperview() }
        var x: CGFloat = 2
        for (index, candidate) in next.items.enumerated() {
            let button: CandidateItemButton
            if index < buttons.count { button = buttons[index] }
            else {
                button = CandidateItemButton(frame: .zero)
                button.onContact = { [weak self] active in self?.setContact(active) }
                content.addSubview(button); buttons.append(button)
            }
            let font = UIFont.systemFont(ofSize: 19, weight: index == 0 ? .medium : .regular)
            button.titleLabel?.font = font; button.setTitle(candidate.text, for: .normal)
            button.setTitleColor(index == 0 ? accent : .label, for: .normal)
            button.backgroundColor = index == 0 ? .secondarySystemFill : .clear; button.layer.cornerRadius = 8
            button.accessibilityLabel = "候选：" + candidate.text; button.accessibilityIdentifier = "candidate." + candidate.text
            let width = ceil((candidate.text as NSString).size(withAttributes: [.font: font]).width) + (index == 0 ? 20 : 0)
            button.frame = CGRect(x: x, y: 0, width: max(22, width), height: 44)
            button.onActivation = { [weak self] in self?.onSelect?(candidate, next.context, next.arithmetic) }
            x = button.frame.maxX + 22
        }
        contentWidth = max(0, x - 10)
        content.frame = CGRect(x: 0, y: 0, width: contentWidth, height: 44)
        contentSize = CGSize(width: contentWidth, height: 44)
        if changedQuery { setContentOffset(.zero, animated: false) }
        setNeedsLayout()
    }
    private func settled() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.holdsCandidateUpdates else { return }
            self.onInteractionChanged?(false)
            if let (next, color) = self.pending { self.pending = nil; self.apply(next, accent: color) }
            self.onSettled?()
        }
    }
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
    private func setContact(_ active: Bool) {
        contact = active
        if active {
            if isDecelerating { setContentOffset(contentOffset, animated: false) }
            onInteractionChanged?(true)
        } else { settled() }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        setContact(true); super.touchesBegan(touches, with: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event); setContact(false)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        setContact(false)
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { candidatePanActive = true; onInteractionChanged?(true) }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        contact = false; candidatePanActive = false; settled()
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settled() }
    @objc private func panChanged(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            contact = false; candidatePanActive = false; settled()
        }
    }
}

@MainActor private final class CandidateItemButton: UIButton {
    var onActivation: (() -> Void)?
    var onContact: ((Bool) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true; accessibilityTraits = .button
        addTarget(self, action: #selector(activate), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { onContact?(true); super.touchesBegan(touches, with: event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { super.touchesEnded(touches, with: event); onContact?(false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { super.touchesCancelled(touches, with: event); onContact?(false) }
    @objc func activate() { onActivation?() }
    override func accessibilityActivate() -> Bool { activate(); return true }
}
