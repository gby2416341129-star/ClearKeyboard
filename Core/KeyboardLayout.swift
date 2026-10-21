import Foundation

public enum KeyAction: Equatable {
    case text(String), shift, delete, page(KeyboardPage), globe, language, space, enter
}
public struct KeyboardKey: Equatable {
    public let label: String
    public let action: KeyAction
    public let units: Double
    public init(_ label: String, _ action: KeyAction? = nil, units: Double = 1) {
        self.label = label; self.action = action ?? .text(label); self.units = units
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
        let mode = KeyboardKey(page == .letters ? "123" : "ABC", .page(page == .letters ? .numbers : .letters), units: globe ? 1 : 1.2)
        // Equal side totals keep both the space face and its touch target on the midline.
        // The optional in-app globe stays on the leading side; iOS owns it in the extension.
        let side = globe ? 2.8 : 2.4
        let bottom = [mode] + (globe ? [KeyboardKey("◎", .globe, units: 0.85)] : []) +
            [KeyboardKey("中", .language, units: globe ? 0.95 : 1.2), KeyboardKey("空格", .space, units: 10 - side * 2), KeyboardKey("换行", .enter, units: side)]
        return rows + [KeyboardRow(bottom)]
    }
}
