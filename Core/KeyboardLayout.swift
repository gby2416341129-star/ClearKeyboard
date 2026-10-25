import Foundation

public enum KeyAction: Equatable {
    case text(String), literal(String), shift, delete, page(KeyboardPage), globe, language, space, enter
}
public struct KeyboardKey: Equatable {
    public let label: String
    public let action: KeyAction
    public let units: Double
    public let alternatives: [String]
    public init(_ label: String, _ action: KeyAction? = nil, units: Double = 1, alternatives: [String]? = nil) {
        self.label = label; self.action = action ?? .text(label); self.units = units
        self.alternatives = alternatives ?? KeyAlternatives.values(for: label)
    }
}
public struct KeyboardRow: Equatable {
    public let keys: [KeyboardKey]
    public let insetUnits: Double
    public init(_ keys: [KeyboardKey], inset: Double = 0) { self.keys = keys; self.insetUnits = inset }
}
public enum KeyboardLayout {
    /// System QWERTY positions. Appearance settings never reorder keys.
    public static func rows(page: KeyboardPage, uppercase: Bool = false, globe: Bool = true, language: InputLanguage = .chinese) -> [KeyboardRow] {
        func letters(_ value: String) -> [KeyboardKey] {
            value.map { KeyboardKey(uppercase ? String($0).uppercased() : String($0), .text(String($0))) }
        }
        let punctuation = [".": "。", ",": "，", "?": "？", "!": "！", ":": "：", ";": "；", "(": "（", ")": "）", "\"": "“", "'": "、"]
        func symbols(_ values: [String]) -> [KeyboardKey] {
            values.map { KeyboardKey(language == .chinese ? (punctuation[$0] ?? $0) : $0) }
        }
        func punctuationRow(_ switcher: KeyboardKey) -> KeyboardRow {
            // A Chinese full stop and a decimal point need separate visible
            // keys. Choosing Chinese punctuation must not remove decimals.
            let values = language == .chinese ? ["。", "，", "、", "？", "！", "."] : [".", ",", "?", "!", "'"]
            return KeyboardRow([switcher] + values.map { KeyboardKey($0, units: 7 / Double(values.count)) } + [KeyboardKey("⌫", .delete, units: 1.5)])
        }
        let rows: [KeyboardRow]
        switch page {
        case .letters:
            rows = [KeyboardRow(letters("qwertyuiop")), KeyboardRow(letters("asdfghjkl"), inset: 0.5),
                    KeyboardRow([KeyboardKey("⇧", .shift, units: 1.5)] + letters("zxcvbnm") + [KeyboardKey("⌫", .delete, units: 1.5)])]
        case .numbers:
            rows = [KeyboardRow("1234567890".map { KeyboardKey(String($0)) }),
                    KeyboardRow(symbols(["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""])),
                    punctuationRow(KeyboardKey("#+=", .page(.symbols), units: 1.5))]
        case .symbols:
            rows = [KeyboardRow(["[", "]", "{", "}", "#", "%", "^", "*", "+", "="].map { KeyboardKey($0) }),
                    KeyboardRow(symbols(["_", "\\", "|", "~", "<", ">", "€", "£", "¥", language == .chinese ? "”" : "•"])),
                    punctuationRow(KeyboardKey("123", .page(.numbers), units: 1.5))]
        }
        // Leading punctuation and trailing language switch balance the space key.
        // The extension uses iOS's separate globe; the in-app keyboard retains its globe.
        let mode = KeyboardKey(page == .letters ? "123" : "ABC", .page(page == .letters ? .numbers : .letters), units: globe ? 1.35 : 2)
        let comma = language == .chinese ? "，" : ","
        let period = language == .chinese ? "。" : "."
        let bottom = [mode] + (globe ? [KeyboardKey("◎", .globe, units: 0.75)] : []) + [
            KeyboardKey(comma, units: 0.9, alternatives: [comma, period]),
            KeyboardKey("空格", .space, units: globe ? 4 : 4.2),
            KeyboardKey("中", .language, units: 0.9),
            KeyboardKey("换行", .enter, units: globe ? 2.1 : 2)
        ]
        return rows + [KeyboardRow(bottom)]
    }
}
