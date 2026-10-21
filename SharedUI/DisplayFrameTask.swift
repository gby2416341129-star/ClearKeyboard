import UIKit
import os

/// Consume the latest value before UIKit commits this update's layers. A result
/// delivered after CADisplayLink dispatch can still join the current update;
/// restarting a paused display link would make it wait for another update.
@MainActor final class DisplayFrameTask {
    private weak var view: UIView?
    private var link: UIUpdateLink?
    private var frameRate = 0
    private var fallbackScheduled = false
    private var generation = 0
    private var action: (() -> Void)?
    private let log = OSLog(subsystem: "app.clear.keyboard", category: .pointsOfInterest)
    func schedule(in view: UIView, maximumFramesPerSecond: Int, _ action: @escaping () -> Void) {
        if self.view !== view {
            cancel(); link = nil; frameRate = 0; self.view = view
        }
        self.action = action
        // A keyboard can be detached while its host replaces or resizes the
        // remote view. No display update is promised without a window; keep
        // document writes and the latest presentation live on the main queue.
        if view.window == nil {
            link?.requiresContinuousUpdates = false; link?.isEnabled = false
            guard !fallbackScheduled else { return }
            fallbackScheduled = true; let revision = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == revision else { return }
                let next = self.action; self.cancel(); next?()
            }
            return
        }
        if link == nil {
            link?.isEnabled = false
            self.view = view; frameRate = 0
            let next = UIUpdateLink(view: view)
            next.addAction(to: .beforeCATransactionCommit) { [weak self] _, info in self?.fire(info) }
            link = next
        }
        let rate = max(1, maximumFramesPerSecond)
        if frameRate != rate {
            frameRate = rate
            let maximum = Float(rate)
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        }
        // Also wake an otherwise idle UI when a worker supplies new words.
        // The request ends as soon as this latest-value task is consumed.
        link?.requiresContinuousUpdates = true
        link?.isEnabled = true
    }
    func cancel() { generation += 1; fallbackScheduled = false; action = nil; link?.requiresContinuousUpdates = false; link?.isEnabled = false }
    private func fire(_ info: UIUpdateInfo) {
        let next = action; cancel()
        let start = CACurrentMediaTime()
        next?()
        // Numeric timing only. A submission deadline is not a measurement of
        // presented FPS; these events let an on-device trace find main-thread
        // overruns without recording the user's spelling or candidate text.
        let end = CACurrentMediaTime()
        os_signpost(.event, log: log, name: "KeyboardSubmission",
            "work_ms=%.3f deadline_remaining_ms=%.3f", (end - start) * 1000, (info.completionDeadlineTime - end) * 1000)
    }
}
