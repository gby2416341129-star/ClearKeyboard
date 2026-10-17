import UIKit

/// Small, cached, vector-drawn color tiles. Original rendering keeps labels neutral and icons colorful.
@MainActor enum ToolArtwork {
    private static var cache: [String: UIImage] = [:]
    static func image(symbol: String, size: CGFloat = 34) -> UIImage { tile(symbol: symbol, size: size, brand: false) }
    static func brand(size: CGFloat = 34) -> UIImage { tile(symbol: "clear", size: size, brand: true) }
    private static func tile(symbol: String, size: CGFloat, brand: Bool) -> UIImage {
        let key = "\(symbol)-\(size)"
        if let result = cache[key] { return result }
        let colors: [UIColor]
        switch symbol {
        case "doc.on.clipboard.fill": colors = [UIColor(red: 0.31, green: 0.69, blue: 1, alpha: 1), UIColor(red: 0.19, green: 0.43, blue: 0.94, alpha: 1)]
        case "face.smiling.fill": colors = [UIColor(red: 1, green: 0.78, blue: 0.27, alpha: 1), UIColor(red: 1, green: 0.49, blue: 0.16, alpha: 1)]
        case "keyboard.fill": colors = [UIColor(red: 0.68, green: 0.57, blue: 1, alpha: 1), UIColor(red: 0.44, green: 0.35, blue: 0.9, alpha: 1)]
        case "slider.horizontal.3": colors = [UIColor(red: 1, green: 0.57, blue: 0.69, alpha: 1), UIColor(red: 0.86, green: 0.34, blue: 0.59, alpha: 1)]
        default: colors = [UIColor(red: 0.25, green: 0.81, blue: 0.76, alpha: 1), UIColor(red: 0.13, green: 0.54, blue: 0.73, alpha: 1)]
        }
        let result = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            let bounds = CGRect(x: 0, y: 0, width: size, height: size)
            UIBezierPath(roundedRect: bounds, cornerRadius: size * 0.31).addClip()
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
            }
            let iconSize = size * (brand ? 0.77 : 0.58)
            let icon = brand ? ClearBrand.image(iconSize) : UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: iconSize, weight: .medium))
            if let icon {
                let ratio = min(iconSize / icon.size.width, iconSize / icon.size.height)
                let width = icon.size.width * ratio, height = icon.size.height * ratio
                icon.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: CGRect(x: (size - width) / 2, y: (size - height) / 2, width: width, height: height))
            }
        }.withRenderingMode(.alwaysOriginal)
        cache[key] = result; return result
    }
}
