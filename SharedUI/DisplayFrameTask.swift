import UIKit

/// One latest-value task at the screen's next display opportunity. A weak
/// target avoids retaining a keyboard/view through the run loop's display link.
@MainActor final class DisplayFrameTask {
    @MainActor private final class Target: NSObject {
        weak var owner: DisplayFrameTask?
        @objc func tick(_ link: CADisplayLink) { owner?.fire() }
    }
    private let target = Target()
    private var link: CADisplayLink?
    private var frameRate = 0
    private var action: (() -> Void)?
    func schedule(maximumFramesPerSecond: Int, _ action: @escaping () -> Void) {
        self.action = action
        if link == nil {
            target.owner = self
            let next = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
            next.add(to: .main, forMode: .common); link = next
        }
        let rate = max(1, maximumFramesPerSecond)
        if frameRate != rate {
            frameRate = rate
            let maximum = Float(rate)
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        }
        link?.isPaused = false
    }
    func cancel() { action = nil; link?.isPaused = true }
    private func fire() {
        let next = action; action = nil; link?.isPaused = true
        next?()
    }
    deinit { link?.invalidate() }
}
