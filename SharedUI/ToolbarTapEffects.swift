import UIKit

/// Short, transparent vector accents. No backdrop, bitmap capture or layout
/// changes; navigation and the original button feedback run immediately.
@MainActor final class ToolbarTapEffects {
    private enum Kind: CaseIterable, Equatable { case fireworks, rings, stars, repel, confetti, orbit, petals, lightning }
    private var previous: [ObjectIdentifier: Kind] = [:]
    private var active: [(layer: CALayer, cleanup: DispatchWorkItem)] = []
    private var nudged: [CALayer] = []
    func play(from source: UIView, in host: UIView, neighbors: [UIView], tint: UIColor) {
        guard host.window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        let key = ObjectIdentifier(source)
        let kind = Kind.allCases.filter { $0 != previous[key] }.randomElement() ?? .fireworks
        if previous.count > 80 { previous.removeAll() }; previous[key] = kind
        while active.count >= 3 {
            let old = active.removeFirst(); old.cleanup.cancel(); old.layer.removeFromSuperlayer()
        }
        let center = source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: host)
        let canvas = CALayer(); canvas.frame = host.bounds; canvas.masksToBounds = true
        host.layer.addSublayer(canvas)
        let colors = [UIColor.systemCyan, .systemPink, .systemYellow, .systemMint, .systemOrange, .systemPurple, tint]
        switch kind {
        case .fireworks, .stars, .confetti, .petals:
            let count = kind == .stars ? 12 : kind == .petals ? 10 : 24
            let phase = CGFloat.random(in: 0 ... .pi * 2)
            for index in 0..<count {
                let angle = phase + CGFloat(index) / CGFloat(count) * .pi * 2
                let distance = CGFloat.random(in: 32...54)
                let spark = CAShapeLayer(); spark.position = center
                spark.fillColor = colors[index % colors.count].resolvedColor(with: host.traitCollection).cgColor
                let side: CGFloat = kind == .stars ? 5 : CGFloat.random(in: 3.5...6)
                if kind == .stars {
                    let path = UIBezierPath(); path.move(to: CGPoint(x: 0, y: -side))
                    for point in [CGPoint(x: side * 0.3, y: -side * 0.3), CGPoint(x: side, y: 0), CGPoint(x: side * 0.3, y: side * 0.3), CGPoint(x: 0, y: side), CGPoint(x: -side * 0.3, y: side * 0.3), CGPoint(x: -side, y: 0), CGPoint(x: -side * 0.3, y: -side * 0.3)] { path.addLine(to: point) }
                    path.close(); spark.path = path.cgPath
                } else if kind == .confetti {
                    spark.path = UIBezierPath(roundedRect: CGRect(x: -side / 2, y: -side, width: side, height: side * 2), cornerRadius: 1).cgPath
                } else if kind == .petals {
                    spark.path = UIBezierPath(ovalIn: CGRect(x: -side / 2, y: -side * 1.5, width: side, height: side * 3)).cgPath
                } else { spark.path = UIBezierPath(ovalIn: CGRect(x: -side / 2, y: -side / 2, width: side, height: side)).cgPath }
                canvas.addSublayer(spark)
                let position = CAKeyframeAnimation(keyPath: "position")
                position.values = [NSValue(cgPoint: center), NSValue(cgPoint: CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)), NSValue(cgPoint: CGPoint(x: center.x + cos(angle) * (distance + 3), y: center.y + sin(angle) * distance + 3))]
                position.keyTimes = [0, 0.6, 1]
                let scale = CAKeyframeAnimation(keyPath: "transform.scale"); scale.values = [0.25, 1.15, 0.45]; scale.keyTimes = [0, 0.18, 1]
                let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [0, 1, 1, 0]; fade.keyTimes = [0, 0.08, 0.46, 1]
                let spin = CABasicAnimation(keyPath: "transform.rotation.z"); spin.fromValue = angle; spin.toValue = angle + (kind == .confetti ? 5 : 1.5)
                run([position, scale, fade, spin], on: spark, duration: 0.68, host: host)
            }
        case .rings, .repel:
            for index in 0..<(kind == .rings ? 3 : 1) {
                let ring = CAShapeLayer(); ring.position = center
                ring.path = UIBezierPath(ovalIn: CGRect(x: -12, y: -12, width: 24, height: 24)).cgPath
                ring.fillColor = UIColor.clear.cgColor; ring.strokeColor = colors[index].resolvedColor(with: host.traitCollection).cgColor
                ring.lineWidth = index == 0 ? 2.6 : 1.8; canvas.addSublayer(ring)
                let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 0.65; scale.toValue = index == 0 ? 3.0 : 2.5 - Double(index) * 0.35
                let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
                run([scale, fade], on: ring, duration: 0.64, host: host)
            }
            if kind == .repel {
                for neighbor in neighbors where neighbor !== source {
                    let other = neighbor.convert(CGPoint(x: neighbor.bounds.midX, y: neighbor.bounds.midY), to: host)
                    let distance = other.x - center.x
                    guard abs(distance) > 5, abs(distance) < 100 else { continue }
                    let layer = neighbor.subviews.first(where: { $0 is ToolIconView })?.layer ?? neighbor.layer
                    let nudge = CAKeyframeAnimation(keyPath: "transform.translation.x")
                    let current = layer.presentation()?.transform.m41 ?? 0
                    nudge.values = [current, (distance < 0 ? -1 : 1) * (abs(distance) < 60 ? 10.0 : 5.0), 0]
                    nudge.keyTimes = [0, 0.28, 1]; nudge.duration = 0.34
                    nudge.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
                    layer.add(nudge, forKey: "toolbar.tap.nudge"); nudged.append(layer)
                }
            }
        case .orbit:
            for index in 0..<10 {
                let angle = CGFloat(index) * .pi / 5
                let comet = CAShapeLayer(); comet.fillColor = colors[index % colors.count].cgColor
                comet.path = UIBezierPath(ovalIn: CGRect(x: -2.8, y: -2.8, width: 5.6, height: 5.6)).cgPath
                canvas.addSublayer(comet)
                let path = UIBezierPath()
                for step in 0...32 {
                    let t = CGFloat(step) / 32, radius = 12 + t * 33, a = angle + t * .pi * 1.25
                    let point = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                let motion = CAKeyframeAnimation(keyPath: "position"); motion.path = path.cgPath
                let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [0, 1, 1, 0]; fade.keyTimes = [0, 0.1, 0.6, 1]
                run([motion, fade], on: comet, duration: 0.72, host: host)
            }
        case .lightning:
            for index in 0..<7 {
                let angle = CGFloat(index) / 7 * .pi * 2
                let path = UIBezierPath(); path.move(to: center)
                for step in 1...4 {
                    let radius = CGFloat(step) * 11, twist = angle + (step % 2 == 0 ? -0.15 : 0.15)
                    path.addLine(to: CGPoint(x: center.x + cos(twist) * radius, y: center.y + sin(twist) * radius))
                }
                let bolt = CAShapeLayer(); bolt.path = path.cgPath; bolt.fillColor = UIColor.clear.cgColor
                bolt.strokeColor = colors[index % colors.count].cgColor; bolt.lineWidth = 2.2; bolt.lineCap = .round
                canvas.addSublayer(bolt)
                let draw = CABasicAnimation(keyPath: "strokeEnd"); draw.fromValue = 0; draw.toValue = 1
                let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [0, 1, 1, 0]; fade.keyTimes = [0, 0.07, 0.42, 1]
                run([draw, fade], on: bolt, duration: 0.6, host: host)
            }
        }
        let cleanup = DispatchWorkItem { [weak self, weak canvas] in
            canvas?.removeFromSuperlayer()
            self?.active.removeAll { $0.layer === canvas }
            self?.nudged.removeAll { $0.animation(forKey: "toolbar.tap.nudge") == nil }
        }
        active.append((canvas, cleanup)); DispatchQueue.main.asyncAfter(deadline: .now() + 0.78, execute: cleanup)
    }
    private func run(_ animations: [CAAnimation], on layer: CALayer, duration: CFTimeInterval, host: UIView) {
        for animation in animations { animation.duration = duration }
        let group = CAAnimationGroup(); group.animations = animations; group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let rate = Float(host.window?.screen.maximumFramesPerSecond ?? 60)
        group.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
        group.isRemovedOnCompletion = false; group.fillMode = .forwards
        layer.add(group, forKey: "toolbar.tap.accent")
    }
    func cancel() {
        for item in active { item.cleanup.cancel(); item.layer.removeFromSuperlayer() }; active.removeAll()
        for layer in nudged { layer.removeAnimation(forKey: "toolbar.tap.nudge") }; nudged.removeAll()
    }
}
