import Foundation
@preconcurrency import CoreML

/// Single process owner. Only the latest candidate worker enters inference;
/// the independent native lookup queue never waits on this lock or Core ML.
final class ClearV10Scorer {
    static let shared=ClearV10Scorer()
    enum RuntimeConfiguration { static let computeUnits: MLComputeUnits = .all }
    private var model: ClearV10Model?
    private var loadFailed=false
    private let lock=NSLock()
    private var revision: UInt64=0
    private struct Key: Hashable {let raw,context,mode,settings:String;let metadata:Data}
    private struct Cached {let decision: V10Decision}
    private var cache: [Key:Cached]=[:]
    private var order: [Key]=[]
    private init() {}
    private func instance() throws -> ClearV10Model {
        if let model{return model}
        guard !loadFailed,
              let compiled=InputResources.url("V10KeyboardModel",extension:"mlmodelc",directory:"V10"),
              let vocabulary=InputResources.url("vocab",extension:"json",directory:"V10"),
              let calibration=InputResources.url("calibration",extension:"json",directory:"V10")
        else {throw V10ContractError.invalidModel("V10 compiled resources unavailable")}
        do {
            let value=try ClearV10Model(compiledModelURL:compiled,vocabularyURL:vocabulary,
                calibrationURL:calibration,computeUnits:RuntimeConfiguration.computeUnits)
            model=value;return value
        }catch {loadFailed=true;NSLog("CLEAR_V10_LOAD %@",String(describing:error));throw error}
    }
    func rank(_ candidates: [Candidate], raw: String, context: String, mode: V10InputMode,
              ruleCandidateID: String, settingsKey: String, cancelled: () -> Bool,
              nativeCandidates: [Candidate] = [], observed: ((CandidateResolution)->Void)? = nil) -> [Candidate] {
        var encoded:[V10Candidate]=[]
        func finish(_ modelID: String,decision: V10Decision?,status: String,cacheHit: Bool = false) -> [Candidate] {
            guard !cancelled() else{return candidates}
            // This is a new explicit-user policy, separate from the unchanged
            // V10 threshold/protected veto. It uses the exact raw/context match
            // of a real selection, never an example string or a model label.
            let personal=candidates.first{$0.personalPreference?.isExplicitContextMatch==true && $0.canConsume(raw)}
            let preferredID=personal?.stableID ?? modelID
            var result=candidates
            if let index=result.firstIndex(where:{$0.stableID==preferredID}),index != 0 {let c=result.remove(at:index);result.insert(c,at:0)}
            observed?(CandidateResolution(engineVersion:"clear-native88",modelVersion:"V10",contractVersion:"contract_v2",raw:raw,
                committedContext:context,mode:mode.rawValue,settings:settingsKey,nativeCandidates:Array(nativeCandidates.prefix(32)).map(CandidateEvidence.init),
                modelCandidates:Array(candidates.prefix(32)).map(CandidateEvidence.init),ruleCandidateID:ruleCandidateID,
                modelDecision:decision,modelStatus:status,cacheHit:cacheHit,
                encodedFeatures:encoded.count==min(32,candidates.count) ? encoded.map{V10InputEncoder.features($0,rawCount:raw.unicodeScalars.count,mode:mode)}:[],
                basePriors:encoded.count==min(32,candidates.count) ? encoded.map{V10InputEncoder.prior($0)}:[],finalCandidateID:preferredID,
                finalSource:personal != nil ? "explicit_user_preference":decision?.adopted==true ? "V10_adopted":"native_rule"))
            return result
        }
        guard !cancelled(),let rule=candidates.firstIndex(where:{$0.stableID==ruleCandidateID}) else{return candidates}
        if rule>=32{return finish(ruleCandidateID,decision:nil,status:"rule_outside_first32")}
        if V10InputEncoder.isProtected(raw:raw,mode:mode){return finish(ruleCandidateID,decision:nil,status:"protected_input")}
        for c in candidates.prefix(32) {
            guard let path=c.path,let kind=V10MatchType(rawValue:path.kind.rawValue) else {
                return finish(ruleCandidateID,decision:nil,status:"unresolved_candidate_metadata:"+c.stableID)
            }
            encoded.append(V10Candidate(id:c.stableID,text:c.text,reading:c.reading,
                consumedInputRange:[path.consumedStart,path.consumedEnd],matchType:kind,
                frequency:path.frequency,editCost:path.editCost,baseRank:path.baseRank))
        }
        guard Set(encoded.map(\.id)).count==encoded.count,let metadata=try? JSONEncoder().encode(encoded) else {
            return finish(ruleCandidateID,decision:nil,status:"invalid_candidate_snapshot")
        }
        let key=Key(raw:raw,context:context,mode:mode.rawValue,settings:"clear-native88:V10:0d27285db15f626a:"+settingsKey,metadata:metadata)
        guard !cancelled() else{return candidates}
        lock.lock();defer{lock.unlock()}
        guard !cancelled() else{return candidates}
        if let cached=cache[key]{return finish(cached.decision.preferredCandidateID,decision:cached.decision,status:"context_cache",cacheHit:true)}
        do {
            let backend=try instance();guard !cancelled() else{return candidates}
            revision &+= 1
            let request=V10Request(revision:revision,committedContext:context,rawInput:raw,mode:mode,candidates:encoded,ruleCandidateID:ruleCandidateID)
            let result=try backend.predict(request)
            guard !cancelled(),result.revision==request.revision,candidates.contains(where:{$0.stableID==result.preferredCandidateID}) else{return candidates}
            cache[key]=Cached(decision:result);order.append(key)
            if order.count>32{cache.removeValue(forKey:order.removeFirst())}
            return finish(result.preferredCandidateID,decision:result,status:result.reason)
        }catch {return finish(ruleCandidateID,decision:nil,status:"model_error:"+String(describing:error))}
    }
}
