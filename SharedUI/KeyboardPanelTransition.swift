import UIKit

/// A short fade-through keeps the toolbar and panel bounds stationary. The
/// previous page clears early, rather than showing two readable pages ghosted
/// over one another for a quarter second. New taps interrupt from the display.
@MainActor final class KeyboardPanelTransition {
    private var cover: UIView?
    private weak var destination: UIView?
    private var animator: UIViewPropertyAnimator?
    private var outgoingAnimator: UIViewPropertyAnimator?
    private var revision = 0
    var isAnimating: Bool { animator?.isRunning == true }

    func begin(in host: UIView, region: CGRect, animated: Bool = true) {
        let canAnimate = animated && host.window != nil && UIView.areAnimationsEnabled &&
            !UIAccessibility.isReduceMotionEnabled && !region.isEmpty
        let snapshot = canAnimate ? host.resizableSnapshotView(from: region,
            afterScreenUpdates: false, withCapInsets: .zero) : nil
        cancel()
        guard let snapshot else { return }
        snapshot.frame = region
        snapshot.isUserInteractionEnabled = false
        snapshot.accessibilityElementsHidden = true
        snapshot.accessibilityIdentifier = "toolbar.transition.snapshot"
        host.addSubview(snapshot); cover = snapshot
    }

    func finish(to content: UIView, in host: UIView) {
        destination = content
        content.alpha = 1; content.isUserInteractionEnabled = true
        guard let cover else { return }
        host.bringSubviewToFront(cover)
        content.alpha = 0
        let token = revision
        let timing = UICubicTimingParameters(controlPoint1: CGPoint(x: 0.16, y: 0),
                                             controlPoint2: CGPoint(x: 0.32, y: 1))
        let motion = UIViewPropertyAnimator(duration: 0.13, timingParameters: timing)
        let outgoing = UIViewPropertyAnimator(duration: 0.07, curve: .easeOut) { cover.alpha = 0 }
        outgoingAnimator = outgoing
        animator = motion
        motion.addAnimations { content.alpha = 1 }
        motion.addCompletion { [weak self, weak content] _ in
            guard let self, self.revision == token else { return }
            content?.alpha = 1; cover.removeFromSuperview()
            self.cover = nil; self.animator = nil; self.outgoingAnimator = nil; self.destination = nil
        }
        outgoing.startAnimation(); motion.startAnimation(afterDelay: 0.02)
    }

    func cancel() {
        revision += 1
        if animator?.state == .active { animator?.stopAnimation(true) }
        animator = nil
        if outgoingAnimator?.state == .active { outgoingAnimator?.stopAnimation(true) }
        outgoingAnimator = nil
        destination?.alpha = 1; destination = nil
        cover?.removeFromSuperview(); cover = nil
    }
}
