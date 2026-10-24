import UIKit
import SwiftUI

/// Compact, normally colored settings symbols with a shared optical keyline.
@MainActor enum ToolArtwork {
    private static var cache: [String: UIImage] = [:]
    private static func descriptor(_ symbol: String) -> (String,CGFloat) {
        switch symbol {
        case "character.bubble.fill": return ("character.bubble.fill",0.65)
        case "doc.on.clipboard.fill", "doc.on.clipboard": return ("list.clipboard.fill",0.57)
        case "face.smiling.fill": return ("face.smiling.fill",0.105)
        case "keyboard.fill": return ("hand.point.up.left.fill",0.62)
        case "paintpalette.fill": return ("paintbrush.pointed.fill",0.075)
        case "rectangle.3.group.fill", "rectangle.3.group": return ("square.grid.2x2.fill",0.68)
        case "desktopcomputer": return ("desktopcomputer",0.56)
        case "key.glass": return ("keyboard.fill",0.60)
        case "key.color": return ("square.on.square.fill",0.70)
        case "candidate.color": return ("character",0.77)
        case "candidate.size": return ("textformat.size",0.63)
        case "slider.horizontal.3": return ("slider.horizontal.3",0.57)
        case "lock.shield": return ("lock.shield.fill",0.57)
        case "waveform": return ("waveform",0.48)
        case "doc.text": return ("doc.text.fill",0.56)
        case "keyboard": return ("keyboard.fill",0.57)
        case "clear.mark": return ("water.waves",0.60)
        default: return (symbol,0.64)
        }
    }
    static func tint(_ symbol: String) -> UIColor {
        UIColor(hue: descriptor(symbol).1,saturation: 0.83,brightness: 0.98,alpha: 1)
    }
    private static func visibleGlyph(_ image: UIImage,scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false; format.preferredRange = .standard
        let raster = UIGraphicsImageRenderer(size: image.size,format: format).image { _ in
            image.draw(in: CGRect(origin: .zero,size: image.size))
        }
        guard let source = raster.cgImage else { return image }
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 0,count: width*height*4)
        return pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return image }
            context.draw(source,in: CGRect(x: 0,y: 0,width: CGFloat(width),height: CGFloat(height)))
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height { for x in 0..<width where raw[(y*width+x)*4+3] > 24 {
                minX = min(minX,x); minY = min(minY,y); maxX = max(maxX,x); maxY = max(maxY,y)
            } }
            guard maxX >= minX, maxY >= minY,
                  let bitmap = context.makeImage()?.cropping(to: CGRect(x: CGFloat(minX),y: CGFloat(minY),width: CGFloat(maxX-minX+1),height: CGFloat(maxY-minY+1))) else { return image }
            return UIImage(cgImage: bitmap,scale: scale,orientation: .up)
        }
    }
    static func stencil(_ symbol: String,scale: CGFloat = 3) -> UIImage {
        let key = "mask:\(symbol):\(scale)"
        if let image = cache[key] { return image }
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32,height: 32),format: format).image { _ in
            let config = UIImage.SymbolConfiguration(pointSize: 26,weight: .semibold)
            guard let original = UIImage(systemName: descriptor(symbol).0,withConfiguration: config)?.withTintColor(.white,renderingMode: .alwaysOriginal) else { return }
            let icon = visibleGlyph(original,scale: scale)
            let side: CGFloat = symbol == "candidate.color" ? 22 : 26
            let ratio = min(side/icon.size.width,side/icon.size.height)
            let width = icon.size.width*ratio, height = icon.size.height*ratio
            let y: CGFloat = symbol == "candidate.color" ? 13.5 : 16
            icon.draw(in: CGRect(x: 16-width/2,y: y-height/2,width: width,height: height))
            if symbol == "candidate.color" {
                UIColor.white.setFill(); UIBezierPath(roundedRect: CGRect(x: 5,y: 28,width: 22,height: 2),cornerRadius: 1).fill()
            }
        }
        cache[key] = image; return image
    }
    static func brand(size: CGFloat = 28) -> UIImage {
        let key = "brand:\(size)"
        if let image = cache[key] { return image }
        guard let url = Bundle.main.url(forResource: "BrandMark", withExtension: "png"),
              let data = try? Data(contentsOf: url), let source = UIImage(data: data) else {
            return image(symbol: "water.waves", size: size)
        }
        let material = brandMaterial(source)
        let format = UIGraphicsImageRendererFormat(); format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size),format: format).image { _ in
            material.draw(in: CGRect(x: 0,y: 0,width: size,height: size))
        }.withRenderingMode(.alwaysOriginal)
        cache[key] = image; return image
    }
    private static func brandMaterial(_ source: UIImage) -> UIImage {
        if let value = cache["brand.material"] { return value }
        guard let bitmap = source.cgImage else { return source }
        guard let image = BrandMaterial.image(bitmap) else { return source }
        let result = UIImage(cgImage: image,scale: source.scale,orientation: .up)
        cache["brand.material"] = result; return result
    }
    static func image(symbol: String, size: CGFloat = 28, scale: CGFloat? = nil, style: UIUserInterfaceStyle? = nil) -> UIImage {
        let scale = scale ?? UIScreen.main.scale
        let key = "settings:\(symbol):\(size):\(scale)"
        if let image = cache[key] { return image }
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false
        let mask = stencil(symbol,scale: scale)
        let value = UIGraphicsImageRenderer(size: CGSize(width: size,height: size),format: format).image { renderer in
            let c = renderer.cgContext; c.scaleBy(x: size/32,y: size/32)
            guard let bitmap = mask.cgImage else { return }
            c.saveGState(); c.translateBy(x: 0,y: 32); c.scaleBy(x: 1,y: -1)
            c.clip(to: CGRect(x: 0,y: 0,width: 32,height: 32),mask: bitmap)
            let color = tint(symbol)
            var r: CGFloat = 0,g: CGFloat = 0,b: CGFloat = 0,a: CGFloat = 0
            color.getRed(&r,green: &g,blue: &b,alpha: &a)
            let light = UIColor(red: r+(1-r)*0.16,green: g+(1-g)*0.16,blue: b+(1-b)*0.16,alpha: 1)
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),colors: [light.cgColor,color.cgColor] as CFArray,locations: [0,1]) {
                c.drawLinearGradient(gradient,start: CGPoint(x: 16,y: 32),end: CGPoint(x: 16,y: 0),options: [])
            }
            c.restoreGState()
        }.withRenderingMode(.alwaysOriginal)
        cache[key] = value; return value
    }

}

