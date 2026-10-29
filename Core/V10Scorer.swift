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
    private var cache: [Key:String]=[:]
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
              ruleCandidateID: String, settingsKey: String, cancelled: () -> Bool) -> [Candidate] {
        guard !cancelled(), let rule=candidates.firstIndex(where:{$0.stableID==ruleCandidateID}),rule<32,
              !V10InputEncoder.isProtected(raw:raw,mode:mode) else{return candidates}
        var encoded: [V10Candidate]=[]
        for c in candidates.prefix(32) {
            // Old learning records are preserved. If their original phonetic
            // evidence cannot be recovered from this native row, keep the rule
            // choice instead of inventing frequency/edit-cost/type features.
            guard let path=c.path,let kind=V10MatchType(rawValue:path.kind.rawValue) else{return candidates}
            encoded.append(V10Candidate(id:c.stableID,text:c.text,reading:c.reading,
                consumedInputRange:[path.consumedStart,path.consumedEnd],matchType:kind,
                frequency:path.frequency,editCost:path.editCost,baseRank:path.baseRank))
        }
        guard Set(encoded.map(\.id)).count==encoded.count,let metadata=try? JSONEncoder().encode(encoded) else{return candidates}
        let key=Key(raw:raw,context:context,mode:mode.rawValue,
            settings:"clear-native84:V10:0d27285db15f626a:"+settingsKey,metadata:metadata)
        guard !cancelled() else{return candidates}
        lock.lock();defer{lock.unlock()}
        guard !cancelled() else{return candidates}
        func preferred(_ id: String) -> [Candidate] {
            guard let index=candidates.firstIndex(where:{$0.stableID==id}),index != 0 else{return candidates}
            var result=candidates;let candidate=result.remove(at:index);result.insert(candidate,at:0);return result
        }
        if let id=cache[key]{return preferred(id)}
        do {
            let backend=try instance();guard !cancelled() else{return candidates}
            revision &+= 1
            let request=V10Request(revision:revision,committedContext:context,rawInput:raw,mode:mode,
                candidates:encoded,ruleCandidateID:ruleCandidateID)
            let result=try backend.predict(request)
            guard !cancelled(),result.revision==request.revision,
                  candidates.contains(where:{$0.stableID==result.preferredCandidateID}) else{return candidates}
            cache[key]=result.preferredCandidateID;order.append(key)
            if order.count>32{cache.removeValue(forKey:order.removeFirst())}
            return preferred(result.preferredCandidateID)
        }catch {return candidates}
    }
}
