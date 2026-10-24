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
    static func image(symbol: String, size: CGFloat = 28, scale: CGFloat? = nil) -> UIImage {
        let scale = scale ?? UIScreen.main.scale
        let key = "\(symbol):\(size):\(scale)"
        if let value = cache[key] { return value }
        let glyph: String, hue: CGFloat
        switch symbol {
        case "character.bubble.fill": glyph = "character.bubble.fill"; hue = 0.66
        case "doc.on.clipboard.fill", "doc.on.clipboard": glyph = "list.clipboard.fill"; hue = 0.57
        case "face.smiling.fill": glyph = "face.smiling.fill"; hue = 0.10
        case "keyboard.fill": glyph = "hand.point.up.left.fill"; hue = 0.62
        case "paintpalette.fill": glyph = "paintpalette.fill"; hue = 0.84
        case "rectangle.3.group.fill", "rectangle.3.group": glyph = "square.grid.2x2.fill"; hue = 0.70
        case "desktopcomputer": glyph = "desktopcomputer"; hue = 0.55
        case "clear.mark": glyph = "water.waves"; hue = 0.60
        default: glyph = symbol; hue = 0.64
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false
        let value = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { renderer in
            let c = renderer.cgContext; c.scaleBy(x: size/32, y: size/32)
            let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
            if let icon = UIImage(systemName: glyph, withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                let ratio = min(25/icon.size.width, 25/icon.size.height)
                let width = icon.size.width*ratio, height = icon.size.height*ratio
                let rect = CGRect(x: 16-width/2, y: 16-height/2, width: width,height: height)
                // The material follows the functional silhouette itself. There
                // is deliberately no colored square with a white glyph inside.
                c.saveGState(); c.setShadow(offset: CGSize(width: 0,height: 1), blur: 1, color: UIColor.black.withAlphaComponent(0.20).cgColor)
                icon.withTintColor(UIColor(hue: hue,saturation: 0.5,brightness: 0.78,alpha: 1)).draw(in: rect.offsetBy(dx: 0,dy: 0.7)); c.restoreGState()
                let maskFormat = UIGraphicsImageRendererFormat(); maskFormat.scale = scale
                let mask = UIGraphicsImageRenderer(size: CGSize(width: 32,height: 32), format: maskFormat).image { _ in icon.draw(in: rect) }
                if let bitmap = mask.cgImage {
                    c.saveGState(); c.translateBy(x: 0,y: 32); c.scaleBy(x: 1,y: -1)
                    c.clip(to: CGRect(x: 0,y: 0,width: 32,height: 32),mask: bitmap)
                    let colors = [UIColor(hue: hue,saturation: 0.58,brightness: 0.84,alpha: 1).cgColor,
                                  UIColor(hue: hue,saturation: 0.20,brightness: 1,alpha: 1).cgColor]
                    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),colors: colors as CFArray,locations: [0,1]) {
                        c.drawLinearGradient(gradient,start: CGPoint(x: 27,y: 2),end: CGPoint(x: 7,y: 31),options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
                    }
                    UIColor.white.withAlphaComponent(0.30).setFill()
                    UIBezierPath(ovalIn: CGRect(x: -4,y: 19,width: 40,height: 22)).fill()
                    c.restoreGState()
                }
            }
        }
        cache[key] = value; return value
    }
}
