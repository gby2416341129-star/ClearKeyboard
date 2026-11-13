import Foundation

/// User-confirmed words, separate from the immutable neural model. A remembered
/// reading can be queried by full syllables, initials or a mixture of both.
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
        // Optional so older dictionaries decode without resetting user data.
        var explicitlyConfirmed: Bool? = nil
    }
    private(set) var entries: [Entry] = []
    public init() {}
    public mutating func record(_ candidate: Candidate, for raw: String, context: String = "", explicit: Bool = true, now: Date = Date()) {
        guard !candidate.text.isEmpty, candidate.text.unicodeScalars.count<=64,
              let consumed=Self.consumedPrefix(candidate,raw:raw),
              let codeKey=Self.codeKey(consumed) else {return}
        let old=entries.first{Self.codeKey(Self.storedCode($0)) == codeKey && $0.text == candidate.text}
        let selectedReading=Self.readingParts(candidate.reading,text:candidate.text)
        let reading=selectedReading?.joined(separator:" ") ?? (candidate.reading.isEmpty ? old?.reading ?? "" : candidate.reading)
        let initials=selectedReading.map{ $0.compactMap(\.first).map(String.init).joined() } ?? old?.initials
        var scopes=old?.selections ?? []
        if explicit {
            let key=Self.contextKey(context)
            let uses=(scopes.first{Self.contextKey($0.context)==key}?.uses ?? 0)+1
            scopes.removeAll{Self.contextKey($0.context)==key};scopes.insert(Scope(context:key,uses:min(10_000,uses),selectedAt:now),at:0)
            scopes=Array(scopes.prefix(8))
        }
        let confirmed=explicit || old?.explicitlyConfirmed == true || !(old?.selections?.isEmpty ?? true)
        entries.removeAll{Self.codeKey(Self.storedCode($0)) == codeKey && $0.text == candidate.text}
        entries.insert(Entry(code:consumed,text:candidate.text,reading:reading,consumed:consumed.utf16.count,
            uses:min(10_000,(old?.uses ?? 0)+1),selectedAt:now,initials:initials,path:old?.path,
            selections:scopes.isEmpty ? nil:scopes,explicitlyConfirmed:confirmed),at:0)
        // Do not truncate or discard historical user entries during the migration.
    }

    /// Only actively confirmed entries participate. A first deliberate tap or
    /// Space confirmation is sufficient; incidental automatic commits do not
    /// teach a new word. The caller binds a fresh localChoice to this request.
    public func candidates(for raw: String, context: String = "", limit: Int = 16) -> [Candidate] {
        guard limit>0,raw.utf8.count<=384,let key=Self.codeKey(raw) else{return []}
        let context=Self.contextKey(context)
        var matches:[(entry:Entry,kind:Int,context:Bool)]=[]
        for entry in entries {
            guard entry.explicitlyConfirmed == true || !(entry.selections?.isEmpty ?? true),
                  !entry.text.isEmpty,entry.text.unicodeScalars.count<=64 else{continue}
            let parts=Self.readingParts(entry.reading,text:entry.text)
            let full=parts?.joined()
            let initials=parts.map{$0.compactMap(\.first).map(String.init).joined()} ?? entry.initials.flatMap(Self.codeKey)
            let kind:Int
            if key==Self.codeKey(Self.storedCode(entry)) || key==full {kind=0}
            else if key==initials {kind=2}
            else if let parts,Self.matchesMixed(key,parts:parts) {kind=1}
            else{continue}
            let related = !context.isEmpty && (entry.selections?.contains{Self.contextKey($0.context)==context} ?? false)
            matches.append((entry,kind,related))
        }
        matches.sort {
            if $0.kind != $1.kind{return $0.kind<$1.kind}
            if $0.context != $1.context{return $0.context}
            if $0.entry.selectedAt != $1.entry.selectedAt{return $0.entry.selectedAt>$1.entry.selectedAt}
            if $0.entry.uses != $1.entry.uses{return $0.entry.uses>$1.entry.uses}
            return $0.entry.text<$1.entry.text
        }
        var seen=Set<String>(),result:[Candidate]=[]
        for match in matches where seen.insert(match.entry.text).inserted {
            result.append(Candidate(text:match.entry.text,reading:match.entry.reading,
                                    consumed:raw.utf16.count,score:Double(match.entry.uses)))
            if result.count>=min(limit,64){break}
        }
        return result
    }

    /// Merge complete snapshots without counting the same selection twice.
    /// The latest reading wins while prior explicit confirmation is retained.
    func merging(_ other:PersonalLexicon)->PersonalLexicon {
        var merged:[String:Entry]=[:]
        for entry in entries+other.entries {
            let stored=Self.storedCode(entry)
            let code=Self.codeKey(stored) ?? stored
            let key=String(code.utf8.count)+":"+code+entry.text
            guard let old=merged[key] else{merged[key]=entry;continue}
            let newest=entry.selectedAt>=old.selectedAt ? entry:old
            let previous=entry.selectedAt>=old.selectedAt ? old:entry
            let selectedCode=Self.storedCode(newest)
            let reading=Self.readingParts(newest.reading,text:newest.text) != nil ? newest.reading:previous.reading
            var scopes:[String:Scope]=[:]
            for scope in (old.selections ?? [])+(entry.selections ?? []) {
                let key=Self.contextKey(scope.context)
                if let prior=scopes[key] {
                    scopes[key]=Scope(context:key,uses:max(prior.uses,scope.uses),selectedAt:max(prior.selectedAt,scope.selectedAt))
                } else{scopes[key]=Scope(context:key,uses:scope.uses,selectedAt:scope.selectedAt)}
            }
            let selectedScopes=Array(scopes.values.sorted{$0.selectedAt>$1.selectedAt}.prefix(8))
            let confirmed=old.explicitlyConfirmed == true || entry.explicitlyConfirmed == true || !selectedScopes.isEmpty
            let initials=Self.readingParts(reading,text:newest.text).map{$0.compactMap(\.first).map(String.init).joined()} ?? newest.initials ?? previous.initials
            merged[key]=Entry(code:selectedCode,text:newest.text,reading:reading,consumed:selectedCode.utf16.count,
                uses:max(old.uses,entry.uses),selectedAt:max(old.selectedAt,entry.selectedAt),initials:initials,
                path:newest.path ?? previous.path,selections:selectedScopes.isEmpty ? nil:selectedScopes,
                explicitlyConfirmed:confirmed)
        }
        var value=PersonalLexicon()
        value.entries=merged.values.sorted {
            $0.selectedAt == $1.selectedAt ? $0.text<$1.text:$0.selectedAt>$1.selectedAt
        }
        return value
    }

    /// The stored query must be the span actually consumed by the selection,
    /// rather than the whole remaining composition during a single-character pick.
    private static func consumedPrefix(_ candidate:Candidate,raw:String)->String? {
        guard !raw.isEmpty,candidate.consumed>0,candidate.consumed<=raw.utf16.count else{return nil}
        if let choice=candidate.nativeChoice {
            let span=choice.selection.consumedRawUTF16Range
            guard choice.raw==raw,span.start==0,span.length==candidate.consumed else{return nil}
        } else if candidate.consumed != raw.utf16.count {return nil}
        guard let range=Range(NSRange(location:0,length:candidate.consumed),in:raw) else{return nil}
        return String(raw[range])
    }
    private static func storedCode(_ entry:Entry)->String {
        guard entry.consumed>0,entry.consumed<entry.code.utf16.count,
              let range=Range(NSRange(location:0,length:entry.consumed),in:entry.code) else{return entry.code}
        return String(entry.code[range])
    }
    private static func codeKey(_ value:String)->String? {
        var value=value.lowercased().replacingOccurrences(of:"u:",with:"v")
        for form in ["ü","ǖ","ǘ","ǚ","ǜ"]{value=value.replacingOccurrences(of:form,with:"v")}
        value=value.folding(options:.diacriticInsensitive,locale:Locale(identifier:"en_US_POSIX"))
        var output=""
        for scalar in value.unicodeScalars {
            if scalar.value==39{continue} // Explicit syllable separators.
            guard (97...122).contains(scalar.value) else{return nil}
            output.unicodeScalars.append(scalar)
        }
        return output.isEmpty ? nil:output
    }
    private static func readingParts(_ reading:String,text:String)->[String]? {
        let tokens=reading.split(whereSeparator:{$0.isWhitespace || $0=="'"})
        guard !tokens.isEmpty,tokens.count==text.unicodeScalars.count,tokens.count<=64 else{return nil}
        var output:[String]=[]
        for token in tokens {
            var token=String(token)
            if let last=token.last,"12345".contains(last){token.removeLast()}
            guard let syllable=codeKey(token),syllable.count<=6 else{return nil}
            output.append(syllable)
        }
        return output
    }
    private static func contextKey(_ context:String)->String {
        String(String.UnicodeScalarView(context.unicodeScalars.suffix(32)))
    }
    private static func matchesMixed(_ query:String,parts:[String])->Bool {
        let input=Array(query.utf8)
        guard input.count>=parts.count,input.count<=parts.reduce(0,{$0+$1.utf8.count}) else{return false}
        var positions:Set<Int>=[0]
        for part in parts {
            let letters=Array(part.utf8)
            var spellings=[letters,[letters[0]]]
            if part.hasPrefix("zh") || part.hasPrefix("ch") || part.hasPrefix("sh") {
                spellings.append(Array(letters.prefix(2)))
            }
            var next=Set<Int>()
            for position in positions {
                for spelling in spellings {
                    let end=position+spelling.count
                    if end<=input.count,input[position..<end].elementsEqual(spelling){next.insert(end)}
                }
            }
            if next.isEmpty{return false}
            positions=next
        }
        return positions.contains(input.count)
    }
}

