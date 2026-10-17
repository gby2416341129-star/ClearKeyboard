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
            let luminance = r * 0.2126 + g * 0.7152 + b * 0.0722
            if trait.userInterfaceStyle == .dark && luminance < 0.45 {
                let mix: CGFloat = 0.55
                return UIColor(red: r + (1-r)*mix, green: g + (1-g)*mix, blue: b + (1-b)*mix, alpha: 1)
            }
            if trait.userInterfaceStyle != .dark && luminance > 0.55 {
                let scale: CGFloat = 0.42 / max(0.01, luminance)
                return UIColor(red: r*scale, green: g*scale, blue: b*scale, alpha: 1)
            }
            return color
        }
    }
    var onAccentColor: UIColor {
        let rgb = accentRGB
        return rgb.red * 0.2126 + rgb.green * 0.7152 + rgb.blue * 0.0722 > 0.6 ? .black : .white
    }
}
