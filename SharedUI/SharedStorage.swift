import UIKit
import Darwin

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
    /// Adopt the complete legacy folder so attachment paths, dates and pins
    /// remain valid. Exclusive rename never replaces a shared store and never
    /// falls back to copying attachment bytes on the keyboard's active path.
    static func adoptLegacyClipboardDirectory(from source: URL, to destination: URL, defaults: UserDefaults, groupIdentifier: String) {
        guard source.isFileURL, destination.isFileURL else { return }
        let source = source.standardizedFileURL, destination = destination.standardizedFileURL
        guard source != destination else { return }
        // The source defaults domain identifies its owning process. Keep this
        // stable when iOS changes that process's absolute container location.
        let marker = "clear.clipboard.migration.v1." + groupIdentifier
        guard !defaults.bool(forKey: marker) else { return }

        var destinationInfo = stat()
        if destination.path.withCString({ Darwin.lstat($0, &destinationInfo) }) == 0 {
            defaults.set(true, forKey: marker)
            return
        }
        var sourceInfo = stat()
        let sourceResult = source.path.withCString { path -> (Int32, Int32) in
            let status = Darwin.lstat(path, &sourceInfo)
            return (status, status == 0 ? 0 : errno)
        }
        guard sourceResult.0 == 0 else {
            if sourceResult.1 == ENOENT { defaults.set(true, forKey: marker) }
            return
        }
        guard (sourceInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return }
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath -> (Int32, Int32) in
                let status = Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
                return (status, status == 0 ? 0 : errno)
            }
        }
        if result.0 == 0 || result.1 == EEXIST { defaults.set(true, forKey: marker) }
    }
    static func clipboardURL(allowShared: Bool) -> URL {
        if allowShared, let group = Bundle.main.object(forInfoDictionaryKey: "ClearAppGroup") as? String,
           let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            let localRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Clear", isDirectory: true)
            let sharedRoot = root.appendingPathComponent("Private", isDirectory: true)
            adoptLegacyClipboardDirectory(from: localRoot, to: sharedRoot, defaults: .standard, groupIdentifier: group)
            return sharedRoot.appendingPathComponent("clipboard.json")
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
    var keyTintColor: UIColor? { Self.color(hex: keyColorHex) }
    var candidateTintColor: UIColor? { Self.color(hex: candidateColorHex) }
    func keyFaceOpacity(dark: Bool, utility: Bool) -> Double {
        // Match the single color film used by the native key lens so contrast
        // is evaluated against its displayed face, without compounded tint.
        if keyColorHex != nil { return 0.66 + 0.16 * resolvedKeyGlassStrength - (utility ? 0.04 : 0) }
        return 0.02 + 0.18 * resolvedKeyGlassStrength
    }
    var keyInkColor: UIColor { keyInkColor(utility: false) }
    func keyInkColor(utility: Bool) -> UIColor {
        guard keyColorHex != nil else { return .label }
        let settings = self
        let reduced = UIAccessibility.isReduceTransparencyEnabled || ProcessInfo.processInfo.isLowPowerModeEnabled
        return UIColor { trait in
            let dark = trait.userInterfaceStyle == .dark
            func blend(_ foreground: RGBColor, _ background: RGBColor, _ alpha: Double) -> RGBColor {
                RGBColor(red: foreground.red * alpha + background.red * (1-alpha),
                         green: foreground.green * alpha + background.green * (1-alpha),
                         blue: foreground.blue * alpha + background.blue * (1-alpha))
            }
            let base = dark ? 0.12 : 0.97
            let backdrop = RGBColor(red: base, green: base, blue: base)
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
