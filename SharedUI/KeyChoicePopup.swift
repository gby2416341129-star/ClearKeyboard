import UIKit

/// A single reusable geometry for pinyin case, punctuation and number variants.
/// The popup is visual only; the held key retains the touch until release.
final class KeyChoicePopup: UIView {
    let choices: [String]
    private(set) var selectedIndex: Int
    private let glass = LiquidGlassView(radius: 15)
    private let selection = UIView()
    private let labels: [CenteredKeyLabel]
    private let cellWidth: CGFloat
    private let initialIndex: Int
    private let origin: CGPoint
    init(choices: [String], initial: Int, origin: CGPoint, anchor: CGRect, host: UIView, accent: UIColor) {
        self.choices = choices; selectedIndex = initial; initialIndex = initial; self.origin = origin
        cellWidth = min(48, max(24, (host.bounds.width - 20) / CGFloat(choices.count)))
        labels = choices.map { text in
            let label = CenteredKeyLabel(); label.text = text
            label.font = .systemFont(ofSize: 25); label.textAlignment = .center
            return label
        }
        let width = cellWidth * CGFloat(choices.count) + 8
        let idealX = anchor.midX - (CGFloat(initial) + 0.5) * cellWidth - 4
        super.init(frame: CGRect(x: min(max(6, idealX), max(6, host.bounds.width - width - 6)),
                                y: max(2, anchor.minY - 62), width: width, height: 56))
        isUserInteractionEnabled = false
        accessibilityIdentifier = "key.alternatives"
        isAccessibilityElement = true; accessibilityLabel = choices.joined(separator: "  ")
        addSubview(glass); glass.frame = bounds
        selection.backgroundColor = accent; selection.layer.cornerRadius = 11
        addSubview(selection); labels.forEach(addSubview)
        updateSelection(initial)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func update(at point: CGPoint) {
        // Relative movement preserves the initial choice even if edge clamping
        // shifts the popup away from the finger at the first/last keyboard key.
        let step = Int(((point.x - origin.x) / cellWidth).rounded())
        updateSelection(min(choices.count - 1, max(0, initialIndex + step)))
        alpha = point.y > origin.y + 78 || point.y < frame.minY - 58 ? 0.35 : 1
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
