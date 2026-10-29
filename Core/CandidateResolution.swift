import Foundation

public struct CandidateEvidence: Codable, Sendable {
    let id: String
    let text: String
    let reading: String
    let consumed: Int
    let nativeScore: Double
    let path: CandidatePath?
    init(_ c: Candidate) {id=c.stableID;text=c.text;reading=c.reading;consumed=c.consumed;nativeScore=c.score;path=c.path}
}
public struct CandidateResolution: Codable, Sendable {
    let engineVersion: String
    let modelVersion: String
    let contractVersion: String
    let raw: String
    let committedContext: String
    let mode: String
    let settings: String
    let nativeCandidates: [CandidateEvidence]
    let modelCandidates: [CandidateEvidence]
    let ruleCandidateID: String
    let modelDecision: V10Decision?
    let modelStatus: String
    let cacheHit: Bool
    let encodedFeatures: [[Float]]
    let basePriors: [Float]
    var finalCandidateID: String
    var finalSource: String
}
/// Bounded local incidents from an explicit, successful candidate selection only.
/// Ordinary keys, automatic Space commits and model predictions are not labels.
/// No network path or background polling exists in this store.
enum CandidateChoiceDiagnostics {
    private static let queue=DispatchQueue(label:"clear.choice.incidents",qos:.utility)
    private static let key="clear.input.choiceIncidents.v1"
    private struct Record: Codable {
        let recordedAt: Date
        let inputRevision: Int
        let resolution: CandidateResolution
        let userSelectedCandidate: CandidateEvidence
        let selectedWasEvaluated: Bool
    }
    static func record(_ resolution: CandidateResolution,selected: Candidate,revision: Int,defaults: UserDefaults,epoch: String?) {
        guard resolution.raw.unicodeScalars.count<=256,resolution.finalCandidateID != selected.stableID else{return}
        let record=Record(recordedAt:Date(),inputRevision:revision,resolution:resolution,userSelectedCandidate:CandidateEvidence(selected),selectedWasEvaluated:resolution.modelDecision?.evaluatedCandidateIDs.contains(selected.stableID)==true)
        queue.async {
            guard defaults.string(forKey:"clear.learned.epoch")==epoch else{return}
            var records=defaults.data(forKey:key).flatMap{try? JSONDecoder().decode([Record].self,from:$0)} ?? []
            records.append(record);records=Array(records.suffix(12))
            while !records.isEmpty {
                guard let data=try? JSONEncoder().encode(records) else{return}
                if data.count<=192*1024{guard defaults.string(forKey:"clear.learned.epoch")==epoch else{return};defaults.set(data,forKey:key);return}
                records.removeFirst()
            }
        }
    }
    static func clear(_ defaults: UserDefaults){queue.async{defaults.removeObject(forKey:key)}}
}
