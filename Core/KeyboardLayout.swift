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
    public static func rows(page: KeyboardPage, uppercase: Bool = false, globe: Bool = true) -> [KeyboardRow] {
        func letters(_ value: String) -> [KeyboardKey] {
            value.map { KeyboardKey(uppercase ? String($0).uppercased() : String($0), .text(String($0))) }
        }
        let rows: [KeyboardRow]
        switch page {
        case .letters:
            rows = [KeyboardRow(letters("qwertyuiop")), KeyboardRow(letters("asdfghjkl"), inset: 0.5),
                    KeyboardRow([KeyboardKey("⇧", .shift, units: 1.5)] + letters("zxcvbnm") + [KeyboardKey("⌫", .delete, units: 1.5)])]
        case .numbers:
            rows = [KeyboardRow("1234567890".map { KeyboardKey(String($0)) }),
                    KeyboardRow(["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""].map { KeyboardKey($0) }),
                    KeyboardRow([KeyboardKey("#+=", .page(.symbols), units: 1.5)] + [".", ",", "?", "!", "'"].map { KeyboardKey($0, units: 1.4) } + [KeyboardKey("⌫", .delete, units: 1.5)])]
        case .symbols:
            rows = [KeyboardRow(["[", "]", "{", "}", "#", "%", "^", "*", "+", "="].map { KeyboardKey($0) }),
                    KeyboardRow(["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"].map { KeyboardKey($0) }),
                    KeyboardRow([KeyboardKey("123", .page(.numbers), units: 1.5)] + [".", ",", "?", "!", "'"].map { KeyboardKey($0, units: 1.4) } + [KeyboardKey("⌫", .delete, units: 1.5)])]
        }
        let mode = KeyboardKey(page == .letters ? "123" : "ABC", .page(page == .letters ? .numbers : .letters), units: 1.25)
        let bottom = [mode] + (globe ? [KeyboardKey("◎", .globe, units: 1)] : []) +
            [KeyboardKey("空格", .space, units: globe ? 4.35 : 5.35), KeyboardKey("中", .language, units: 1.15), KeyboardKey("换行", .enter, units: 2.25)]
        return rows + [KeyboardRow(bottom)]
    }
}
