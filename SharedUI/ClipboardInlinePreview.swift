import UIKit
import CoreText

/// The canvas stays the size of the viewport. Text is shaped once; scrolling
/// draws only intersecting glyph runs, including the far end of long articles.
/// A UITextView's internal tiled layout must not compete with our contentSize.
@MainActor final class ClipboardInlinePreview: UIScrollView {
    var onPaste: (() -> Void)?
    var isReady: Bool { canvas.isReady }
    private let canvas = ClipboardLineCanvas()
    private let edgeMask = CAGradientLayer()
    private(set) var text = ""
    var renderedLineRect: CGRect { canvas.lineRect }
    var visibleStringRange: NSRange { canvas.visibleStringRange }
    var lastDrawnGlyphCount: Int { canvas.lastDrawnGlyphCount }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; canvas.isUserInteractionEnabled = false
        addSubview(canvas)
        canvas.onShape = { [weak self] in self?.setNeedsLayout(); self?.layoutIfNeeded() }
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
        let overflow = max(0, contentSize.width - bounds.width)
        let left = contentOffset.x > 0.5, right = contentOffset.x < overflow - 0.5 || contentOffset.x < -0.5
        let fade = min(16, bounds.width / 3)
        guard bounds.width > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.mask = edgeMask; edgeMask.frame = bounds
        edgeMask.startPoint = CGPoint(x: 0, y: 0.5); edgeMask.endPoint = CGPoint(x: 1, y: 0.5)
        edgeMask.colors = [UIColor.black.withAlphaComponent(left ? 0 : 1).cgColor, UIColor.black.cgColor,
                           UIColor.black.cgColor, UIColor.black.withAlphaComponent(right ? 0 : 1).cgColor]
        edgeMask.locations = [0, NSNumber(value: Double(fade / bounds.width)), NSNumber(value: Double(1 - fade / bounds.width)), 1]
        CATransaction.commit()
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
    nonisolated private static let shapeQueue = DispatchQueue(label: "clear.clipboard.line", qos: .userInitiated)
    private var revision = 0
    private(set) var isReady = true
    var onShape: (() -> Void)?
    private struct Chunk {
        let run: CTRun; let range: CFRange; let minX: CGFloat; let maxX: CGFloat
    }
    private struct Shape {
        let line: CTLine; let chunks: [Chunk]; let width: CGFloat; let ascent: CGFloat; let descent: CGFloat
    }
    private var maxEnds: [CGFloat] = []
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
        revision += 1; let request = revision
        let color = UIColor.label.resolvedColor(with: traitCollection).cgColor
        isReady = false
        let apply: (Shape) -> Void = { [weak self] result in
            guard let self, self.revision == request else { return }
            self.line = result.line; self.chunks = result.chunks
            self.lineWidth = result.width; self.ascent = result.ascent; self.descent = result.descent
            var end: CGFloat = -.greatestFiniteMagnitude
            self.maxEnds = result.chunks.map { end = max(end, $0.maxX); return end }
            self.isReady = true; self.setNeedsDisplay(); self.onShape?()
        }
        if value.utf8.count <= 8192 { apply(Self.prepare(value, color: color)) }
        else {
            Self.shapeQueue.async {
                let result = Self.prepare(value, color: color)
                DispatchQueue.main.async { apply(result) }
            }
        }
    }
    nonisolated private static func prepare(_ value: String, color: CGColor) -> Shape {
        let pointSize: CGFloat = 15
        // The private UIFont name is not a public Core Text family name; using
        // it by name can silently fall back to Times for Latin text.
        let system = CTFontCreateUIFontForLanguage(.system, pointSize, nil)!
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontTraitsAttribute: [kCTFontWeightTrait: 0.23]
        ] as CFDictionary)
        let face = CTFontCreateCopyWithAttributes(system, pointSize, nil, descriptor)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): face,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        let shaped = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes) as CFAttributedString)
        var chunks: [Chunk] = []
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(shaped, &ascent, &descent, nil))
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
        chunks.sort { $0.minX < $1.minX }
        return Shape(line: shaped, chunks: chunks, width: lineWidth, ascent: ascent, descent: descent)
    }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.textMatrix = .identity
        context.translateBy(x: -viewportOrigin, y: (bounds.height + ascent - descent) / 2)
        context.scaleBy(x: 1, y: -1); context.textPosition = .zero
        lastDrawnGlyphCount = 0
        let right = viewportOrigin + bounds.width
        var low = 0, high = chunks.count
        while low < high {
            let mid = (low + high) / 2
            if maxEnds[mid] < viewportOrigin { low = mid + 1 } else { high = mid }
        }
        for chunk in chunks.dropFirst(low) {
            if chunk.minX > right { break }
            guard chunk.maxX >= viewportOrigin else { continue }
            context.saveGState()
            context.textPosition = .zero
            CTRunDraw(chunk.run, context, chunk.range)
            context.restoreGState(); lastDrawnGlyphCount += chunk.range.length
        }
    }
}