/// Selection-chain bookkeeping. Native spans come from SDK receipts; a
/// validated local learned word consumes its bound composition in full.
public struct PhraseLearning {
    public struct Choice { public let raw: String; public let candidate: Candidate; public let context: String; public let explicit: Bool }
    private struct Chain {var raw,text,reading,remaining:String;let anchor,after,document:String;var allExplicit:Bool}
    private var chain: Chain?
    public init() {}
    public mutating func reset() {chain=nil}
    public mutating func select(_ candidate: Candidate, from composition: Composition,
                                before: String, after: String, document: String, explicit: Bool = false) -> Choice? {
        let selectedText:String,selectedReading:String,remaining:String,consumed:String
        if let choice=candidate.nativeChoice,choice.raw==composition.raw {
            let selection=choice.selection,span=selection.consumedRawUTF16Range
            guard span.start==0,span.length>0,span.length<=composition.raw.utf16.count,
                  let range=Range(NSRange(location:0,length:span.length),in:composition.raw) else {reset();return nil}
            consumed=String(composition.raw[range]);remaining=selection.remainingPinyin
            guard consumed+remaining==composition.raw else{reset();return nil}
            selectedText=selection.selectedText;selectedReading=selection.selectedReading
        } else if let local=candidate.localChoice,local.kind == .learned,local.raw==composition.raw,
                  candidate.consumed==composition.raw.utf16.count,!candidate.text.isEmpty {
            // The owner has already checked this entry against PersonalLexicon.
            // A recalled local word consumes this request's complete composition.
            consumed=composition.raw;remaining="";selectedText=candidate.text;selectedReading=candidate.reading
        } else {reset();return nil}
        let anchor=before.hasSuffix(composition.raw) ? String(before.dropLast(composition.raw.count)):before
        if let old=chain, old.document != document || old.after != after || old.anchor+old.text != anchor || old.remaining != composition.raw {reset()}
        var next=chain ?? Chain(raw:"",text:"",reading:"",remaining:"",anchor:anchor,after:after,document:document,allExplicit:true)
        next.raw += consumed;next.text += selectedText
        next.reading += (next.reading.isEmpty ? "":" ")+selectedReading
        next.remaining=remaining;next.allExplicit = next.allExplicit && explicit
        if next.remaining.isEmpty {
            reset();return Choice(raw:next.raw,candidate:Candidate(text:next.text,reading:next.reading,consumed:next.raw.utf16.count),context:next.anchor,explicit:next.allExplicit)
        }
        chain=next;return nil
    }
}
