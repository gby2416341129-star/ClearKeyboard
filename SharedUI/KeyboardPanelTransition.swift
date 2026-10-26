import UIKit

/// One interruptible transition for every keyboard panel. The toolbar stays
/// anchored while the outgoing page softens and the incoming page settles.
@MainActor final class KeyboardPanelTransition {
    private var cover: UIView?
    private var incomingBlur: UIVisualEffectView?
    private weak var destination: UIView?
    private var animator: UIViewPropertyAnimator?
    private var outgoingAnimator: UIViewPropertyAnimator?
    private var revision = 0
    var isAnimating: Bool { animator?.isRunning == true }

    func begin(in host: UIView, region: CGRect, animated: Bool = true) {
        let enabled = animated && host.window != nil && UIView.areAnimationsEnabled &&
            !UIAccessibility.isReduceMotionEnabled && !region.isEmpty
        let snapshot = enabled ? host.resizableSnapshotView(from: region, afterScreenUpdates: false, withCapInsets: .zero) : nil
        cancel()
        guard let snapshot else { return }
        snapshot.frame = region; snapshot.isUserInteractionEnabled = false
        snapshot.accessibilityElementsHidden = true
        snapshot.accessibilityIdentifier = "toolbar.transition.snapshot"
        host.addSubview(snapshot); cover = snapshot
    }
    func finish(to content: UIView, in host: UIView) {
        destination = content; content.alpha = 1; content.transform = .identity
        content.isUserInteractionEnabled = true
        guard let cover else { return }
        let outgoingBlur = UIVisualEffectView(effect: nil)
        outgoingBlur.frame = cover.bounds; outgoingBlur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        outgoingBlur.isUserInteractionEnabled = false; cover.addSubview(outgoingBlur)
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        blur.frame = content.bounds; blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blur.isUserInteractionEnabled = false; blur.alpha = 0.38
        content.addSubview(blur); incomingBlur = blur
        content.alpha = 0.65
        content.transform = CGAffineTransform(translationX: 0, y: 7).scaledBy(x: 0.985, y: 0.985)
        host.bringSubviewToFront(cover)
        let token = revision
        let motion = UIViewPropertyAnimator(duration: 0.30, dampingRatio: 0.88) {
            content.alpha = 1; content.transform = .identity
            blur.effect = nil; blur.alpha = 0
        }
        let outgoing = UIViewPropertyAnimator(duration: 0.18, curve: .easeOut) {
            cover.alpha = 0
            cover.transform = CGAffineTransform(translationX: 0, y: -3).scaledBy(x: 1.012, y: 1.012)
            outgoingBlur.effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        animator = motion; outgoingAnimator = outgoing
        motion.addCompletion { [weak self, weak content] _ in
            guard let self, self.revision == token else { return }
            content?.alpha = 1; content?.transform = .identity
            cover.removeFromSuperview(); blur.removeFromSuperview()
            self.cover = nil; self.incomingBlur = nil; self.destination = nil
            self.animator = nil; self.outgoingAnimator = nil
        }
        outgoing.startAnimation(); motion.startAnimation()
    }
    func cancel() {
        revision += 1
        if animator?.state == .active { animator?.stopAnimation(true) }
        if outgoingAnimator?.state == .active { outgoingAnimator?.stopAnimation(true) }
        destination?.alpha = 1; destination?.transform = .identity; destination = nil
        incomingBlur?.removeFromSuperview(); incomingBlur = nil
        cover?.removeFromSuperview(); cover = nil
        animator = nil; outgoingAnimator = nil
    }
}
