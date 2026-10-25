import UIKit

/// Keep the last displayed body visible while its destination is laid out.
/// UIKit's render-server snapshot also captures an interrupted crossfade, so
/// a second tap starts at the image on screen instead of restarting a page.
@MainActor final class KeyboardPanelTransition {
    private var cover: UIView?
    private weak var destination: UIView?
    private var animator: UIViewPropertyAnimator?
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
        let timing = UICubicTimingParameters(controlPoint1: CGPoint(x: 0.2, y: 0),
                                             controlPoint2: CGPoint(x: 0, y: 1))
        let motion = UIViewPropertyAnimator(duration: 0.24, timingParameters: timing)
        animator = motion
        motion.addAnimations { content.alpha = 1; cover.alpha = 0 }
        motion.addCompletion { [weak self, weak content] _ in
            guard let self, self.revision == token else { return }
            content?.alpha = 1; cover.removeFromSuperview()
            self.cover = nil; self.animator = nil; self.destination = nil
        }
        motion.startAnimation()
    }

    func cancel() {
        revision += 1
        animator?.stopAnimation(true); animator = nil
        destination?.alpha = 1; destination = nil
        cover?.removeFromSuperview(); cover = nil
    }
}
