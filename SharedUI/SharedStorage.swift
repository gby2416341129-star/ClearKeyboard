import UIKit
import Darwin

enum SharedStorage {
    private static let migrationQueue = DispatchQueue(label: "clear.legacy.clipboard", qos: .utility)
    private static let migrationLock = NSLock()
    private static var migrating = Set<String>()
    private static let defaultsMigrationLock=NSRecursiveLock()
    private static var defaultsMigrations=Set<String>()
    struct Group { let identifier: String; let root: URL }
    /// Re-signers can rewrite the provisioning group while leaving Info.plist
    /// untouched. Use only a container iOS actually grants this process.
    static func applicationGroup() -> Group? {
        applicationGroups().first
    }
    static func applicationGroups() -> [Group] {
        let snapshot=InstallationLifecycle.prepare()
        return InstallationLifecycle.rawGroups().map {Group(identifier:$0.identifier,root:InstallationLifecycle.sharedRoot($0.root,snapshot:snapshot))}
    }
    private static let provisionedGroups: [String] = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url), data.count < 2_000_000,
              let start = data.range(of: Data("<plist".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound), options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }()

    /// Move each process's legacy local data only once for this shared group.
    /// A marker in the source domain also prevents a later shared reset from
    /// bringing back old names or numbers that the user deliberately cleared.
    static func migrateLegacyDefaults(from source: UserDefaults, to destination: UserDefaults, groupIdentifier: String) {
        guard source !== destination else{return}
        if source.bool(forKey:"clear.shared.migration.v1."+groupIdentifier),
           source.bool(forKey:"clear.shared.learning-migration.v2."+groupIdentifier) {return}
        defaultsMigrationLock.lock()
        guard defaultsMigrations.insert(groupIdentifier).inserted else {defaultsMigrationLock.unlock();return}
        defer{defaultsMigrations.remove(groupIdentifier);defaultsMigrationLock.unlock()}
        if let root=FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:groupIdentifier) {
            // Serialize migration's epoch/payload publication with clear/save.
            _ = try? SharedFileLock.perform(at:InstallationLifecycle.sharedRoot(root).appendingPathComponent("Learning/learning.lock")) {
                migrateDefaultsLocked(from:source,to:destination,groupIdentifier:groupIdentifier)
            }
        } else {migrateDefaultsLocked(from:source,to:destination,groupIdentifier:groupIdentifier)}
    }
    private static func migrateDefaultsLocked(from source:UserDefaults,to destination:UserDefaults,groupIdentifier:String) {
        guard source !== destination else { return }
        source.synchronize();destination.synchronize()
        let marker = "clear.shared.migration.v1." + groupIdentifier
        // Earlier migrations copied only the epoch pointer and legacy keys.
        // Copy that epoch's current v3 payload once, never a retired namespace.
        let learningMarker="clear.shared.learning-migration.v2."+groupIdentifier
        if !source.bool(forKey:learningMarker) {
            let sourceEpoch=source.string(forKey:"clear.learned.epoch")
            let sharedEpoch=destination.string(forKey:"clear.learned.epoch")
            let sharedHasEpoch=destination.object(forKey:"clear.learned.epoch") != nil
            let sharedLegacyExists=destination.object(forKey:"clear.learning.v3.legacy") != nil
            if (!sharedHasEpoch && !sharedLegacyExists) || sourceEpoch==sharedEpoch {
                let key="clear.learning.v3."+(sourceEpoch ?? "legacy")
                if destination.object(forKey:key)==nil,let value=source.object(forKey:key) {
                    destination.set(value,forKey:key)
                    if !sharedHasEpoch,let sourceEpoch {destination.set(sourceEpoch,forKey:"clear.learned.epoch")}
                }
            }
            source.set(true,forKey:learningMarker)
        }
        guard !source.bool(forKey: marker) else { return }

        if destination.object(forKey: "clear.settings.v1") == nil,
           let settings = source.object(forKey: "clear.settings.v1") {
            destination.set(settings, forKey: "clear.settings.v1")
        }

        let sourceEpoch = source.string(forKey: "clear.learned.epoch")
        let sharedEpoch = destination.string(forKey: "clear.learned.epoch")
        let sharedEpochExists = destination.object(forKey: "clear.learned.epoch") != nil
        let sharedLegacyExists=destination.object(forKey:"clear.learning.v3.legacy") != nil
        if (!sharedEpochExists && !sharedLegacyExists) || (sharedEpoch != nil && sharedEpoch == sourceEpoch) {
            for key in ["clear.learned.v1", "clear.choices.v2", "clear.numbers.v1", "clear.learned.epoch"] {
                if destination.object(forKey: key) == nil, let value = source.object(forKey: key) {
                    destination.set(value, forKey: key)
                }
            }
        }
        source.set(true, forKey: marker)
    }

    static func defaults(allowShared: Bool) -> UserDefaults {
        let local=InstallationLifecycle.privateDefaults()
        guard allowShared, let group = applicationGroup(),
              let backing = UserDefaults(suiteName: group.identifier) else { return local }
        let defaults=InstallationLifecycle.scopedDefaults(backing,domain:group.identifier)
        migrateLegacyDefaults(from: local, to: defaults, groupIdentifier: group.identifier)
        return defaults
    }
    /// Adopt the complete legacy folder so attachment paths, dates and pins
    /// remain valid. Existing shared stores merge on a background queue;
    /// exclusive rename handles a new shared directory without copying bytes.
    static func adoptLegacyClipboardDirectory(from source: URL, to destination: URL, defaults: UserDefaults, groupIdentifier: String, sourceTag:String="local",trustedScope:Bool=false) {
        guard trustedScope || InstallationLifecycle.legacyMigrationAllowed() else{return}
        guard source.isFileURL, destination.isFileURL else { return }
        let source = source.standardizedFileURL, destination = destination.standardizedFileURL
        guard source != destination else { return }
        // The source defaults domain identifies its owning process. Keep this
        // stable when iOS changes that process's absolute container location.
        let marker = "clear.clipboard.migration.install.v1." + groupIdentifier+"."+sourceTag
        guard !defaults.bool(forKey: marker) else { return }

        // Copy only records/assets owned by ClipboardStore. Never move or erase
        // an entire shared Private directory, which may contain another App's data.
        do {try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)}catch{return}
        do {
            migrationLock.lock(); let start = migrating.insert(source.path + destination.path).inserted; migrationLock.unlock()
            guard start else { return }
            migrationQueue.async {
                defer { migrationLock.lock(); migrating.remove(source.path + destination.path); migrationLock.unlock() }
                guard FileManager.default.fileExists(atPath: source.path) else { return }
                var complete = true
                for name in ["clipboard.json", "common-phrases.json"] {
                    let old = source.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: old.path) {
                        complete = ClipboardStore(url: destination.appendingPathComponent(name)).mergeLegacy(from: old) && complete
                    }
                }
                if complete { defaults.set(true, forKey: marker) }
            }
            return
        }
    }
    static func clipboardURL(allowShared: Bool) -> URL {
        if allowShared, let group = applicationGroup() {
            let root = group.root
            let localRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Clear", isDirectory: true)
            let sharedRoot = root.appendingPathComponent("Private", isDirectory: true)
            let preferences=defaults(allowShared:true)
            adoptLegacyClipboardDirectory(from: localRoot, to: sharedRoot, defaults: preferences, groupIdentifier: group.identifier,sourceTag:Bundle.main.bundleIdentifier ?? "local")
            for raw in InstallationLifecycle.rawGroups() {
                adoptLegacyClipboardDirectory(from:raw.root.appendingPathComponent("Private"),to:sharedRoot,defaults:preferences,groupIdentifier:group.identifier,sourceTag:"group-"+raw.identifier)
                let snapshot=InstallationLifecycle.prepare()
                for prior in InstallationLifecycle.priorRoots(raw.root,snapshot:snapshot) {
                    adoptLegacyClipboardDirectory(from:prior.appendingPathComponent("Private"),to:sharedRoot,defaults:preferences,groupIdentifier:group.identifier,sourceTag:"prior-"+prior.lastPathComponent,trustedScope:true)
                }
            }
            return sharedRoot.appendingPathComponent("clipboard.json")
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let snapshot=InstallationLifecycle.prepare()
        let current=root.appendingPathComponent("ClearInstallation/data/"+snapshot.identifier+"/Private",isDirectory:true)
        adoptLegacyClipboardDirectory(from:root.appendingPathComponent("Clear"),to:current,defaults:InstallationLifecycle.privateDefaults(),groupIdentifier:"private",sourceTag:Bundle.main.bundleIdentifier ?? "local")
        for prior in snapshot.priorIdentifiers ?? [] {
            adoptLegacyClipboardDirectory(from:root.appendingPathComponent("ClearInstallation/data/"+prior+"/Private"),to:current,defaults:InstallationLifecycle.privateDefaults(),groupIdentifier:"private",sourceTag:"prior-"+prior,trustedScope:true)
        }
        return current.appendingPathComponent("clipboard.json")
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
        if keyColorHex != nil { return 0.62 - 0.26 * resolvedKeyGlassStrength - (utility ? 0.04 : 0) }
        return 0.075 * (1 - resolvedKeyGlassStrength)
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
