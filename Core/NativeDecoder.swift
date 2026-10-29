import Foundation
#if SWIFT_PACKAGE
import CNative
#endif
private final class NativeCancellation {
    let cancelled: () -> Bool
    init(_ cancelled: @escaping () -> Bool) { self.cancelled=cancelled }
}
private let nativeCancelled: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { value in
    guard let value else { return 0 }
    return Unmanaged<NativeCancellation>.fromOpaque(value).takeUnretainedValue().cancelled() ? 1:0
}
final class NativeDecoder {
    static let revision=89
    private static let ownerLock=NSLock()
    private static var owner: NativeDecoder?
    private let handle: OpaquePointer
    enum LoadError: LocalizedError {
        case resources, runtime(String)
        var errorDescription: String? {
            switch self { case .resources:return "缺少自研拼音索引";case .runtime(let value):return value }
        }
    }
    static func bundled() throws -> NativeDecoder {
        ownerLock.lock();defer{ownerLock.unlock()}
        if let owner{return owner}
        let value=try NativeDecoder();owner=value;return value
    }
    private init() throws {
        guard let url=InputResources.url("native",extension:"cklx",directory:"Pinyin") else {throw LoadError.resources}
        guard let native=ck_native_create(url.path) else {throw LoadError.runtime(String(cString:ck_native_error()))}
        handle=native
    }
    deinit {ck_native_destroy(handle)}
    func candidates(_ raw: String, context: String = "", fuzzy: Set<String> = [], correction: Bool = true,
                    characterOnly: Bool = false, limit: Int = 32, cancelled: () -> Bool) -> [Candidate] {
        guard !cancelled() else{return []}
        let mask=FuzzyPinyin.availablePairs.enumerated().reduce(UInt32(0)) { fuzzy.contains($1.element) ? $0 | (1 << UInt32($1.offset)):$0 }
        return withoutActuallyEscaping(cancelled) { callback in
            let request=NativeCancellation(callback), maximum=FuzzyPinyin.normalize(raw).count
            let opaque=Unmanaged.passUnretained(request).toOpaque()
            guard let page=ck_native_decode(handle,raw,context,mask,correction ? 1:0,characterOnly ? 1:0,
                                            Int32(clamping:max(1,min(4096,limit))),nativeCancelled,opaque) else{return []}
            defer{ck_native_page_destroy(page)}
            guard !callback() else{return []}
            return snapshot(page,maximum:maximum)

        }
    }
    private func snapshot(_ page: OpaquePointer, maximum: Int) -> [Candidate] {
        let kinds: [InputMatchType]=[.exact,.initials,.mixed,.prefix,.fuzzy,.correction,.association,.literal]
        return (0..<ck_native_page_count(page)).compactMap { i in
            let text=String(cString:ck_native_text(page,i)),consumed=Int(ck_native_consumed(page,i))
            let kind=Int(ck_native_match_type(page,i))
            guard !text.isEmpty, consumed>=0,consumed<=maximum,(maximum==0 || consumed>0),kinds.indices.contains(kind) else{return nil}
            let count=ck_native_segment_count(page,i)
            let segments=(0..<count).map{Int(ck_native_segment_end(page,i,$0))}
            let editKinds: [InputEditKind]=[.substitution,.insertion,.deletion,.transposition,.fuzzyInitial,.fuzzyFinal]
            let edits=(0..<ck_native_edit_count(page,i)).compactMap { j -> InputEdit? in
                let k=Int(ck_native_edit_kind(page,i,j));guard editKinds.indices.contains(k) else{return nil}
                return InputEdit(kind:editKinds[k],inputStart:Int(ck_native_edit_start(page,i,j)),inputEnd:Int(ck_native_edit_end(page,i,j)),
                    syllableIndex:Int(ck_native_edit_unit(page,i,j)),typed:String(cString:ck_native_edit_typed(page,i,j)),
                    replacement:String(cString:ck_native_edit_replacement(page,i,j)),cost:ck_native_edit_amount(page,i,j),searchPenalty:ck_native_edit_penalty(page,i,j))
            }
            let flags=ck_native_match_flags(page,i)
            let channels: [InputMatchType]=[.exact,.fuzzy,.prefix,.initials,.correction,.literal]
            var matched=channels.enumerated().compactMap{flags & (1 << UInt32($0.offset)) != 0 ? $0.element:nil}
            if (matched.contains(.exact) && matched.contains(.initials)) || (matched.contains(.literal) && matched.count>1){matched.append(.mixed)}
            let pronunciation=ck_native_pronunciation_cost(page,i)
            let path=CandidatePath(kind:kinds[kind],frequency:ck_native_frequency(page,i),editCost:ck_native_edit_cost(page,i),
                consumedEnd:Int(ck_native_scalar_end(page,i)),segments:segments,baseRank:Int(ck_native_base_rank(page,i)),
                edits:edits,matchKinds:matched,pronunciationCost:pronunciation.isFinite ? pronunciation:nil,expandsCompleteSyllable:ck_native_expands_complete_syllable(page,i) != 0)
            return Candidate(text:text,reading:String(cString:ck_native_reading(page,i)),consumed:consumed,
                         score:ck_native_score(page,i),path:path)
        }
    }
    func resolve(_ candidate: Candidate, raw: String, fuzzy: Set<String>, correction: Bool, cancelled: () -> Bool) -> Candidate {
        guard !cancelled(),!candidate.reading.isEmpty else{return candidate.withPath(nil)}
        let mask=FuzzyPinyin.availablePairs.enumerated().reduce(UInt32(0)) { fuzzy.contains($1.element) ? $0 | (1 << UInt32($1.offset)):$0 }
        return withoutActuallyEscaping(cancelled) { callback in
            let token=NativeCancellation(callback)
            // Keep precisely this cancellation owner alive for the synchronous C call.
            let pointer=Unmanaged.passUnretained(token).toOpaque()
            guard let page=ck_native_resolve(handle,raw,candidate.text,candidate.reading,Int32(clamping:candidate.consumed),
                candidate.personalPreference.map{Float($0.uses)} ?? -1,mask,correction ? 1:0,nativeCancelled,pointer) else{return candidate.withPath(nil)}
            defer{ck_native_page_destroy(page)}
            guard !callback(),let resolved=snapshot(page,maximum:FuzzyPinyin.normalize(raw).count).first else{return candidate.withPath(nil)}
            return candidate.withPath(resolved.path)
        }
    }
    func preview(_ raw: String, context: String, fuzzy: Set<String>, correction: Bool, cancelled: () -> Bool) -> [Candidate] {
        candidates(raw,context:context,fuzzy:fuzzy,correction:correction,limit:96,cancelled:cancelled)
    }
}
