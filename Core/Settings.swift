import Foundation

public enum InputLanguage: String, Codable, CaseIterable { case chinese, english }
public enum KeyboardPage: String, Codable { case letters, numbers, symbols }
public enum HandMode: String, Codable, CaseIterable, Identifiable {
    case full, left, right
    public var id: String { rawValue }
    public var title: String { switch self { case .full: return "标准"; case .left: return "左手"; case .right: return "右手" } }
}
public enum GlassPreset: String, Codable, CaseIterable, Identifiable {
    case clear, mist, solid
    public var id: String { rawValue }
    public var title: String { switch self { case .clear: return "清透"; case .mist: return "柔雾"; case .solid: return "纯净" } }
}
public enum Accent: String, Codable, CaseIterable, Identifiable {
    case jade, ocean, rose, graphite
    public var id: String { rawValue }
    public var title: String { switch self { case .jade: return "青瓷"; case .ocean: return "海盐"; case .rose: return "蔷薇"; case .graphite: return "石墨" } }
}
public enum ToolbarTool: String, Codable, CaseIterable, Identifiable {
    case language, clipboard, emoji, oneHand, appearance
    public var id: String { rawValue }
    public var title: String {
        switch self { case .language: return "中 / EN"; case .clipboard: return "剪贴板"; case .emoji: return "表情"; case .oneHand: return "单手"; case .appearance: return "外观" }
    }
    public var symbol: String {
        switch self { case .language: return "character.bubble.fill"; case .clipboard: return "doc.on.clipboard.fill"; case .emoji: return "face.smiling.fill"; case .oneHand: return "keyboard.fill"; case .appearance: return "slider.horizontal.3" }
    }
}

public struct KeyboardSettings: Codable, Equatable {
    public var language: InputLanguage = .chinese
    public var glass: GlassPreset = .clear
    public var accent: Accent = .jade
    public var customAccentHex: String? = nil
    public var glassOpacity: Double = 0.52
    public var keyHeight: Double = 50
    public var hand: HandMode = .full
    public var toolbar: [ToolbarTool] = [.language, .clipboard, .emoji, .appearance]
    public var oneHandWidth: Double? = nil
    public var oneHandFraction: Double { min(0.88, max(0.68, oneHandWidth ?? 0.78)) }
    public var fuzzyPairs: Set<String> = []
    public var predictions = true
    public var learnChoices = false
    public var haptics = false
    public var autoCapitalization = true
    /// Zero means no time-based expiry. Optional flag keeps pre-0.1.3 settings readable.
    public var clipboardLifetimeHours: Double = 168
    public var automaticClipboard: Bool? = nil
    public var capturesClipboard: Bool { automaticClipboard ?? true }
    public init() {}

    public mutating func sanitize() {
        customAccentHex = customAccentHex.flatMap { RGBColor(hex: $0)?.hex }
        glassOpacity = min(1, max(0.15, glassOpacity.isFinite ? glassOpacity : 0.52))
        keyHeight = min(58, max(44, keyHeight.isFinite ? keyHeight : 50))
        clipboardLifetimeHours = clipboardLifetimeHours == 0 ? 0 : min(8_760, max(0.25, clipboardLifetimeHours.isFinite ? clipboardLifetimeHours : 168))
        oneHandWidth = oneHandWidth.flatMap { $0.isFinite ? min(0.88, max(0.68, $0)) : nil }
        var seen = Set<ToolbarTool>()
        toolbar = toolbar.filter { seen.insert($0).inserted }
        // The keyboard always retains a way to change the input language.
        if !toolbar.contains(.language) { toolbar.insert(.language, at: 0) }
        toolbar = [.language] + toolbar.filter { $0 != .language }.prefix(3)
        fuzzyPairs.formIntersection(Set(FuzzyPinyin.availablePairs))
    }
}

public final class SettingsStore {
    public static let key = "clear.settings.v1"
    public let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> KeyboardSettings {
        guard let data = defaults.data(forKey: Self.key), var value = try? JSONDecoder().decode(KeyboardSettings.self, from: data) else { return KeyboardSettings() }
        value.sanitize()
        return value
    }
    public func save(_ settings: KeyboardSettings) {
        var clean = settings; clean.sanitize()
        guard let data = try? JSONEncoder().encode(clean) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
