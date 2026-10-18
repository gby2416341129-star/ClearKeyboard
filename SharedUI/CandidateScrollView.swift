import UIKit

/// One scroll gesture owns the entire ribbon. Candidate children do not compete
/// with it for touches, and no controls are disabled or replaced under a finger.
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
    private(set) var holdsCandidateUpdates = false
    var onSettled: (() -> Void)?
    var onSelect: ((Candidate, KeyboardModel.CandidateContext?, Bool) -> Void)?
    override var accessibilityValue: String? {
        get { "offset:\(Int(contentOffset.x));count:\(presentation?.items.count ?? 0)" }
        set {}
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self; addSubview(content); content.isUserInteractionEnabled = false
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        delaysContentTouches = false; canCancelContentTouches = true
        alwaysBounceHorizontal = true; isDirectionalLockEnabled = true
        accessibilityIdentifier = "clear.candidates"
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapCandidate(_:)))
        tap.cancelsTouchesInView = false; tap.delaysTouchesBegan = false; tap.delaysTouchesEnded = false
        tap.require(toFail: panGestureRecognizer); addGestureRecognizer(tap)
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
            guard let self, !self.holdsCandidateUpdates, !self.isTracking, !self.isDragging else { return }
            if let (next, color) = self.pending { self.pending = nil; self.apply(next, accent: color) }
            self.onSettled?()
        }
    }
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        holdsCandidateUpdates = true; super.touchesBegan(touches, with: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event); holdsCandidateUpdates = false; settled()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        if !isDragging { holdsCandidateUpdates = false; settled() }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { holdsCandidateUpdates = true }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        holdsCandidateUpdates = false; settled()
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settled() }
    @objc private func tapCandidate(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: content)
        if let button = buttons.first(where: { $0.frame.insetBy(dx: -8, dy: 0).contains(point) }) { button.activate() }
        holdsCandidateUpdates = false; settled()
    }
}

@MainActor private final class CandidateItemButton: UIButton {
    var onActivation: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        // The scroll view classifies a pan or a tap. Children remain available to
        // accessibility and programmatic actions without consuming finger events.
        isUserInteractionEnabled = false; isAccessibilityElement = true; accessibilityTraits = .button
        addTarget(self, action: #selector(activate), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    @objc func activate() { onActivation?() }
    override func accessibilityActivate() -> Bool { activate(); return true }
}
