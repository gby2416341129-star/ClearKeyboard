import Foundation

public enum FuzzyPinyin {
    public static let availablePairs = ["z/zh", "c/ch", "s/sh", "n/l", "f/h", "an/ang", "en/eng", "in/ing"]
    public static func normalize(_ input: String) -> String {
        input.lowercased().replacingOccurrences(of: "ü", with: "v").unicodeScalars
            .filter { (97...122).contains($0.value) }.map(String.init).joined()
    }
    /// Bounded variants; edit one syllable boundary at a time instead of exponential rewrites.
    public static func variants(_ input: String, enabled: Set<String>, limit: Int = 12) -> [String] {
        var result = [input], seen: Set<String> = [input]
        for pair in availablePairs where enabled.contains(pair) {
            let parts = pair.split(separator: "/").map(String.init)
            for (from, to) in [(parts[0], parts[1]), (parts[1], parts[0])] {
                var search = input.startIndex..<input.endIndex
                while let range = input.range(of: from, range: search) {
                    // Do not turn zhong into zh + hong, or an into ang + g.
                    let next = range.upperBound < input.endIndex ? input[range.upperBound] : nil
                    let valid = !(to.count > from.count && next == (from.count == 1 ? "h" : "g"))
                    if valid {
                        var changed = input; changed.replaceSubrange(range, with: to)
                        if seen.insert(changed).inserted { result.append(changed) }
                        if result.count >= limit { return result }
                    }
                    guard range.upperBound < input.endIndex else { break }
                    search = range.upperBound..<input.endIndex
                }
            }
        }
        return result
    }
}
