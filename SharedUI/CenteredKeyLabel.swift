import UIKit
import CoreText

/// Center the visible glyph contour, rather than the font's ascender/descender line box.
final class CenteredKeyLabel: UILabel {
    override func drawText(in rect: CGRect) {
        guard let text, !text.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
        let drawingFont = font ?? UIFont.systemFont(ofSize: 23)
        let inkColor = (textColor ?? .label).resolvedColor(with: traitCollection)
        let value = NSAttributedString(string: text, attributes: [.font: drawingFont, .foregroundColor: inkColor])
        let line = CTLineCreateWithAttributedString(value)
        let ink = CTLineGetImageBounds(line, nil)
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
