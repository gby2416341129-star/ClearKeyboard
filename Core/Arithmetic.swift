import Foundation

public struct ArithmeticResult: Equatable {
    public let expression: String
    public let value: String
    public var candidates: [String] { [value, expression + "=" + value] }
}

/// Bounded recursive descent; never executes user text as code.
public enum InlineArithmetic {
    public static func result(in context: String) -> ArithmeticResult? {
        let allowed = Set("0123456789.+-xX×*/÷() ")
        let suffix = String(context.suffix(128).reversed().prefix { allowed.contains($0) }.reversed()).trimmingCharacters(in: .whitespaces)
        guard !suffix.isEmpty, suffix.count < 128, suffix.contains(where: { "+-xX×*/÷".contains($0) }) else { return nil }
        // Spaces may separate operators, never two pieces of the same number.
        let pieces = suffix.split(whereSeparator: \.isWhitespace)
        for (left, right) in zip(pieces, pieces.dropFirst()) {
            if let a = left.last, let b = right.first,
               (a.isNumber || a == "."), (b.isNumber || b == ".") { return nil }
        }
        let normalized = suffix.replacingOccurrences(of: "X", with: "*").replacingOccurrences(of: "x", with: "*").replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/").filter { !$0.isWhitespace }
        var parser = Parser(Array(normalized))
        guard let value = parser.expression(), parser.index == parser.characters.count, parser.operations > 0,
              value.isFinite, abs(value) <= 1e15 else { return nil }
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal; formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 10; formatter.minimumFractionDigits = 0
        guard let output = formatter.string(from: NSNumber(value: value == 0 ? 0 : value)) else { return nil }
        return ArithmeticResult(expression: suffix, value: output)
    }
    private struct Parser {
        let characters: [Character]
        var index = 0, operations = 0, depth = 0
        init(_ characters: [Character]) { self.characters = characters }
        mutating func take(_ chars: String) -> Character? {
            guard index < characters.count, chars.contains(characters[index]) else { return nil }
            let value = characters[index]; index += 1; return value
        }
        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let op = take("+-") { guard let rhs = term() else { return nil }; operations += 1; value = op == "+" ? value + rhs : value - rhs }
            return value
        }
        mutating func term() -> Double? {
            guard var value = factor() else { return nil }
            while let op = take("*/") {
                guard let rhs = factor(), op != "/" || rhs != 0 else { return nil }
                operations += 1; value = op == "*" ? value * rhs : value / rhs
            }
            return value
        }
        mutating func factor() -> Double? {
            if let sign = take("+-") { guard let number = factor() else { return nil }; return sign == "-" ? -number : number }
            if take("(") != nil {
                depth += 1; guard depth <= 8, let number = expression(), take(")") != nil else { return nil }
                depth -= 1; return number
            }
            let start = index
            while index < characters.count, "0123456789.".contains(characters[index]) { index += 1 }
            guard index > start else { return nil }
            return Double(String(characters[start..<index]))
        }
    }
}
