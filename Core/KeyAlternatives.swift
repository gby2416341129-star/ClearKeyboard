import Foundation

/// Literal choices never enter the pinyin decoder. The base choice remains under
/// the held key, including when the popup is clamped against a screen edge.
public enum KeyAlternatives {
    public static func values(for key: String) -> [String] {
        let digits = Array("零壹贰叁肆伍陆柒捌玖").map(String.init)
        let circled = Array("⓪①②③④⑤⑥⑦⑧⑨").map(String.init)
        let filled = ["⓿", "❶", "❷", "❸", "❹", "❺", "❻", "❼", "❽", "❾"]
        if key.count == 1, let n = Int(key), (0...9).contains(n) { return [digits[n], filled[n], circled[n], key] }
        let families = [
            ["<", "《", "〈", "【", "（", "(", "[", "{"],
            [">", "》", "〉", "】", "）", ")", "]", "}"],
            ["-", "–", "—", "_", "−"], ["/", "\\", "／", "÷"],
            [":", "：", ";", "；"], [";", "；", ":", "："],
            ["$", "¥", "€", "£", "₩", "¢"], ["&", "＆", "§"],
            ["@", "＠"], ["%", "‰", "％"], ["*", "×", "＊", "·"],
            ["+", "＋", "±"], ["=", "＝", "≠", "≈"],
            ["\"", "“", "”", "«", "»"], ["'", "‘", "’", "`"],
            [".", "。", "…", "·"], [",", "，", "、"],
            ["?", "？", "¿"], ["!", "！", "¡"], ["~", "～", "≈"],
            ["#", "＃", "№"], ["^", "↑", "ˆ"], ["|", "｜", "¦"]
        ]
        return families.first { $0.contains(key) } ?? []
    }
    public static func choices(for key: KeyboardKey, language: InputLanguage) -> [String] {
        if case .text(let text) = key.action,
           text.utf8.count == 1, let byte = text.utf8.first,
           (65...90).contains(byte) || (97...122).contains(byte) {
            return [text.uppercased(), text.lowercased()]
        }
        return key.alternatives
    }
    public static func initialIndex(for key: KeyboardKey, choices: [String], language: InputLanguage) -> Int {
        if language == .chinese, choices.count == 2, choices[0].lowercased() == choices[1] { return 0 }
        return choices.firstIndex(of: key.label) ?? 0
    }
}
