import UIKit
import CoreText

/// Center the visible glyph contour, rather than the font's ascender/descender line box.
final class CenteredKeyLabel: UILabel {
    private var cachedText: String?
    private var cachedFont: UIFont?
    private var cachedColor: UIColor?
    private var cachedLine: CTLine?
    private var cachedInk = CGRect.null
    override func drawText(in rect: CGRect) {
        guard let text, !text.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
        let drawingFont = font ?? UIFont.systemFont(ofSize: 23)
        let inkColor = (textColor ?? .label).resolvedColor(with: traitCollection)
        if cachedText != text || cachedFont != drawingFont || cachedColor != inkColor || cachedLine == nil {
            cachedText = text; cachedFont = drawingFont; cachedColor = inkColor
            let value = NSAttributedString(string: text, attributes: [.font: drawingFont, .foregroundColor: inkColor])
            cachedLine = CTLineCreateWithAttributedString(value)
            cachedInk = CTLineGetImageBounds(cachedLine!, nil)
        }
        guard let line = cachedLine else { return }
        let ink = cachedInk
        guard !ink.isNull, !ink.isEmpty else { return }
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let scale = window?.screen.scale ?? UIScreen.main.scale
        context.textPosition = CGPoint(x: ((bounds.midX - ink.midX) * scale).rounded() / scale,
                                       y: ((bounds.midY - ink.midY) * scale).rounded() / scale)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
