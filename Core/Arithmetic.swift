import Foundation

public struct ArithmeticResult: Equatable {
    public let expression: String
    public let value: String
    /// Exact host suffix owned by this suggestion, including trailing spaces or =.
    public let consumedInput:String
    public var candidates: [String] { [value, expression + "=" + value] }
    public init(expression:String,value:String,consumedInput:String?=nil) {
        self.expression=expression;self.value=value;self.consumedInput=consumedInput ?? expression
    }
}

/// Bounded recursive descent; never executes user text as code.
public enum InlineArithmetic {
    private static let allowed=Set("0123456789.+-xX×*/÷() =０１２３４５６７８９．＋－＊／（）＝")
    private static func suffix(in context:String)->String? {
        let raw=String(context.suffix(128).reversed().prefix{allowed.contains($0)}.reversed())
        let value=String(raw.drop(while:{$0.isWhitespace}))
        return value.isEmpty || raw.count>=128 ? nil:value
    }
    private static func normalized(_ value:String)->String {
        let replacements:[Character:Character]=["０":"0","１":"1","２":"2","３":"3","４":"4","５":"5","６":"6","７":"7","８":"8","９":"9",
            "．":".","＋":"+","－":"-","＊":"*","／":"/","（":"(","）":")","＝":"=","X":"*","x":"*","×":"*","÷":"/"]
        return String(value.map{replacements[$0] ?? $0})
    }
    /// This is only lexical routing for an in-progress expression. It does not
    /// execute a parser or turn a trailing operand into a remembered phone number.
    public static func isExpressionDraft(in context:String)->Bool {
        guard let suffix=suffix(in:context) else{return false}
        let value=normalized(suffix)
        return value.contains(where:{$0.isASCII && $0.isNumber}) && value.contains(where:{"+-*/.".contains($0)})
    }
    public static func isOperatorInput(_ text:String)->Bool {
        !text.isEmpty && normalized(text).allSatisfy{"+-*/().=".contains($0)}
    }
    public static func result(in context: String) -> ArithmeticResult? {
        guard let consumed=suffix(in:context) else{return nil}
        var expression=consumed.trimmingCharacters(in:.whitespaces)
        if expression.last=="=" || expression.last=="＝" {expression.removeLast();expression=expression.trimmingCharacters(in:.whitespaces)}
        let source=normalized(expression)
        guard !source.isEmpty, source.contains(where: { "+-*/".contains($0) }) else { return nil }
        // Spaces may separate operators, never two pieces of the same number.
        let pieces = source.split(whereSeparator: \.isWhitespace)
        for (left, right) in zip(pieces, pieces.dropFirst()) {
            if let a = left.last, let b = right.first,
               (a.isNumber || a == "."), (b.isNumber || b == ".") { return nil }
        }
        let compact=source.filter{!$0.isWhitespace}
        var parser = Parser(Array(compact))
        guard let value = parser.expression(), parser.index == parser.characters.count, parser.operations > 0,
              value.isFinite, abs(value) <= 1e15 else { return nil }
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal; formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 10; formatter.minimumFractionDigits = 0
        guard let output = formatter.string(from: NSNumber(value: value == 0 ? 0 : value)) else { return nil }
        return ArithmeticResult(expression:expression,value:output,consumedInput:consumed)
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
