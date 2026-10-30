import Foundation

/// Preserve historical records and keep recording explicit selections. The
/// trial SDK does not accept learning features; these records never re-rank it.
public struct PersonalLexicon: Codable {
    public struct Scope: Codable {
        var context: String
        var uses: Int
        var selectedAt: Date
    }
    public struct Entry: Codable {
        let code: String
        let text: String
        let reading: String
        let consumed: Int
        var uses: Int
        var selectedAt: Date
        var initials: String?
        var path: ArchivedUserValue? = nil
        var selections: [Scope]? = nil
    }
    private(set) var entries: [Entry] = []
    public init() {}
    public mutating func record(_ candidate: Candidate, for raw: String, context: String = "", explicit: Bool = true, now: Date = Date()) {
        guard !raw.isEmpty, !candidate.text.isEmpty else {return}
        let old=entries.first{$0.code == raw && $0.text == candidate.text}
        var scopes=old?.selections ?? []
        if explicit {
            let uses=(scopes.first{$0.context==context}?.uses ?? 0)+1
            scopes.removeAll{$0.context==context};scopes.insert(Scope(context:context,uses:min(10_000,uses),selectedAt:now),at:0)
            scopes=Array(scopes.prefix(8))
        }
        entries.removeAll{$0.code == raw && $0.text == candidate.text}
        entries.insert(Entry(code:raw,text:candidate.text,reading:candidate.reading,consumed:candidate.consumed,
            uses:min(10_000,(old?.uses ?? 0)+1),selectedAt:now,initials:old?.initials,path:old?.path,selections:scopes.isEmpty ? nil:scopes),at:0)
        // Do not truncate or discard historical user entries during the migration.
    }
}

/// Selection-chain bookkeeping; input boundaries come only from SDK receipts.
public struct PhraseLearning {
    public struct Choice { public let raw: String; public let candidate: Candidate; public let context: String; public let explicit: Bool }
    private struct Chain {var raw,text,reading,remaining:String;let anchor,after,document:String;var allExplicit:Bool}
    private var chain: Chain?
    public init() {}
    public mutating func reset() {chain=nil}
    public mutating func select(_ candidate: Candidate, from composition: Composition,
                                before: String, after: String, document: String, explicit: Bool = false) -> Choice? {
        guard let choice=candidate.nativeChoice, choice.raw==composition.raw else {reset();return nil}
        let selection=choice.selection
        let anchor=before.hasSuffix(composition.raw) ? String(before.dropLast(composition.raw.count)):before
        if let old=chain, old.document != document || old.after != after || old.anchor+old.text != anchor || old.remaining != composition.raw {reset()}
        var next=chain ?? Chain(raw:"",text:"",reading:"",remaining:"",anchor:anchor,after:after,document:document,allExplicit:true)
        next.raw += String(composition.raw.dropLast(selection.remainingPinyin.count));next.text += selection.selectedText
        next.reading += (next.reading.isEmpty ? "":" ")+selection.selectedReading
        next.remaining=selection.remainingPinyin;next.allExplicit = next.allExplicit && explicit
        if next.remaining.isEmpty {
            reset();return Choice(raw:next.raw,candidate:Candidate(text:next.text,reading:next.reading,consumed:next.raw.utf16.count),context:next.anchor,explicit:next.allExplicit)
        }
        chain=next;return nil
    }
}
