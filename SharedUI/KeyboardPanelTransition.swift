import UIKit

/// Panel motion never installs a backdrop material or a full-panel bitmap.
/// Keeping the continuous keyboard background unchanged avoids white flashes
/// and dark gaps while a panel settles into place.
@MainActor final class KeyboardPanelTransition {
    private weak var destination: UIView?
    private var animator: UIViewPropertyAnimator?
    private var enabled = false
    var isAnimating: Bool { animator?.isRunning == true }
    func begin(in host: UIView, region: CGRect, animated: Bool = true) {
        cancel()
        enabled = animated && host.window != nil && UIView.areAnimationsEnabled &&
            !UIAccessibility.isReduceMotionEnabled && !region.isEmpty
    }
    func finish(to content: UIView, in host: UIView) {
        content.alpha = 1; content.transform = .identity; content.isUserInteractionEnabled = true
        guard enabled else { return }; enabled = false
        destination = content
        content.transform = CGAffineTransform(translationX: 0, y: 6)
        let motion = UIViewPropertyAnimator(duration: 0.26, dampingRatio: 0.92) { content.transform = .identity }
        animator = motion
        motion.addCompletion { [weak self, weak content] _ in
            guard self?.destination === content else { return }
            content?.transform = .identity; content?.alpha = 1
            self?.destination = nil; self?.animator = nil
        }
        motion.startAnimation()
    }
    func cancel() {
        animator?.stopAnimation(true); animator = nil
        destination?.alpha = 1; destination?.transform = .identity; destination = nil; enabled = false
    }
}
