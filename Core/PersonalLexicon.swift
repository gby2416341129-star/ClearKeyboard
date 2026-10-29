import Foundation

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
        var path: CandidatePath? = nil
        var selections: [Scope]? = nil
    }
    private(set) var entries: [Entry] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case entries }
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        entries=Array(try c.decode([Entry].self,forKey:.entries).prefix(512))
        for i in entries.indices where entries[i].initials==nil {
            if entries[i].consumed==FuzzyPinyin.normalize(entries[i].code).count {
                entries[i].initials=Self.initials(text:entries[i].text,reading:entries[i].reading)
            }
        }
    }
    private static func key(_ raw: String) -> String {
        raw.lowercased().filter{$0.isASCII && ($0.isLetter || $0=="'")}
    }
    static func contextKey(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.suffix(24)))
    }
    private static func personContext(_ text: String) -> Bool {
        ["联系","找","问问","请教","咨询","通知","发给","交给","麻烦","请问","拜托","叫"].contains{text.hasSuffix($0)}
    }
    private static func contextMatches(_ old: String,_ current: String) -> Bool {
        if old==current{return true}
        if old.isEmpty || current.isEmpty{return false}
        if personContext(old) && personContext(current){return true}
        let a=Array(old.unicodeScalars),b=Array(current.unicodeScalars)
        let length=min(6,a.count,b.count)
        return length>=4 && a.suffix(length).elementsEqual(b.suffix(length))
    }
    public mutating func record(_ candidate: Candidate, for raw: String, context: String = "", explicit: Bool = true, now: Date = Date()) {
        let code=Self.key(raw),old=entries.first{$0.code==Self.key(raw) && $0.text==candidate.text}
        guard !code.isEmpty,code.count<=Composition.maximumQueryLength,candidate.consumed>0,
              candidate.consumed<=FuzzyPinyin.normalize(code).count,!candidate.text.isEmpty else{return}
        var scopes=old?.selections ?? []
        if explicit {
            let current=Self.contextKey(context),uses=(scopes.first{$0.context==current}?.uses ?? 0)+1
            scopes.removeAll{$0.context==current};scopes.insert(Scope(context:current,uses:min(10_000,uses),selectedAt:now),at:0)
            scopes=Array(scopes.prefix(8))
        }
        entries.removeAll{$0.code==code && $0.text==candidate.text}
        entries.insert(Entry(code:code,text:candidate.text,reading:candidate.reading,consumed:candidate.consumed,
            uses:min(10_000,(old?.uses ?? 0)+1),selectedAt:explicit ? now:(old?.selectedAt ?? .distantPast),
            initials:candidate.consumed==FuzzyPinyin.normalize(code).count ? Self.initials(text:candidate.text,reading:candidate.reading):nil,
            path:candidate.path ?? old?.path,selections:scopes.isEmpty ? nil:scopes),at:0)
        entries=Array(entries.prefix(512))
    }
    public func candidates(for raw: String, context: String = "") -> [Candidate] {
        guard raw.utf8.count<=Composition.maximumQueryLength else{return []}
        let code=Self.key(raw),ctx=Self.contextKey(context)
        guard !code.isEmpty else{return []}
        struct Found {let entry:Entry;let consumed:Int;let scope:Scope?;let alias:Bool}
        var found:[Found]=[]
        for e in entries {
            let alias=e.code != code && e.initials==code
            guard e.code==code || alias else{continue}
            let count=alias ? FuzzyPinyin.normalize(code).count:e.consumed
            let scope=e.selections?.first{Self.contextMatches($0.context,ctx)}
            found.append(Found(entry:e,consumed:count,scope:scope,alias:alias))
        }
        found.sort {
            if ($0.scope != nil) != ($1.scope != nil){return $0.scope != nil}
            if let a=$0.scope,let b=$1.scope {return a.selectedAt==b.selectedAt ? a.uses>b.uses:a.selectedAt>b.selectedAt}
            return $0.entry.uses==$1.entry.uses ? $0.entry.selectedAt>$1.entry.selectedAt:$0.entry.uses>$1.entry.uses
        }
        var seen=Set<String>()
        return Array(found.filter{seen.insert($0.entry.text).inserted}.prefix(4).map { item in
            let e=item.entry,strong=item.scope != nil && item.consumed==FuzzyPinyin.normalize(code).count
            let preference=PersonalPreference(code:code,context:ctx,uses:e.uses,isExplicitContextMatch:strong)
            return Candidate(text:e.text,reading:e.reading,consumed:item.consumed,score:item.alias ? 4:Double(min(3,e.uses)),
                path:e.path?.learned(raw:raw,consumed:item.consumed,uses:e.uses,initials:item.alias),personalPreference:preference)
        })
    }
    private static func initials(text: String, reading: String) -> String? {
        let parts=reading.split(separator:" ")
        guard (2...32).contains(text.count),parts.count==text.count,
              text.unicodeScalars.allSatisfy({(0x3400...0x9fff).contains($0.value) || (0x20000...0x3347f).contains($0.value)}),
              parts.allSatisfy({!$0.isEmpty && $0.allSatisfy{$0.isASCII && $0.isLowercase && $0.isLetter}}) else{return nil}
        return String(parts.compactMap(\.first))
    }
    public static func merging(_ preferred:[Candidate],into words:[Candidate],limit:Int)->[Candidate] {
        var seen=Set<String>()
        let choices=preferred.filter{seen.insert($0.text).inserted}.map { c in
            guard c.path==nil,let p=words.first(where:{$0.text==c.text && $0.consumed==c.consumed})?.path else{return c}
            return c.withPath(p)
        }
        let ranks=Dictionary(words.enumerated().map{($0.element.text,$0.offset)},uniquingKeysWith:min)
        var result=words.filter{!seen.contains($0.text)};seen.removeAll();result=result.filter{seen.insert($0.text).inserted}
        for (offset,c) in choices.enumerated(){
            let gradual=(1...3).contains(c.score) ? 3-Int(c.score):0
            let position=c.personalPreference?.isExplicitContextMatch==true ? min(offset,result.count):min(ranks[c.text] ?? Int.max,gradual+offset,result.count)
            result.insert(c,at:position)
        }
        return Array(result.prefix(max(1,limit)))
    }
    public func recentCorrections(for raw: String, now: Date = Date()) -> [Candidate] {
        let code=Self.key(raw),typed=Array(code)
        guard code.count>=8,!code.contains("'") else{return []}
        let rows: [[Character]]=[Array("qwertyuiop"),Array("asdfghjkl"),Array("zxcvbnm")]
        func adjacent(_ a:Character,_ b:Character)->Bool {rows.contains{row in guard let x=row.firstIndex(of:a),let y=row.firstIndex(of:b) else{return false};return abs(x-y)==1}}
        return entries.prefix(12).compactMap { e in
            let age=now.timeIntervalSince(e.selectedAt)
            guard age>=0,age<=120,e.code.count==code.count,e.consumed==code.count,!e.reading.isEmpty,
                  e.code.prefix(4)==code.prefix(4),e.text.allSatisfy({!$0.isASCII}) else{return nil}
            var changes=0
            for (a,b) in zip(e.code,typed) where a != b {guard adjacent(a,b) else{return nil};changes+=1;if changes>2{return nil}}
            guard changes>0 else{return nil}
            return Candidate(text:e.text,reading:e.reading,consumed:code.count,score:150,
                personalPreference:PersonalPreference(code:code,context:"",uses:e.uses,isExplicitContextMatch:false))
        }
    }
}

