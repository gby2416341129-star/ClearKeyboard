import Foundation

public enum ClipboardSelection {
    public struct Token {
        public let text: String
        public let range: NSRange
    }
    public static func tokens(_ text: String) -> [Token] {
        let expression = try! NSRegularExpression(pattern: "[A-Za-z0-9]+(?:[.+#_/-][A-Za-z0-9]+)*|\\X")
        let string = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: string.length)).filter { !string.substring(with: $0.range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
            Token(text: string.substring(with: $0.range), range: $0.range)
        }
    }
    public static func text(_ source: String, tokens: [Token], from: Int, through: Int) -> String {
        let low = min(from, through), high = max(from, through)
        guard low >= 0, high < tokens.count else { return "" }
        let range = NSRange(location: tokens[low].range.location, length: NSMaxRange(tokens[high].range) - tokens[low].range.location)
        guard NSMaxRange(range) <= (source as NSString).length else { return "" }
        return (source as NSString).substring(with: range)
    }
}