/// The same clean settings artwork is used in rows, tools and drag previews.
@MainActor final class ToolIconView: UIView {
    private let ink = UIImageView()
    private var symbol = ""
    init(symbol: String) {
        super.init(frame: .zero)
        isOpaque = false; backgroundColor = .clear
        isUserInteractionEnabled = false; isAccessibilityElement = false
        ink.contentMode = .scaleAspectFit; addSubview(ink); setSymbol(symbol)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func setSymbol(_ value: String) {
        guard symbol != value else { return }; symbol = value
        updateArtwork()
    }
    private func updateArtwork() { ink.image = ToolArtwork.image(symbol: symbol,size: 32,style: traitCollection.userInterfaceStyle) }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection); updateArtwork()
    }
    override func layoutSubviews() { super.layoutSubviews(); ink.frame = bounds }
}

struct ToolIcon: UIViewRepresentable {
    let symbol: String
    func makeUIView(context: Context) -> ToolIconView { ToolIconView(symbol: symbol) }
    func updateUIView(_ view: ToolIconView,context: Context) { view.setSymbol(symbol) }
}

/// Compact rectangular controls, with separate readable artwork and thin clear glass.
@MainActor final class ToolTileButton: UIButton {
    private let lens = LiquidGlassView(radius: 10, keycap: true, clear: true)
    private let artwork: ToolIconView
    private let caption = UILabel()
    init(title: String, symbol: String, action: @escaping () -> Void) {
        artwork = ToolIconView(symbol: symbol)
        super.init(frame: .zero)
        addSubview(lens); addSubview(artwork); addSubview(caption)
        caption.text = title; caption.textColor = .label; caption.font = .systemFont(ofSize: 12,weight: .medium)
        caption.textAlignment = .center; caption.adjustsFontSizeToFitWidth = true; caption.minimumScaleFactor = 0.9
        for view in [artwork,caption] { view.isUserInteractionEnabled = false }
        isAccessibilityElement = true; accessibilityLabel = title
        addAction(UIAction { _ in action() }, for: .touchUpInside)
        lens.configure(tint: nil,strength: 0.25,fallback: .secondarySystemBackground)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        lens.frame = bounds
        artwork.frame = CGRect(x: bounds.midX-14,y: 7,width: 28,height: 28)
        caption.frame = CGRect(x: 5,y: 40,width: max(0,bounds.width-10),height: 16)
    }
    override var isHighlighted: Bool {
        didSet { lens.alpha = isHighlighted ? 0.72 : 1 }
    }
}
