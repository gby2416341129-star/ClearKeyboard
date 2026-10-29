import Foundation

public enum InputMatchType: String, Codable, Sendable {
    case exact, initials, mixed, prefix, fuzzy, correction, association, literal
}
public enum InputEditKind: String,Codable,Sendable {
    case substitution,insertion,deletion,transposition,fuzzyInitial,fuzzyFinal
}
public struct InputEdit: Equatable,Codable,Sendable {
    public let kind: InputEditKind
    public let inputStart: Int
    public let inputEnd: Int
    public let syllableIndex: Int
    public let typed: String
    public let replacement: String
    public let cost: Float
    public let searchPenalty: Float
}
/// Native evidence, independent of any neural backend. Offsets and segments
/// refer to the actual raw Unicode scalar stream; consumed remains the public
/// normalized-letter count used by the existing composition transaction.
public struct CandidatePath: Equatable, Codable, Sendable {
    public let kind: InputMatchType
    public let frequency: Float
    public let editCost: Float
    public let consumedStart: Int
    public let consumedEnd: Int
    public let segments: [Int]
    public let baseRank: Int
    public let edits: [InputEdit]?
    public let matchKinds: [InputMatchType]?
    public let pronunciationCost: Float?
    public let expandsCompleteSyllable: Bool?
    public init(kind: InputMatchType, frequency: Float, editCost: Float, consumedStart: Int = 0,
                consumedEnd: Int, segments: [Int] = [], baseRank: Int = 0,
                edits: [InputEdit]? = nil, matchKinds: [InputMatchType]? = nil, pronunciationCost: Float? = nil, expandsCompleteSyllable: Bool? = nil) {
        self.kind=kind;self.frequency=frequency;self.editCost=editCost
        self.consumedStart=consumedStart;self.consumedEnd=consumedEnd;self.segments=segments;self.baseRank=baseRank
        self.edits=edits;self.matchKinds=matchKinds;self.pronunciationCost=pronunciationCost;self.expandsCompleteSyllable=expandsCompleteSyllable
    }
    func ranked(_ rank: Int) -> CandidatePath {
        CandidatePath(kind:kind,frequency:frequency,editCost:editCost,consumedStart:consumedStart,
                      consumedEnd:consumedEnd,segments:segments,baseRank:rank,edits:edits,matchKinds:matchKinds,pronunciationCost:pronunciationCost,expandsCompleteSyllable:expandsCompleteSyllable)
    }
    func learned(raw: String, consumed: Int, uses: Int, initials: Bool) -> CandidatePath {
        var ends: [Int]=[]
        for (offset,scalar) in raw.unicodeScalars.enumerated() {
            if scalar.isASCII && CharacterSet.letters.contains(scalar) { ends.append(offset+1) }
            else if scalar == "'", !ends.isEmpty { ends[ends.count-1]=offset+1 }
        }
        let end=consumed>0 && consumed<=ends.count ? ends[consumed-1] : 0
        return CandidatePath(kind:initials ? .initials:kind,frequency:Float(uses),editCost:initials ? 0:editCost,
            consumedEnd:end,segments:initials ? Array(ends.prefix(consumed)):segments.filter{$0<=end},baseRank:baseRank,
            edits:initials ? nil:edits,matchKinds:initials ? [.initials]:matchKinds,pronunciationCost:pronunciationCost,expandsCompleteSyllable:initials ? false:expandsCompleteSyllable)
    }
}
public struct PersonalPreference: Equatable, Codable, Sendable {
    public let code: String
    public let context: String
    public let uses: Int
    public let isExplicitContextMatch: Bool
}
public struct Candidate: Equatable, Sendable {
    public let text: String
    public let reading: String
    public let consumed: Int
    public let score: Double
    public let path: CandidatePath?
    public let personalPreference: PersonalPreference?
    public var stableID: String {
        // Length-prefix fields: user text may itself contain any separator.
        let segmentsKey=path?.segments.map(String.init).joined(separator:",") ?? ""
        let operations=path?.edits ?? []
        let editKeys:[String]=operations.map { e in
            let positions=[String(e.inputStart),String(e.inputEnd),String(e.syllableIndex)].joined(separator:":")
            return [e.kind.rawValue,positions,e.typed,e.replacement].joined(separator:":")
        }
        let fields:[String]=[text,reading,String(consumed),String(path?.consumedStart ?? 0),String(path?.consumedEnd ?? 0),
                             path?.kind.rawValue ?? "unmapped",segmentsKey,editKeys.joined(separator:";"),path?.expandsCompleteSyllable == true ? "tail-expansion":"faithful"]
        return fields.map{String($0.utf8.count)+":"+$0}.joined()
    }
    public init(text: String, reading: String = "", consumed: Int, score: Double = 0, path: CandidatePath? = nil, personalPreference: PersonalPreference? = nil) {
        self.text=text;self.reading=reading;self.consumed=consumed;self.score=score;self.path=path;self.personalPreference=personalPreference
    }
    public static func == (a: Candidate, b: Candidate) -> Bool {
        a.stableID==b.stableID && a.score==b.score
    }
    func canConsume(_ raw: String) -> Bool {
        guard consumed>0,consumed<=FuzzyPinyin.normalize(raw).count,let path,
              path.consumedStart==0,path.consumedEnd>0,path.consumedEnd<=raw.unicodeScalars.count else{return false}
        let prefix=String(String.UnicodeScalarView(raw.unicodeScalars.prefix(path.consumedEnd)))
        return FuzzyPinyin.normalize(prefix).count==consumed && path.segments.last==path.consumedEnd
    }
    func inDraft(_ raw:String)->Candidate {
        guard let path,path.kind == .exact,consumed<FuzzyPinyin.normalize(raw).count else{return self}
        return withPath(CandidatePath(kind:.prefix,frequency:path.frequency,editCost:path.editCost,
            consumedStart:path.consumedStart,consumedEnd:path.consumedEnd,segments:path.segments,baseRank:path.baseRank,
            edits:path.edits,matchKinds:path.matchKinds,pronunciationCost:path.pronunciationCost,expandsCompleteSyllable:path.expandsCompleteSyllable))
    }
    func completes(_ raw:String)->Bool {
        canConsume(raw) && consumed==FuzzyPinyin.normalize(raw).count && path?.kind != .literal &&
            (path?.expandsCompleteSyllable != true || personalPreference?.isExplicitContextMatch == true)
    }
    func withPath(_ path: CandidatePath?) -> Candidate {
        Candidate(text:text,reading:reading,consumed:consumed,score:score,path:path,personalPreference:personalPreference)
    }
}
