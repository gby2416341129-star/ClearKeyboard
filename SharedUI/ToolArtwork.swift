import UIKit

/// A consistent optical grid and distinct silhouettes, cached at display scale.
@MainActor enum ToolArtwork {
    private static var cache: [String: UIImage] = [:]
    static func brand(size: CGFloat = 28) -> UIImage {
        let key = "brand:\(size)"
        if let image = cache[key] { return image }
        guard let url = Bundle.main.url(forResource: "BrandMark", withExtension: "png"),
              let data = try? Data(contentsOf: url), let source = UIImage(data: data) else {
            return image(symbol: "water.waves", size: size)
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            UIBezierPath(roundedRect: CGRect(x: 1,y: 1,width: size-2,height: size-2), cornerRadius: size*0.27).addClip()
            source.draw(in: CGRect(x: 0,y: 0,width: size,height: size))
        }
        cache[key] = image; return image
    }
    static func image(symbol: String, size: CGFloat = 28, scale: CGFloat = UIScreen.main.scale) -> UIImage {
        let key = "\(symbol):\(size):\(scale)"
        if let value = cache[key] { return value }
        let glyph: String, hue: CGFloat
        switch symbol {
        case "character.bubble.fill": glyph = "character.bubble"; hue = 0.66
        case "doc.on.clipboard.fill", "doc.on.clipboard": glyph = "list.clipboard"; hue = 0.57
        case "face.smiling.fill": glyph = "face.smiling"; hue = 0.10
        case "keyboard.fill": glyph = "hand.point.up.left"; hue = 0.62
        case "paintpalette.fill": glyph = "paintbrush.pointed"; hue = 0.84
        case "rectangle.3.group.fill", "rectangle.3.group": glyph = "square.grid.2x2"; hue = 0.70
        case "desktopcomputer": glyph = "desktopcomputer"; hue = 0.55
        case "clear.mark": glyph = "water.waves"; hue = 0.60
        default: glyph = symbol; hue = 0.64
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false
        let value = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { renderer in
            let c = renderer.cgContext; c.scaleBy(x: size/32, y: size/32)
            let shape = UIBezierPath(roundedRect: CGRect(x: 3, y: 3, width: 26, height: 26), cornerRadius: 8)
            c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: 1), blur: 1.5, color: UIColor.black.withAlphaComponent(0.15).cgColor)
            UIColor(hue: hue, saturation: 0.46, brightness: 0.92, alpha: 1).setFill(); shape.fill(); c.restoreGState()
            c.saveGState(); shape.addClip()
            let colors = [UIColor(hue: hue, saturation: 0.22, brightness: 1, alpha: 1).cgColor, UIColor(hue: hue, saturation: 0.63, brightness: 0.87, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0,1]) {
                c.drawLinearGradient(gradient, start: CGPoint(x: 7,y: 3), end: CGPoint(x: 24,y: 31), options: [])
            }
            UIColor.white.withAlphaComponent(0.25).setFill()
            UIBezierPath(ovalIn: CGRect(x: -5, y: -8, width: 40, height: 25)).fill(); c.restoreGState()
            UIColor.white.withAlphaComponent(0.55).setStroke(); shape.lineWidth = 0.65; shape.stroke()
            let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            if let icon = UIImage(systemName: glyph, withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                let ratio = min(18/icon.size.width, 18/icon.size.height)
                let width = icon.size.width*ratio, height = icon.size.height*ratio
                c.saveGState(); c.setShadow(offset: CGSize(width: 0,height: 0.5), blur: 0.5, color: UIColor.black.withAlphaComponent(0.12).cgColor)
                icon.draw(in: CGRect(x: 16-width/2, y: 16-height/2, width: width,height: height)); c.restoreGState()
            }
        }
        cache[key] = value; return value
    }
}
