import Foundation

/// Local memory of complete numbers deliberately entered with the keyboard.
/// Strings preserve leading zeroes and avoid numeric overflow. One completed
/// occurrence is enough for a full-value candidate; insertion remains explicit.
public struct NumericLexicon: Codable {
    private struct Entry: Codable { let value: String; var uses: Int; var selectedAt: Date }
    private var entries: [Entry] = []
    static let maximumDigits=64
    public init() {}
    static func isDigits(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    private static func isRememberable(_ value:String)->Bool {
        guard (4...maximumDigits).contains(value.utf8.count) else{return false}
        if isDigits(value){return true}
        return value.utf8.count==18 && (value.last=="X" || value.last=="x") && isDigits(String(value.dropLast()))
    }
    public mutating func record(_ value: String, now: Date = Date()) {
        guard Self.isRememberable(value) else { return }
        let uses = entries.first { $0.value == value }?.uses ?? 0
        entries.removeAll { $0.value == value }
        entries.insert(Entry(value: value, uses: min(10_000, uses + 1), selectedAt: now), at: 0)
        entries = Array(entries.prefix(512))
    }
    public func candidates(for prefix: String, limit: Int = 16) -> [Candidate] {
        guard limit>0,(1..<Self.maximumDigits).contains(prefix.utf8.count), Self.isDigits(prefix) else { return [] }
        return entries.filter { $0.uses >= 1 && Self.isRememberable($0.value) && $0.value.count > prefix.count && $0.value.hasPrefix(prefix) }
            .sorted { $0.uses == $1.uses ? $0.selectedAt > $1.selectedAt : $0.uses > $1.uses }
            .prefix(min(limit,64)).map { Candidate(text: $0.value, reading: $0.value, consumed: 0) }
    }
    /// Validate against the current prefix and saved full value after the UI has
    /// attached its request-local identity. Never compare Candidate.stableID here.
    public func completionSuffix(for candidate:Candidate,prefix:String)->String? {
        guard Self.isDigits(prefix),candidate.consumed==0,candidate.text==candidate.reading,
              let entry=entries.first(where:{$0.value==candidate.text && $0.uses>=1 && Self.isRememberable($0.value)}),
              entry.value.hasPrefix(prefix),entry.value.count>prefix.count else{return nil}
        return String(entry.value.dropFirst(prefix.count))
    }
    func merging(_ other:NumericLexicon)->NumericLexicon {
        var merged:[String:Entry]=[:]
        for entry in entries+other.entries {
            if let old=merged[entry.value] {
                merged[entry.value]=Entry(value:entry.value,uses:max(old.uses,entry.uses),selectedAt:max(old.selectedAt,entry.selectedAt))
            } else{merged[entry.value]=entry}
        }
        var value=NumericLexicon()
        value.entries=Array(merged.values.sorted {
            $0.selectedAt == $1.selectedAt ? $0.value<$1.value:$0.selectedAt>$1.selectedAt
        }.prefix(512))
        return value
    }
}

/// Track one contiguous explicit numeric run, not every prefix seen while typing.
/// Editing, a different field or an unverified cursor move invalidates the run.
public struct NumericInputRun {
    private var value = "", anchor = "", after = "", document = ""
    public var isEmpty: Bool { value.isEmpty }
    public init() {}
    public mutating func reset() { value = ""; anchor = ""; after = ""; document = "" }
    public func prefix(before: String, after: String, document: String) -> String? {
        guard !value.isEmpty,self.document==document,self.after==after,before.hasPrefix(anchor) else{return nil}
        let tail=before.dropFirst(anchor.count)
        guard tail.utf8.count<=value.utf8.count*2+4 else{return nil}
        var observed=""
        for scalar in tail.unicodeScalars {
            if scalar.value==32 || scalar.value==45{continue} // Host card-number grouping only.
            guard (48...57).contains(scalar.value) || scalar.value==88 || scalar.value==120 else{return nil}
            observed.unicodeScalars.append(scalar)
        }
        // Formatting can change, but no digit, X case, field or trailing context
        // may differ from the run that the user actually typed.
        return observed==value ? value:nil
    }
    public func canAppendIdentifierSuffix(_ text:String,before:String,after:String,document:String)->Bool {
        (text=="X" || text=="x") && value.utf8.count==17 && NumericLexicon.isDigits(value) &&
        prefix(before:before,after:after,document:document)==value
    }
    public mutating func append(_ digits: String, before: String, after: String, document: String) {
        if canAppendIdentifierSuffix(digits,before:before,after:after,document:document) {value+=digits;return}
        guard NumericLexicon.isDigits(digits) else { reset(); return }
        if prefix(before: before, after: after, document: document) == nil {
            reset()
            // Starting in the middle of an existing number would learn only
            // its tail as if it were a complete value.
            guard before.last.map({ !$0.isASCII || !$0.isNumber }) ?? true else { return }
            anchor = before; self.after = after; self.document = document
        }
        guard value.count + digits.count <= NumericLexicon.maximumDigits else { reset(); return }
        value += digits
    }
    public mutating func delete(before: String, after: String, document: String) {
        guard prefix(before: before, after: after, document: document) != nil else { reset(); return }
        value.removeLast()
        if value.isEmpty { reset() }
    }
    public mutating func complete(before: String, after: String, document: String) -> String? {
        let result = prefix(before: before, after: after, document: document)
        reset(); return result
    }
}
