import UIKit

/// The base choice is aligned to the held key after edge fitting. Both relative
/// sliding below and direct pointing inside the popup share the same selection.
final class KeyChoicePopup: UIView {
    let choices: [String]
    private(set) var selectedIndex: Int
    private let glass = LiquidGlassView(radius: 15)
    private let selection = UIView()
    private let labels: [CenteredKeyLabel]
    private let cellWidth: CGFloat
    private let initialIndex: Int
    private let origin: CGPoint
    init(choices values: [String], initial: Int, origin: CGPoint, anchor: CGRect, host: UIView, accent: UIColor) {
        self.origin = origin
        cellWidth = min(48, max(24, (host.bounds.width - 20) / CGFloat(values.count)))
        let width = cellWidth * CGFloat(values.count) + 8
        let idealX = anchor.midX - (CGFloat(initial) + 0.5) * cellWidth - 4
        let x = min(max(6, idealX), max(6, host.bounds.width - width - 6))
        let slot = min(values.count - 1, max(0, Int(((origin.x - x - 4) / cellWidth - 0.5).rounded())))
        var fitted = values
        let base = fitted.remove(at: initial); fitted.insert(base, at: slot)
        choices = fitted; initialIndex = slot; selectedIndex = slot
        labels = fitted.map { text in
            let label = CenteredKeyLabel(); label.text = text
            label.font = .systemFont(ofSize: 25); label.textAlignment = .center; return label
        }
        super.init(frame: CGRect(x: x, y: max(2, anchor.minY - 62), width: width, height: 56))
        isUserInteractionEnabled = false; accessibilityIdentifier = "key.alternatives"
        isAccessibilityElement = true; accessibilityLabel = fitted.joined(separator: "  ")
        addSubview(glass); glass.frame = bounds
        selection.backgroundColor = accent; selection.layer.cornerRadius = 11
        addSubview(selection); labels.forEach(addSubview); updateSelection(slot)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func update(at point: CGPoint) {
        let index: Int
        if point.y <= frame.maxY + 5 {
            index = Int(floor((point.x - frame.minX - 4) / cellWidth))
        } else {
            index = initialIndex + Int(((point.x - origin.x) / cellWidth).rounded())
        }
        updateSelection(min(choices.count - 1, max(0, index)))
        alpha = point.y > origin.y + 90 || point.y < frame.minY - 65 ? 0.35 : 1
    }
    var selectedValue: String? { alpha < 1 ? nil : choices[selectedIndex] }
    private func updateSelection(_ index: Int) {
        selectedIndex = index; accessibilityValue = choices[index]
        for (i, label) in labels.enumerated() {
            label.frame = CGRect(x: 4 + CGFloat(i) * cellWidth, y: 4, width: cellWidth, height: 48)
            label.textColor = i == index ? .white : .label
        }
        selection.frame = labels[index].frame.insetBy(dx: 2, dy: 2)
    }
}
