import UIKit

enum SharedStorage {
    static func defaults(allowShared: Bool) -> UserDefaults {
        guard allowShared, let group = Bundle.main.object(forInfoDictionaryKey: "ClearAppGroup") as? String,
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil,
              let defaults = UserDefaults(suiteName: group) else { return .standard }
        return defaults
    }
    static func clipboardURL(allowShared: Bool) -> URL {
        if allowShared, let group = Bundle.main.object(forInfoDictionaryKey: "ClearAppGroup") as? String,
           let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            return root.appendingPathComponent("Private/clipboard.json")
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("Clear/clipboard.json")
    }
}

extension Accent {
    var uiColor: UIColor {
        switch self {
        case .jade: return UIColor(red: 0.16, green: 0.54, blue: 0.44, alpha: 1)
        case .ocean: return UIColor(red: 0.20, green: 0.44, blue: 0.72, alpha: 1)
        case .rose: return UIColor(red: 0.69, green: 0.32, blue: 0.47, alpha: 1)
        case .graphite: return UIColor(red: 0.39, green: 0.43, blue: 0.48, alpha: 1)
        }
    }
}

extension KeyboardSettings {
    static func color(hex: String?) -> UIColor? {
        guard let hex, let rgb = RGBColor(hex: hex) else { return nil }
        return UIColor(red: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
    }
    var backgroundTintColor: UIColor? { Self.color(hex: backgroundColorHex) }
    var keyTintColor: UIColor? { Self.color(hex: keyColorHex) }
    var candidateTintColor: UIColor? { Self.color(hex: candidateColorHex) }
    var keyInkColor: UIColor {
        guard let hex = keyColorHex, let rgb = RGBColor(hex: hex) else { return .label }
        return rgb.red * 0.2126 + rgb.green * 0.7152 + rgb.blue * 0.0722 < 0.45 ? .white : .black
    }
    var accentColor: UIColor {
        guard let hex = customAccentHex, let rgb = RGBColor(hex: hex) else { return accent.uiColor }
        return UIColor(red: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
    }
    var accentRGB: RGBColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        accentColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGBColor(red: Double(red), green: Double(green), blue: Double(blue))
    }
    var accentInkColor: UIColor {
        let color = accentColor
        return UIColor { trait in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            func component(_ value: CGFloat) -> Double {
                let value = Double(value)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            let dark = trait.userInterfaceStyle == .dark
            let background = component(dark ? 0.18 : 0.97)
            let target: CGFloat = dark ? 1 : 0
            for step in 0...20 {
                let mix = CGFloat(step) / 20
                let red = r + (target-r)*mix, green = g + (target-g)*mix, blue = b + (target-b)*mix
                let ink = component(red) * 0.2126 + component(green) * 0.7152 + component(blue) * 0.0722
                let contrast = (max(ink, background) + 0.05) / (min(ink, background) + 0.05)
                if contrast >= 4.5 { return UIColor(red: red, green: green, blue: blue, alpha: 1) }
            }
            return dark ? .white : .black
        }
    }
    var onAccentColor: UIColor {
        let rgb = accentRGB
        return rgb.red * 0.2126 + rgb.green * 0.7152 + rgb.blue * 0.0722 > 0.6 ? .black : .white
    }
}
