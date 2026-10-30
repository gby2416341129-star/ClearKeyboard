import Foundation
#if canImport(V19NativeIME)
import V19NativeIME
#endif

public struct V19Choice: Sendable {
    public let raw: String
    public let selection: V19Selection
    public let recommended: Bool
}
public struct Candidate: Equatable, Sendable {
    public let text: String
    public let reading: String
    /// SDK raw UTF16 span for language candidates; numeric recall uses zero.
    public let consumed: Int
    public let score: Double
    public let nativeChoice: V19Choice?
    public var stableID: String {
        if let nativeChoice { return "v19:\(nativeChoice.selection.inputVersion):\(nativeChoice.selection.candidateID)" }
        return [text,reading,String(consumed)].map{String($0.utf8.count)+":"+$0}.joined()
    }
    public init(text: String, reading: String = "", consumed: Int, score: Double = 0, nativeChoice: V19Choice? = nil) {
        self.text=text; self.reading=reading; self.consumed=consumed; self.score=score; self.nativeChoice=nativeChoice
    }
    public static func == (a: Candidate, b: Candidate) -> Bool { a.stableID == b.stableID && a.score == b.score }
    func canConsume(_ raw: String) -> Bool {
        guard let nativeChoice, nativeChoice.raw == raw else { return false }
        let range=nativeChoice.selection.consumedRawUTF8Range
        return range.start == 0 && range.end > 0 && range.end <= raw.utf8.count
    }
}
