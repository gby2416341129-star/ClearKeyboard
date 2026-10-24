import XCTest
import UIKit

@MainActor final class CandidateAnimationRuntimeTests: XCTestCase {
    private weak var previousKeyWindow: UIWindow?
    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    private func ink(_ view: UIView) throws -> UILabel {
        try XCTUnwrap(views(view).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "candidate.currentInk" })
    }
    private func context(_ raw: String = "ni") -> KeyboardModel.CandidateContext {
        KeyboardModel.CandidateContext(raw: raw, before: raw, after: "", document: "animation-fixture", language: .chinese)
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "The latest candidate frame must arrive without an animation delay")
    }
    private func row() -> (UIWindow, CandidateScrollView) {
        let window: UIWindow
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first {
            previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene)
        } else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 120)) }
        window.overrideUserInterfaceStyle = .dark
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(white: 0.13, alpha: 1)
        window.rootViewController = controller
        let ribbon = CandidateScrollView(); ribbon.frame = CGRect(x: 12, y: 10, width: 350, height: 44)
        controller.view.addSubview(ribbon)
        window.makeKeyAndVisible(); controller.view.layoutIfNeeded()
        CATransaction.flush()
        return (window, ribbon)
    }
    private func close(_ window: UIWindow) {
        window.isHidden = true
        previousKeyWindow?.makeKey()
    }
    private func button(_ row: CandidateScrollView, at index: Int = 0) -> CandidateButton? {
        views(row).compactMap { $0 as? CandidateButton }.first { $0.tag == index && !$0.isHidden }
    }
    private func waitForSettledInk(in ribbon: CandidateScrollView, completedFrames: () -> Int,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        // Query CA after real completed UI updates. Sleeping or manually
        // flushing a snapshot transaction is not a render-server barrier and
        // can leave an old animation copy visible to animation(forKey:).
        let started = CACurrentMediaTime(), deadline = started + 2
        let firstFrame = completedFrames()
        var checkedFrame = firstFrame
        while CACurrentMediaTime() < deadline {
            let frame = completedFrames()
            guard frame > checkedFrame else {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            checkedFrame = frame
            let controls = views(ribbon).compactMap { $0 as? CandidateButton }.filter { !$0.isHidden }
            if !controls.isEmpty, controls.allSatisfy({ control in
                guard let label = try? ink(control) else { return false }
                return label.layer.animation(forKey: "candidateText") == nil &&
                    label.layer.animation(forKey: "candidateTextPosition") == nil
            }) {
                print("CANDIDATE_ANIMATION_SETTLED observedRemoval=true completed_frames=\(frame - firstFrame) wait_ms=\((CACurrentMediaTime() - started) * 1000)")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        print("CANDIDATE_ANIMATION_CLOCK completed_frames=\(completedFrames() - firstFrame) appState=\(UIApplication.shared.applicationState.rawValue) sceneState=\(ribbon.window?.windowScene?.activationState.rawValue ?? -1) keyWindow=\(ribbon.window?.isKeyWindow == true) hidden=\(ribbon.window?.isHidden ?? true)")
        for control in views(ribbon).compactMap({ $0 as? CandidateButton }).filter({ !$0.isHidden }) {
            let label = try ink(control), now = CACurrentMediaTime()
            for key in ["candidateText", "candidateTextPosition"] {
                if let animation = label.layer.animation(forKey: key) {
                    print("CANDIDATE_ANIMATION_CLOCK key=\(key) now=\(now) localNow=\(label.layer.convertTime(now, from: nil)) begin=\(animation.beginTime) duration=\(animation.duration) removedOnCompletion=\(animation.isRemovedOnCompletion) presentationOpacity=\(label.layer.presentation()?.opacity ?? -1)")
                }
            }
            var layer: CALayer? = label.layer
            while let current = layer {
                print("CANDIDATE_LAYER_CLOCK speed=\(current.speed) offset=\(current.timeOffset) begin=\(current.beginTime) hidden=\(current.isHidden)")
                layer = current.superlayer
            }
        }
        XCTFail("Committed candidate animations did not complete in the active window", file: file, line: line)
    }
    func testNewInkIsReadableImmediatelyWithoutOldWordOverprint() throws {
        let button = CandidateButton(frame: CGRect(x: 0, y: 0, width: 240, height: 44))
        let font = UIFont.systemFont(ofSize: 19)
        button.configure(Candidate(text: "上一条候选", consumed: 2), first: true, accent: .systemBlue, font: font)
        button.configure(Candidate(text: "你今天吃饭了吗", consumed: 7), first: true, accent: .systemBlue,
                         font: font, animate: true, reduceMotion: false)
        let label = try ink(button)
        XCTAssertEqual(label.text, "你今天吃饭了吗")
        XCTAssertEqual(label.layer.opacity, 1, "The model layer must already hold readable latest ink")
        XCTAssertEqual(views(button).compactMap { $0 as? UILabel }.count, 1, "No old sentence may show through the new sentence")
        let fade = try XCTUnwrap(label.layer.animation(forKey: "candidateText") as? CABasicAnimation)
        let settle = try XCTUnwrap(label.layer.animation(forKey: "candidateTextPosition") as? CABasicAnimation)
        XCTAssertGreaterThanOrEqual((fade.fromValue as? NSNumber)?.doubleValue ?? 0, 0.9)
        XCTAssertGreaterThan(fade.duration, 0); XCTAssertLessThanOrEqual(fade.duration, 0.18)
        XCTAssertEqual(settle.beginTime, fade.beginTime); XCTAssertEqual(settle.duration, fade.duration)
        XCTAssertEqual((settle.toValue as? NSNumber)?.doubleValue, 0)
        XCTAssertLessThanOrEqual((settle.fromValue as? NSNumber)?.doubleValue ?? 100, 2)
        XCTAssertTrue(CATransform3DIsIdentity(button.layer.transform), "Hit geometry must never animate")
        button.configure(Candidate(text: "候选文字大小", consumed: 6), first: true, accent: .systemBlue,
                         font: .systemFont(ofSize: 25), animate: false)
        button.layoutIfNeeded()
        XCTAssertTrue(label.superview === button, "The smaller highlight must not clip large animated glyphs")
        XCTAssertGreaterThanOrEqual((label.bounds.height - label.font.lineHeight) / 2, 2)
    }
    func testRapidResultsShareOneClockAndKeepLatestTextAndExactHitGeometry() throws {
        let button = CandidateButton(frame: CGRect(x: 8, y: 0, width: 260, height: 44))
        let font = UIFont.systemFont(ofSize: 19), originalFrame = button.frame
        button.configure(Candidate(text: "你", consumed: 1), first: true, accent: .systemBlue, font: font, animate: true, reduceMotion: false)
        let label = try ink(button)
        let first = try XCTUnwrap(label.layer.animation(forKey: "candidateText") as? CABasicAnimation)
        for text in ["你今", "你今天", "你今天吃饭", "你今天吃饭了吗", "hello"] {
            button.configure(Candidate(text: text, consumed: text.count), first: true, accent: .systemBlue,
                             font: font, animate: true, reduceMotion: false)
            let current = try XCTUnwrap(label.layer.animation(forKey: "candidateText") as? CABasicAnimation)
            let position = try XCTUnwrap(label.layer.animation(forKey: "candidateTextPosition") as? CABasicAnimation)
            XCTAssertEqual(current.beginTime, first.beginTime); XCTAssertEqual(current.duration, first.duration)
            XCTAssertEqual(position.beginTime, first.beginTime)
            XCTAssertEqual(label.text, text); XCTAssertEqual(button.frame, originalFrame)
            XCTAssertEqual(views(button).compactMap { $0 as? UILabel }.count, 1)
        }
        let previousDeadline = button.transitionDeadline
        button.finishTransition()
        button.configure(Candidate(text: "下一次输入", consumed: 5), first: true, accent: .systemBlue,
                         font: font, animate: true, reduceMotion: false)
        let next = try XCTUnwrap(label.layer.animation(forKey: "candidateText"))
        // Deliver a stale completion deterministically. A wall-clock sleep
        // can resume after the newer burst has naturally finished on a busy
        // simulator, which cannot establish premature cancellation.
        button.finishTransition(matching: previousDeadline)
        XCTAssertEqual(label.layer.animation(forKey: "candidateText")?.beginTime, next.beginTime,
                       "A cancelled prior deadline must not settle a newer burst early")
        button.finishTransition(matching: button.transitionDeadline)
        XCTAssertNil(label.layer.animation(forKey: "candidateText"))
        XCTAssertNil(label.layer.animation(forKey: "candidateTextPosition"))
        XCTAssertEqual(label.text, "下一次输入"); XCTAssertEqual(button.frame, originalFrame)
    }
    func testOnlyFirstInkHasASmallSpringWithoutChangingTheBurstDeadlineOrTargets() throws {
        let button = CandidateButton(frame: CGRect(x: 8, y: 0, width: 240, height: 44))
        let font = UIFont.systemFont(ofSize: 19), frame = button.frame
        button.configure(Candidate(text: "你", consumed: 2), first: true, accent: .systemBlue,
                         font: font, animate: true, reduceMotion: false, voiceOver: false, firstAppearance: true)
        button.layoutIfNeeded()
        let label = try ink(button)
        let spring = try XCTUnwrap(label.layer.animation(forKey: "candidateTextPosition") as? CASpringAnimation)
        let fade = try XCTUnwrap(label.layer.animation(forKey: "candidateText") as? CABasicAnimation)
        XCTAssertEqual(spring.duration, 0.18, accuracy: 0.0001)
        XCTAssertEqual(spring.beginTime, fade.beginTime); XCTAssertEqual(spring.duration, fade.duration)
        let amplitude = try XCTUnwrap(spring.fromValue as? NSNumber).doubleValue
        let frequency = sqrt(spring.stiffness / spring.mass)
        let dampingRatio = spring.damping / (2 * sqrt(spring.stiffness * spring.mass))
        XCTAssertGreaterThan(dampingRatio, 0); XCTAssertLessThan(dampingRatio, 1)
        let overshoot = amplitude * exp(-Double.pi * dampingRatio / sqrt(1 - dampingRatio * dampingRatio))
        let finalEnvelope = amplitude * exp(-dampingRatio * frequency * spring.duration) / sqrt(1 - dampingRatio * dampingRatio)
        XCTAssertGreaterThan(overshoot, 0, "First appearance should have a small, single rebound")
        XCTAssertLessThan(overshoot, 0.3, "The rebound must stay smaller than one pixel on a 3x screen")
        XCTAssertLessThan(finalEnvelope, 0.002, "The fixed deadline must not truncate visible spring travel")
        XCTAssertEqual(button.frame, frame); XCTAssertTrue(CATransform3DIsIdentity(button.layer.transform))
        XCTAssertEqual(label.text, "你"); XCTAssertEqual(label.layer.opacity, 1)
        XCTAssertGreaterThanOrEqual((fade.fromValue as? NSNumber)?.doubleValue ?? 0, 0.96,
            "First ink must remain readable throughout its spring")
        for face in button.subviews where face !== label { XCTAssertNil(face.layer.animationKeys()) }
        button.configure(Candidate(text: "你今天", consumed: 7), first: true, accent: .systemBlue,
                         font: font, animate: true, reduceMotion: false, voiceOver: false)
        let continued = try XCTUnwrap(label.layer.animation(forKey: "candidateTextPosition") as? CASpringAnimation)
        XCTAssertEqual(continued.beginTime, spring.beginTime); XCTAssertEqual(continued.duration, spring.duration)
        button.finishTransition()
        button.configure(Candidate(text: "你今天吃饭了吗", consumed: 12), first: true, accent: .systemBlue,
                         font: font, animate: true, reduceMotion: false, voiceOver: false)
        let replacement = try XCTUnwrap(label.layer.animation(forKey: "candidateTextPosition") as? CABasicAnimation)
        XCTAssertFalse(replacement is CASpringAnimation, "A later result must not launch another rebound")
        XCTAssertEqual(replacement.duration, 0.18, accuracy: 0.0001)
        let replacementOpacity = try XCTUnwrap(label.layer.animation(forKey: "candidateText") as? CABasicAnimation)
        XCTAssertEqual((replacementOpacity.fromValue as? NSNumber)?.doubleValue, 1,
            "Repeated decoder updates must not make readable words flash")
        XCTAssertEqual(button.frame, frame); XCTAssertEqual(views(button).compactMap { $0 as? UILabel }.count, 1)
    }
    func testAnEmptyRowReusesItsInkButGetsOneFreshAppearanceSpring() async throws {
        if UIAccessibility.isReduceMotionEnabled || UIAccessibility.isVoiceOverRunning {
            throw XCTSkip("Accessibility intentionally disables candidate movement")
        }
        let (window, ribbon) = row(); defer { close(window) }
        let word = Candidate(text: "你好", consumed: 5), query = context("nihao")
        ribbon.update([word], context: query, arithmetic: false, accent: .systemBlue)
        try await waitFor { self.button(ribbon)?.accessibilityIdentifier == "candidate.你好" }
        let reused = try XCTUnwrap(button(ribbon)), label = try ink(reused), frame = reused.frame
        XCTAssertNotNil(label.layer.animation(forKey: "candidateTextPosition") as? CASpringAnimation)
        ribbon.update([], context: context(""), arithmetic: false, accent: .systemBlue)
        try await waitFor { ribbon.accessibilityValue == "offset:0;count:0" }
        XCTAssertTrue(reused.isHidden); XCTAssertEqual(label.text, word.text)
        XCTAssertNil(label.layer.animationKeys())
        // Even the same word must appear again. Its pooled label intentionally
        // retains old text, so oldText alone cannot identify a fresh appearance.
        ribbon.update([word], context: query, arithmetic: false, accent: .systemBlue)
        try await waitFor { self.button(ribbon)?.accessibilityIdentifier == "candidate.你好" }
        XCTAssertTrue(button(ribbon) === reused); XCTAssertEqual(reused.frame, frame)
        let spring = try XCTUnwrap(label.layer.animation(forKey: "candidateTextPosition") as? CASpringAnimation)
        XCTAssertEqual(spring.duration, 0.18, accuracy: 0.0001)
        ribbon.update([Candidate(text: "你好吗", consumed: 6)], context: context("nihaom"), arithmetic: false, accent: .systemBlue)
        try await waitFor { self.button(ribbon)?.accessibilityIdentifier == "candidate.你好吗" }
        let continued = try XCTUnwrap(label.layer.animation(forKey: "candidateTextPosition") as? CABasicAnimation)
        if continued is CASpringAnimation {
            XCTAssertEqual(continued.beginTime, spring.beginTime); XCTAssertEqual(continued.duration, spring.duration)
        } else {
            XCTAssertGreaterThanOrEqual(label.layer.convertTime(CACurrentMediaTime(), from: nil), spring.beginTime + spring.duration,
                                        "Only an already-finished burst may start a quiet replacement")
        }
        ribbon.scrollViewWillBeginDragging(ribbon)
        XCTAssertNil(label.layer.animationKeys(), "A finger must still settle reused ink immediately")
        let words = (0..<35).map { Candidate(text: "候选\($0)", consumed: 6) }
        ribbon.update(words, context: context("nihaom"), arithmetic: false, accent: .systemBlue)
        try await waitFor { ribbon.accessibilityValue == "offset:0;count:36" }
        for control in views(ribbon).compactMap({ $0 as? CandidateButton }).filter({ !$0.isHidden }) {
            let currentInk = try ink(control)
            XCTAssertNil(currentInk.layer.animation(forKey: "candidateText"))
            XCTAssertNil(currentInk.layer.animation(forKey: "candidateTextPosition"),
                         "An appended page must stay still throughout browsing, including after finger-up")
            XCTAssertEqual(currentInk.layer.opacity, 1)
            XCTAssertTrue(CATransform3DIsIdentity(currentInk.layer.transform))
        }
        ribbon.contentOffset.x = 140; ribbon.layoutIfNeeded()
        for control in views(ribbon).compactMap({ $0 as? CandidateButton }).filter({ !$0.isHidden }) {
            let currentInk = try ink(control)
            XCTAssertNil(currentInk.layer.animation(forKey: "candidateText"))
            XCTAssertNil(currentInk.layer.animation(forKey: "candidateTextPosition"),
                         "A scrolling pool reuse must not start a spring or a replacement settle")
            XCTAssertEqual(currentInk.layer.opacity, 1)
            XCTAssertTrue(CATransform3DIsIdentity(currentInk.layer.transform))
        }
    }
    func testVoiceOverSettlesActiveInkAndKeepsNewResultsStable() throws {
        let button = CandidateButton(frame: CGRect(x: 0, y: 0, width: 160, height: 44))
        let font = UIFont.systemFont(ofSize: 19), word = Candidate(text: "你好", consumed: 5)
        button.configure(word, first: true, accent: .systemBlue, font: font, animate: true,
                         reduceMotion: false, voiceOver: false)
        let label = try ink(button)
        XCTAssertNotNil(label.layer.animation(forKey: "candidateTextPosition"))
        button.configure(word, first: true, accent: .systemBlue, font: font, animate: true,
                         reduceMotion: false, voiceOver: true)
        XCTAssertNil(label.layer.animationKeys(), "Enabling VoiceOver must settle even unchanged ink")
        button.configure(Candidate(text: "你今天", consumed: 7), first: true, accent: .systemBlue, font: font,
                         animate: true, reduceMotion: false, voiceOver: true)
        XCTAssertNil(label.layer.animationKeys()); XCTAssertEqual(label.text, "你今天")
        XCTAssertEqual(label.layer.opacity, 1); XCTAssertTrue(CATransform3DIsIdentity(label.layer.transform))
    }
    func testReduceMotionSettlesAnUnchangedWordAndNeverStartsAnotherTransition() throws {
        let button = CandidateButton(frame: CGRect(x: 0, y: 0, width: 160, height: 44))
        let font = UIFont.systemFont(ofSize: 19), word = Candidate(text: "你好", consumed: 5)
        button.configure(word, first: true, accent: .systemBlue, font: font, animate: true, reduceMotion: false)
        let label = try ink(button)
        XCTAssertNotNil(label.layer.animation(forKey: "candidateText"))
        button.configure(word, first: true, accent: .systemBlue, font: font, animate: true, reduceMotion: true)
        XCTAssertNil(label.layer.animation(forKey: "candidateText")); XCTAssertNil(label.layer.animation(forKey: "candidateTextPosition"))
        button.configure(Candidate(text: "hello", consumed: 5), first: true, accent: .systemBlue,
                         font: font, animate: true, reduceMotion: true)
        XCTAssertEqual(label.text, "hello"); XCTAssertNil(label.layer.animationKeys())
        XCTAssertEqual(label.layer.opacity, 1); XCTAssertTrue(CATransform3DIsIdentity(label.layer.transform))
    }
    func testIntermediateEmptyAndSupersededRowsCoalesceWithoutHidingTheCurrentInk() async throws {
        let (window, ribbon) = row(); defer { close(window) }
        ribbon.update([Candidate(text: "你", consumed: 2)], context: context(), arithmetic: false, accent: .systemBlue)
        try await waitFor { self.button(ribbon)?.accessibilityIdentifier == "candidate.你" }
        let original = try XCTUnwrap(button(ribbon)); let currentInk = try ink(original)
        let latest = context("nijintian")
        ribbon.update([], context: latest, arithmetic: false, accent: .systemBlue)
        ribbon.update([Candidate(text: "你今", consumed: 4)], context: latest, arithmetic: false, accent: .systemBlue)
        ribbon.update([Candidate(text: "你今天", consumed: 8)], context: latest, arithmetic: false, accent: .systemBlue)
        XCTAssertFalse(original.isHidden); XCTAssertEqual(currentInk.text, "你")
        XCTAssertEqual(currentInk.layer.opacity, 1)
        try await waitFor { self.button(ribbon)?.accessibilityIdentifier == "candidate.你今天" }
        XCTAssertTrue(button(ribbon) === original, "A new word reuses its visible control instead of hiding and rebuilding the row")
        XCTAssertEqual(ribbon.accessibilityValue, "offset:0;count:1")
        var selected: (String, KeyboardModel.CandidateContext?)?
        ribbon.onSelect = { candidate, context, _ in selected = (candidate.text, context) }
        ribbon.selectCandidate(at: CGPoint(x: original.frame.midX, y: 22))
        XCTAssertEqual(selected?.0, "你今天"); XCTAssertEqual(selected?.1, latest)
        XCTAssertNil(currentInk.layer.animationKeys(), "Contact must settle ink immediately without delaying selection")
        ribbon.update([], context: context("unknown"), arithmetic: false, accent: .systemBlue)
        try await waitFor { ribbon.accessibilityValue == "offset:0;count:0" }
        XCTAssertNil(button(ribbon), "A genuine empty result must still clear obsolete, unselectable words")
    }
    func testAppendingWhileBrowsingKeepsControlPositionsOffsetAndSelectableContext() async throws {
        let (window, ribbon) = row(); defer { close(window) }
        let query = context("ni")
        let values = (0..<35).map { Candidate(text: "候选\($0)", consumed: 2) }
        ribbon.update(values, context: query, arithmetic: false, accent: .systemBlue)
        try await waitFor { ribbon.accessibilityValue == "offset:0;count:35" }
        ribbon.layoutIfNeeded(); ribbon.contentOffset = CGPoint(x: 140, y: 0); ribbon.layoutIfNeeded()
        ribbon.scrollViewWillBeginDragging(ribbon)
        let offset = ribbon.contentOffset
        let controls = views(ribbon).compactMap { $0 as? CandidateButton }.filter { !$0.isHidden }
        let positions = controls.map { ($0, $0.tag, $0.frame) }
        ribbon.update([values[1], values[0]] + Array(values.dropFirst(2)) + [Candidate(text: "新增", consumed: 2)],
                      context: query, arithmetic: false, accent: .systemBlue)
        try await waitFor { ribbon.accessibilityValue == "offset:140;count:36" }
        XCTAssertEqual(ribbon.contentOffset, offset)
        for (control, index, frame) in positions where !control.isHidden {
            XCTAssertEqual(control.tag, index); XCTAssertEqual(control.frame, frame)
            XCTAssertEqual(control.accessibilityIdentifier, "candidate." + values[index].text)
            XCTAssertNil(try ink(control).layer.animationKeys())
        }
        var selected: String?
        ribbon.onSelect = { candidate, context, _ in selected = candidate.text; XCTAssertEqual(context, query) }
        let target = try XCTUnwrap(positions.first { ribbon.bounds.contains(CGPoint(x: $0.2.midX, y: 22)) })
        ribbon.selectCandidate(at: CGPoint(x: target.2.midX, y: 22))
        XCTAssertEqual(selected, values[target.1].text)
    }
    func testCandidateHandoffVisualSamplesAndSettledInk() async throws {
        let (window, ribbon) = row(); defer { close(window) }
        // The production row submits changes before CA commit and then stops
        // its update request. This fixture explicitly observes completed frames
        // while taking snapshots; it never finishes or removes the animations.
        var completedFrames = 0
        let updates = UIUpdateLink(view: ribbon)
        updates.addAction(to: .afterUpdateComplete) { _, _ in completedFrames += 1 }
        updates.requiresContinuousUpdates = true; updates.isEnabled = true
        defer { updates.requiresContinuousUpdates = false; updates.isEnabled = false }
        var samples: [(String, UIImage)] = []
        func capture(_ title: String) async throws {
            let before = completedFrames, deadline = CACurrentMediaTime() + 2
            while completedFrames <= before && CACurrentMediaTime() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertGreaterThan(completedFrames, before, "A snapshot requires a completed UI update, not only a changed model label")
            ribbon.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: ribbon.bounds.size).image { context in
                UIColor(white: 0.13, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: ribbon.bounds.size))
                XCTAssertTrue(ribbon.drawHierarchy(in: CGRect(origin: .zero, size: ribbon.bounds.size), afterScreenUpdates: true))
            }
            if samples.isEmpty, let bitmap = image.cgImage {
                // A model-side identifier is not proof of displayed ink. The
                // first sample must include blue glyph pixels, not an old empty
                // render. This asserts a rendered sample, not physical latency.
                let width = bitmap.width, height = bitmap.height
                var pixels = [UInt8](repeating: 0, count: width * height * 4)
                let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
                    guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                    context.draw(bitmap, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))); return true
                }
                XCTAssertTrue(drawn)
                var bluePixels = 0
                for offset in stride(from: 0, to: pixels.count, by: 4) {
                    if pixels[offset] < 130 && pixels[offset + 1] < 210 && pixels[offset + 2] > 170 &&
                        Int(pixels[offset + 2]) > Int(pixels[offset]) + 60 { bluePixels += 1 }
                }
                XCTAssertGreaterThan(bluePixels, 10, "The first visual sample must actually contain the first candidate's ink")
            }
            samples.append((title, image))
        }
        ribbon.update(["你", "呢", "拟", "泥"].map { Candidate(text: $0, consumed: 2) }, context: context(), arithmetic: false, accent: .systemBlue)
        try await waitFor { self.button(ribbon)?.accessibilityIdentifier == "candidate.你" }
        try await capture("首次候选 / 清晰显示")
        ribbon.update(["你今天", "你已经", "你在"].map { Candidate(text: $0, consumed: 4) }, context: context("nijint"), arithmetic: false, accent: .systemBlue)
        try await waitFor { self.button(ribbon)?.accessibilityIdentifier == "candidate.你今天" }
        try await capture("文字交接 / 无旧字叠印")
        ribbon.update([Candidate(text: "你今天吃饭了吗", consumed: 10), Candidate(text: "你今天", consumed: 6)], context: context("nijtchiflm"), arithmetic: false, accent: .systemBlue)
        try await waitFor { self.button(ribbon)?.accessibilityIdentifier == "candidate.你今天吃饭了吗" }
        try await capture("快速输入 / 最新结果立即可选")
        try await waitForSettledInk(in: ribbon, completedFrames: { completedFrames })
        try await capture("收稳 / 字形完整且位置固定")
        for control in views(ribbon).compactMap({ $0 as? CandidateButton }).filter({ !$0.isHidden }) {
            let label = try ink(control)
            XCTAssertNil(label.layer.animation(forKey: "candidateText")); XCTAssertNil(label.layer.animation(forKey: "candidateTextPosition"))
            XCTAssertEqual(label.layer.opacity, 1); XCTAssertTrue(CATransform3DIsIdentity(label.layer.transform))
        }
        let sheet = UIGraphicsImageRenderer(size: CGSize(width: 390, height: CGFloat(samples.count) * 92)).image { context in
            UIColor(white: 0.09, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 390, height: CGFloat(samples.count) * 92))
            for (index, sample) in samples.enumerated() {
                let y = CGFloat(index) * 92
                (sample.0 as NSString).draw(at: CGPoint(x: 14, y: y + 10), withAttributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.white])
                sample.1.draw(in: CGRect(x: 14, y: y + 35, width: 350, height: 44))
            }
        }
        let attachment = XCTAttachment(image: sheet); attachment.name = "Candidate-animation-handoff-contact-sheet"
        attachment.lifetime = .keepAlways; add(attachment)
        print("CANDIDATE_ANIMATION_VISUAL_SAMPLES count=4 latestWordsImmediate=true noOldWordOverprint=true physicalFrameRateMeasured=false")
    }
}
