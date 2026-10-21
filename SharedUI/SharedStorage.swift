import UIKit

enum SharedStorage {
    /// Move each process's legacy local data only once for this shared group.
    /// A marker in the source domain also prevents a later shared reset from
    /// bringing back old names or numbers that the user deliberately cleared.
    static func migrateLegacyDefaults(from source: UserDefaults, to destination: UserDefaults, groupIdentifier: String) {
        guard source !== destination else { return }
        let marker = "clear.shared.migration.v1." + groupIdentifier
        guard !source.bool(forKey: marker) else { return }

        if destination.object(forKey: "clear.settings.v1") == nil,
           let settings = source.object(forKey: "clear.settings.v1") {
            destination.set(settings, forKey: "clear.settings.v1")
        }

        let sourceEpoch = source.string(forKey: "clear.learned.epoch")
        let sharedEpoch = destination.string(forKey: "clear.learned.epoch")
        let sharedEpochExists = destination.object(forKey: "clear.learned.epoch") != nil
        if !sharedEpochExists || (sharedEpoch != nil && sharedEpoch == sourceEpoch) {
            for key in ["clear.learned.v1", "clear.choices.v2", "clear.numbers.v1", "clear.learned.epoch"] {
                if destination.object(forKey: key) == nil, let value = source.object(forKey: key) {
                    destination.set(value, forKey: key)
                }
            }
        }
        source.set(true, forKey: marker)
    }

    static func defaults(allowShared: Bool) -> UserDefaults {
        guard allowShared, let group = Bundle.main.object(forInfoDictionaryKey: "ClearAppGroup") as? String,
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil,
              let defaults = UserDefaults(suiteName: group) else { return .standard }
        migrateLegacyDefaults(from: .standard, to: defaults, groupIdentifier: group)
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
    var backgroundTintOpacity: Double { glass == .solid ? 1 : glass == .clear ? 0.55 : 0.70 }
    func keyFaceOpacity(dark: Bool, utility: Bool) -> Double {
        // Color and optical strength are independent controls. A low glass
        // strength must not reduce a chosen key color to a nearly invisible tint.
        if keyColorHex != nil { return utility ? 0.70 : 0.78 }
        let base = glass == .clear ? (dark ? 0.14 : 0.62) : (dark ? 0.25 : 0.78)
        return min(0.92, 0.06 + base * resolvedKeyGlassStrength) * (utility ? 0.72 : 1)
    }
    var keyInkColor: UIColor { keyInkColor(utility: false) }
    func keyInkColor(utility: Bool) -> UIColor {
        guard keyColorHex != nil || backgroundColorHex != nil else { return .label }
        let settings = self
        let reduced = glass == .solid || UIAccessibility.isReduceTransparencyEnabled || ProcessInfo.processInfo.isLowPowerModeEnabled
        return UIColor { trait in
            let dark = trait.userInterfaceStyle == .dark
            func blend(_ foreground: RGBColor, _ background: RGBColor, _ alpha: Double) -> RGBColor {
                RGBColor(red: foreground.red * alpha + background.red * (1-alpha),
                         green: foreground.green * alpha + background.green * (1-alpha),
                         blue: foreground.blue * alpha + background.blue * (1-alpha))
            }
            let base = dark ? 0.12 : 0.97
            var backdrop = RGBColor(red: base, green: base, blue: base)
            if let hex = settings.backgroundColorHex, let tint = RGBColor(hex: hex) {
                backdrop = blend(tint, backdrop, reduced ? 1 : settings.backgroundTintOpacity)
            }
            let neutral = reduced ? (dark ? (utility ? 0.19 : 0.30) : (utility ? 0.82 : 0.97)) : 1
            let tint = settings.keyColorHex.flatMap(RGBColor.init(hex:)) ?? RGBColor(red: neutral, green: neutral, blue: neutral)
            let alpha = reduced ? 1 : settings.keyFaceOpacity(dark: dark, utility: utility)
            let face = blend(tint, backdrop, alpha)
            func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            let luminance = linear(face.red) * 0.2126 + linear(face.green) * 0.7152 + linear(face.blue) * 0.0722
            // Pick ink for the translucent face, not for the uncomposited color
            // swatch: a faint white tint on a dark keyboard still needs white ink.
            return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) ? .black : .white
        }
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