/// A phrase can be confirmed a character at a time. Keep that transaction only
/// while the same document, unmarked anchor and remaining spelling still agree.
/// No host text is polled here; callers provide their existing editor snapshot.
public struct PhraseLearning {
    public struct Choice { public let raw: String; public let candidate: Candidate; public let context: String; public let explicit: Bool }
    private struct Chain {
        var raw: String; var text: String; var reading: String; var remaining: String
        let anchor: String; let after: String; let document: String; var allExplicit: Bool
    }
    private var chain: Chain?
    public init() {}
    public mutating func reset() { chain = nil }
    public mutating func select(_ candidate: Candidate, from composition: Composition,
                                before: String, after: String, document: String, explicit: Bool = false) -> Choice? {
        guard !composition.isEmpty, candidate.consumed > 0, candidate.consumed <= composition.normalized.count,
              !candidate.text.isEmpty, candidate.text.allSatisfy({ !$0.isASCII }),
              candidate.reading.split(separator: " ").count == candidate.text.count else { reset(); return nil }
        let anchor = before.hasSuffix(composition.raw) ? String(before.dropLast(composition.raw.count)) : before
        if let old = chain, old.document != document || old.after != after || old.anchor + old.text != anchor ||
            old.remaining.isEmpty || !composition.raw.hasPrefix(old.remaining) { reset() }
        var remaining = composition; remaining.consume(candidate.consumed)
        let source = String(composition.raw.dropLast(remaining.raw.count))
        var next = chain ?? Chain(raw: "", text: "", reading: "", remaining: "", anchor: anchor, after: after, document: document, allExplicit: true)
        next.raw += source; next.text += candidate.text; next.allExplicit = next.allExplicit && explicit
        next.reading += (next.reading.isEmpty ? "" : " ") + candidate.reading
        next.remaining = remaining.raw
        guard next.raw.count <= Composition.maximumQueryLength, next.text.count <= 32 else { reset(); return nil }
        if remaining.isEmpty {
            reset()
            return Choice(raw: next.raw, candidate: Candidate(text: next.text, reading: next.reading,
                consumed: FuzzyPinyin.normalize(next.raw).count), context: CandidateLanguageContext.tail(next.anchor), explicit: next.allExplicit)
        }
        chain = next; return nil
    }
}
