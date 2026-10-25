import Foundation

public enum ClipboardSelection {
    private static let expression = try! NSRegularExpression(pattern: "[A-Za-z0-9]+(?:[.+#_/-][A-Za-z0-9]+)*|\\X")
    public struct Token {
        public let text: String
        public let range: NSRange
    }
    public static func tokens(_ text: String) -> [Token] {
        let string = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: string.length)).filter { !string.substring(with: $0.range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
            Token(text: string.substring(with: $0.range), range: $0.range)
        }
    }
    public static func text(_ source: String, tokens: [Token], selected: Set<Int>) -> String {
        let indices = selected.filter { tokens.indices.contains($0) }.sorted()
        guard let first = indices.first else { return "" }
        var start = first, end = first, parts: [String] = []
        for index in indices.dropFirst() {
            if index == end + 1 { end = index }
            else { parts.append(text(source, tokens: tokens, from: start, through: end)); start = index; end = index }
        }
        parts.append(text(source, tokens: tokens, from: start, through: end))
        return parts.reduce("") { result, part in
            let separator = result.last?.isASCII == true && result.last?.isLetterOrNumber == true && part.first?.isASCII == true && part.first?.isLetterOrNumber == true ? " " : ""
            return result + separator + part
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

private extension Character { var isLetterOrNumber: Bool { isLetter || isNumber } }
