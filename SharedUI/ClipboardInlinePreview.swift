import UIKit
import CoreText

/// The canvas stays the size of the viewport. Text is shaped once; scrolling
/// draws only intersecting glyph runs, including the far end of long articles.
/// A UITextView's internal tiled layout must not compete with our contentSize.
@MainActor final class ClipboardInlinePreview: UIScrollView {
    var onPaste: (() -> Void)?
    private let canvas = ClipboardLineCanvas()
    private(set) var text = ""
    var renderedLineRect: CGRect { canvas.lineRect }
    var visibleStringRange: NSRange { canvas.visibleStringRange }
    var lastDrawnGlyphCount: Int { canvas.lastDrawnGlyphCount }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; canvas.isUserInteractionEnabled = false
        addSubview(canvas)
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = true; alwaysBounceVertical = false
        isDirectionalLockEnabled = true; contentInsetAdjustmentBehavior = .never
        delaysContentTouches = false
        accessibilityIdentifier = "clipboard.recent.text"; isAccessibilityElement = true
        accessibilityTraits = .button
        let tap = UITapGestureRecognizer(target: self, action: #selector(pasteText))
        tap.require(toFail: panGestureRecognizer); addGestureRecognizer(tap)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: ClipboardInlinePreview, _: UITraitCollection) in
            view.canvas.shape(view.text); view.setNeedsLayout()
        }
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let size = CGSize(width: max(bounds.width, canvas.lineWidth + 8), height: bounds.height)
        if contentSize != size { contentSize = size }
        canvas.frame = bounds
        canvas.viewportOrigin = contentOffset.x
    }
    func show(_ value: String) {
        let line = value.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\t", with: " ")
        guard text != line else { return }
        text = line; accessibilityLabel = value; canvas.shape(line)
        contentSize = CGSize(width: max(bounds.width, canvas.lineWidth + 8), height: bounds.height)
        setContentOffset(.zero, animated: false); setNeedsLayout()
    }
    @objc private func pasteText() { onPaste?() }
}

@MainActor private final class ClipboardLineCanvas: UIView {
    private struct Chunk {
        let run: CTRun; let range: CFRange; let minX: CGFloat; let maxX: CGFloat
    }
    private var line: CTLine?
    private var chunks: [Chunk] = []
    private var ascent: CGFloat = 0, descent: CGFloat = 0
    private(set) var lineWidth: CGFloat = 0
    private(set) var lastDrawnGlyphCount = 0
    var viewportOrigin: CGFloat = 0 { didSet { if viewportOrigin != oldValue { setNeedsDisplay() } } }
    var lineRect: CGRect { CGRect(x: -viewportOrigin, y: (bounds.height - ascent - descent) / 2, width: lineWidth, height: ascent + descent) }
    var visibleStringRange: NSRange {
        guard let line else { return NSRange(location: 0, length: 0) }
        let a = CTLineGetStringIndexForPosition(line, CGPoint(x: max(0, viewportOrigin), y: 0))
        let b = CTLineGetStringIndexForPosition(line, CGPoint(x: min(lineWidth, viewportOrigin + bounds.width), y: 0))
        guard a != kCFNotFound, b != kCFNotFound else { return NSRange(location: 0, length: 0) }
        return NSRange(location: min(a,b), length: abs(b-a))
    }
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear; isOpaque = false; contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func shape(_ value: String) {
        let font = UIFont.systemFont(ofSize: 15, weight: .medium)
        // The private UIFont name is not a public Core Text family name; using
        // it by name can silently fall back to Times for Latin text.
        let system = CTFontCreateUIFontForLanguage(.system, font.pointSize, nil)!
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontTraitsAttribute: [kCTFontWeightTrait: UIFont.Weight.medium.rawValue]
        ] as CFDictionary)
        let face = CTFontCreateCopyWithAttributes(system, font.pointSize, nil, descriptor)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): face,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): UIColor.label.resolvedColor(with: traitCollection).cgColor]
        let shaped = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes) as CFAttributedString)
        line = shaped; chunks = []
        lineWidth = CGFloat(CTLineGetTypographicBounds(shaped, &ascent, &descent, nil))
        for run in CTLineGetGlyphRuns(shaped) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            for start in stride(from: 0, to: count, by: 64) {
                let length = min(64, count - start), range = CFRange(location: start, length: min(64, count - start))
                var positions = [CGPoint](repeating: .zero, count: length)
                var advances = [CGSize](repeating: .zero, count: length)
                CTRunGetPositions(run, range, &positions); CTRunGetAdvances(run, range, &advances)
                let left = positions.map(\.x).min() ?? 0
                let right = zip(positions, advances).map { $0.0.x + $0.1.width }.max() ?? left
                chunks.append(Chunk(run: run, range: range, minX: left - 30, maxX: right + 30))
            }
        }
        setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.textMatrix = .identity
        context.translateBy(x: -viewportOrigin, y: (bounds.height + ascent - descent) / 2)
        context.scaleBy(x: 1, y: -1); context.textPosition = .zero
        lastDrawnGlyphCount = 0
        let right = viewportOrigin + bounds.width
        for chunk in chunks where chunk.maxX >= viewportOrigin && chunk.minX <= right {
            context.saveGState()
            context.textPosition = .zero
            CTRunDraw(chunk.run, context, chunk.range)
            context.restoreGState(); lastDrawnGlyphCount += chunk.range.length
        }
    }
}
