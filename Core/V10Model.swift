import Foundation
@preconcurrency import CoreML

// V10 contract adapter supplied with the 2026-10-29 delivery. Device acceptance is user-owned.
public enum V10InputMode: String, Codable, Sendable { case pinyin, english, mixed }
public enum V10MatchType: String, Codable, Sendable {
    case exact, initials, mixed, prefix, fuzzy, correction, association, literal
}
public struct V10Candidate: Codable, Sendable {
    public let id: String
    public let text: String
    public let reading: String
    public let consumedInputRange: [Int] // Unicode scalar offsets on the ACTUAL raw keys.
    public let matchType: V10MatchType
    public let frequency: Float         // Same native Float32 frequency as the reference decoder.
    public let editCost: Float
    public let baseRank: Int            // Original rule ordering, before neural ranking.
    enum CodingKeys: String, CodingKey {
        case id, text, reading, frequency
        case consumedInputRange = "consumed_input_range", matchType = "match_type"
        case editCost = "edit_cost", baseRank = "base_rank"
    }
    public init(id: String, text: String, reading: String, consumedInputRange: [Int],
                matchType: V10MatchType, frequency: Float, editCost: Float, baseRank: Int) {
        self.id=id; self.text=text; self.reading=reading; self.consumedInputRange=consumedInputRange
        self.matchType=matchType; self.frequency=frequency; self.editCost=editCost; self.baseRank=baseRank
    }
}
public struct V10Request: Sendable {
    public let revision: UInt64
    public let committedContext: String
    public let rawInput: String
    public let mode: V10InputMode
    public let candidates: [V10Candidate]
    public let ruleCandidateID: String
    public init(revision: UInt64, committedContext: String, rawInput: String, mode: V10InputMode,
                candidates: [V10Candidate], ruleCandidateID: String) {
        self.revision=revision; self.committedContext=committedContext; self.rawInput=rawInput
        self.mode=mode; self.candidates=candidates; self.ruleCandidateID=ruleCandidateID
    }
}
public enum V10ContractError: Error {
    case invalidInput(String), invalidModel(String), invalidCalibration, invalidOutput
}
public struct V10Decision: Codable, Sendable {
    public let revision: UInt64
    public let preferredCandidateID: String
    public let ruleCandidateID: String
    public let proposalCandidateID: String?
    public let adopted: Bool
    public let reason: String
    public let evaluatedCandidateIDs: [String]
    public let scores: [Float]
    public let acceptanceLogits: [Float]
    public let adoptLogit: Float?
    public let adoptionProbability: Float?
    // Only preferredCandidateID is the evaluated final-choice contract.
    // Do not silently replace the host IME's entire candidate ordering/features.
}
public struct V10EncodedInput {
    public let arrays: [String: MLMultiArray]
    public let orderedCandidateIDs: [String]
    public let ruleIndex: Int
}
public struct V10InputEncoder {
    private let vocabulary: [String: Int32]
    private var workspace: [String:MLMultiArray]=[:]
    public static let matchTypes: [V10MatchType] = [.exact,.initials,.mixed,.prefix,.fuzzy,.correction,.association,.literal]
    public static let inputShapes: [String: [Int]] = [
        "context_ids":[1,96], "raw_ids":[1,96], "candidate_ids":[1,32,32], "reading_ids":[1,32,96],
        "features":[1,32,18], "valid_mask":[1,32], "base_prior":[1,32], "rule_index":[1]
    ]
    public init(vocabularyURL: URL) throws {
        struct Vocab: Decodable { let tokens: [String] }
        let tokens=try JSONDecoder().decode(Vocab.self,from:Data(contentsOf:vocabularyURL)).tokens
        guard tokens.count == 8192 else { throw V10ContractError.invalidInput("Expected 8192 vocabulary entries") }
        var map: [String:Int32]=[:]
        for (index,token) in tokens.enumerated() where index >= 257 { map[token]=Int32(index) }
        vocabulary=map
    }
    public func tokenIDs(_ string: String, length: Int, keepTail: Bool = false) -> [Int32] {
        var ids: [Int32]=[]
        for scalar in string.unicodeScalars {
            let unit=String(scalar)
            if let id=vocabulary[unit] { ids.append(id) }
            else { ids.append(contentsOf:unit.utf8.map { Int32($0)+1 }) }
        }
        // Truncate the TOKEN stream; never use String.count (graphemes) or UTF16 offsets.
        var result=Array(keepTail ? ids.suffix(length) : ids.prefix(length))
        result.append(contentsOf:repeatElement(0,count:max(0,length-result.count)))
        return result
    }
    public static func isProtected(raw: String, mode: V10InputMode) -> Bool {
        // Python \w is Unicode letters/numbers/underscore, not ICU's combining-mark-inclusive \w.
        let searches = [
            #"https?://|www\."#,
            #"[\p{L}\p{N}_.+\-]+@[\p{L}\p{N}_.\-]+\.[A-Za-z]{2,}"#,
            #"[{}<>;=\\]"#
        ]
        let range=NSRange(raw.startIndex..<raw.endIndex,in:raw)
        for pattern in searches {
            if let re=try? NSRegularExpression(pattern:pattern),
               re.firstMatch(in:raw,range:range) != nil { return true }
        }
        func full(_ pattern: String) -> Bool {
            guard let re=try? NSRegularExpression(pattern:pattern),
                  let match=re.firstMatch(in:raw,range:range) else { return false }
            return match.range == range
        }
        if full(#"\A[A-Z]{1,8}[-_]?\p{Nd}+[A-Za-z0-9-]*\z"#) { return true }
        return mode == .english && full(#"\A[A-Za-z]+[-_]?\p{Nd}+[A-Za-z0-9-]*\z"#)
    }
    public static func features(_ c:V10Candidate,rawCount:Int,mode:V10InputMode)->[Float] {
        let n=Double(max(1,rawCount)),a=c.consumedInputRange[0],b=c.consumedInputRange[1]
        var f:[Double]=[min(1,log1p(max(0,Double(c.frequency)))/12),min(1,max(0,Double(c.editCost))/3),c.matchType == .exact ? 1:0,
            min(1,Double(c.text.unicodeScalars.count)/32),min(1,Double(b-a)/n),min(1,Double(rawCount)/64),mode == .english ? 1:0,mode == .mixed ? 1:0]
        f.append(contentsOf:matchTypes.map{$0==c.matchType ? 1.0:0.0})
        f.append(min(1,Double(max(0,a))/n));f.append(min(1,Double(max(0,b))/n))
        return f.map{Float(Float16($0))}
    }
    public static func prior(_ c:V10Candidate)->Float {
        Float(-0.15*Double(c.baseRank)-0.5*Double(c.editCost)+0.02*log1p(max(0,Double(c.frequency))))
    }
    public mutating func encode(_ request: V10Request) throws -> V10EncodedInput {
        let all=request.candidates
        guard !all.isEmpty, Set(all.map(\.id)).count == all.count,
              let rule=all.firstIndex(where:{$0.id == request.ruleCandidateID}), rule < 32
        else { throw V10ContractError.invalidInput("Empty/duplicate candidates, missing rule, or rule outside unchanged first32") }
        let candidates=Array(all.prefix(32)); let rawCount=request.rawInput.unicodeScalars.count
        var arrays: [String:MLMultiArray]=[:]
        for (name,shape) in Self.inputShapes {
            let integer=name.hasSuffix("_ids") || name == "rule_index"
            let a: MLMultiArray
            if let reused=workspace[name] {a=reused}
            else {a=try MLMultiArray(shape:shape.map{NSNumber(value:$0)},dataType:integer ? .int32 : .float32);workspace[name]=a}
            for i in 0..<a.count { a[i]=0 } // Do not assume allocation is zero-initialized.
            arrays[name]=a
        }
        func putTokens(_ name:String,_ ids:[Int32],_ offset:Int=0) {
            for (i,id) in ids.enumerated() { arrays[name]![offset+i]=NSNumber(value:id) }
        }
        putTokens("context_ids",tokenIDs(request.committedContext,length:96,keepTail:true))
        // No NFC/NFKC, no ü->v rewrite, no punctuation/space stripping.
        let raw=request.mode == .pinyin ? request.rawInput.lowercased() : request.rawInput
        putTokens("raw_ids",tokenIDs(raw,length:96))
        arrays["rule_index"]![0]=NSNumber(value:rule)
        for (j,c) in candidates.enumerated() {
            guard c.frequency.isFinite, c.editCost.isFinite, c.editCost >= 0, c.baseRank >= 0,
                  c.consumedInputRange.count == 2 else { throw V10ContractError.invalidInput("Invalid candidate metadata") }
            let a=c.consumedInputRange[0], b=c.consumedInputRange[1]
            guard a >= 0, a <= b, b <= rawCount else { throw V10ContractError.invalidInput("Consumption must reference actual raw Unicode scalars") }
            putTokens("candidate_ids",tokenIDs(c.text,length:32),j*32)
            putTokens("reading_ids",tokenIDs(c.reading,length:96),j*96)
            let f=Self.features(c,rawCount:rawCount,mode:request.mode)
            for k in 0..<18 {arrays["features"]![j*18+k]=NSNumber(value:f[k])}
            arrays["valid_mask"]![j]=1
            arrays["base_prior"]![j]=NSNumber(value:Self.prior(c))
        }
        return V10EncodedInput(arrays:arrays,orderedCandidateIDs:candidates.map(\.id),ruleIndex:rule)
    }
}
final class ClearV10Model {
    private let model: MLModel
    private var encoder: V10InputEncoder
    private let threshold: Float
    // Construct ONCE off the main thread, reuse for keystrokes.
    // Pass Xcode's compiled .mlmodelc URL, not a .pt or a per-keystroke compilation.
    public init(compiledModelURL: URL, vocabularyURL: URL, calibrationURL: URL,
                computeUnits: MLComputeUnits) throws {
        struct Calibration: Decodable {
            let adoptionThreshold: Float
            let applyExternalAffine: Bool
            let adoptionLogitIsAlreadyCalibrated: Bool
            enum CodingKeys: String, CodingKey {
                case adoptionThreshold="adoption_threshold", applyExternalAffine="apply_external_affine"
                case adoptionLogitIsAlreadyCalibrated="adoption_logit_is_already_calibrated"
            }
        }
        let calibration=try JSONDecoder().decode(Calibration.self,from:Data(contentsOf:calibrationURL))
        guard calibration.adoptionThreshold == Float(0.65), !calibration.applyExternalAffine,
              calibration.adoptionLogitIsAlreadyCalibrated else { throw V10ContractError.invalidCalibration }
        threshold=calibration.adoptionThreshold; encoder=try V10InputEncoder(vocabularyURL:vocabularyURL)
        guard compiledModelURL.pathExtension == "mlmodelc" else { throw V10ContractError.invalidModel("Use Xcode-built V10KeyboardModel.mlmodelc") }
        let config=MLModelConfiguration();config.computeUnits=computeUnits
        model=try MLModel(contentsOf:compiledModelURL,configuration:config)
        guard Set(model.modelDescription.inputDescriptionsByName.keys) == Set(V10InputEncoder.inputShapes.keys)
        else { throw V10ContractError.invalidModel("Eight-input V10 contract required") }
        for (name,shape) in V10InputEncoder.inputShapes {
            guard let a=model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint,
                  a.shape.map({$0.intValue})==shape,
                  a.dataType == (name.hasSuffix("_ids") || name=="rule_index" ? .int32:.float32)
            else {throw V10ContractError.invalidModel("V10 tensor ABI mismatch: "+name)}
        }
        guard Set(model.modelDescription.outputDescriptionsByName.keys)==Set(["scores","acceptance_logits","proposal_index","adopt_logit"])
        else {throw V10ContractError.invalidModel("V10 four-output ABI required")}
    }
    public func predict(_ request: V10Request) throws -> V10Decision {
        guard let originalRule=request.candidates.firstIndex(where:{$0.id == request.ruleCandidateID})
        else { throw V10ContractError.invalidInput("The actual rule ID must be in the unmodified candidate list") }
        func keep(_ reason:String) -> V10Decision {
            V10Decision(revision:request.revision,preferredCandidateID:request.ruleCandidateID,
                        ruleCandidateID:request.ruleCandidateID,proposalCandidateID:nil,adopted:false,
                        reason:reason,evaluatedCandidateIDs:[],scores:[],acceptanceLogits:[],
                        adoptLogit:nil,adoptionProbability:nil)
        }
        if V10InputEncoder.isProtected(raw:request.rawInput,mode:request.mode) { return keep("protected_input") }
        if originalRule >= 32 { return keep("rule_outside_first32") }
        let encoded=try encoder.encode(request); var dict:[String:Any]=[:]
        for (name,a) in encoded.arrays { dict[name]=MLFeatureValue(multiArray:a) }
        let output=try model.prediction(from:MLDictionaryFeatureProvider(dictionary:dict))
        guard let s=output.featureValue(for:"scores")?.multiArrayValue,
              let q=output.featureValue(for:"acceptance_logits")?.multiArrayValue,
              let p=output.featureValue(for:"proposal_index")?.multiArrayValue,
              let z=output.featureValue(for:"adopt_logit")?.multiArrayValue,
              s.count == 32, q.count == 32, p.count == 1, z.count == 1
        else { return keep("invalid_model_outputs") }
        let n=encoded.orderedCandidateIDs.count; let scores=(0..<n).map{s[$0].floatValue}
        let acceptance=(0..<n).map{q[$0].floatValue}; let proposal=p[0].intValue; let logit=z[0].floatValue
        guard (0..<n).contains(proposal), scores.allSatisfy({$0.isFinite}), logit.isFinite else { return keep("invalid_model_outputs") }
        let best=(0..<n).reduce(0) {scores[$1] > scores[$0] ? $1:$0}
        guard proposal == best else { return keep("inconsistent_proposal") }
        let clipped=min(Float(40),max(Float(-40),logit))
        let probability:Float=1/(1+Float(exp(Double(-clipped))))
        // Affine calibration is ALREADY in policy.2. Never apply scale/bias again.
        // acceptance_logits, ranking margin and softmax are not additional product gates.
        let adopt=proposal != encoded.ruleIndex && probability >= threshold
        return V10Decision(revision:request.revision,
            preferredCandidateID:adopt ? encoded.orderedCandidateIDs[proposal]:request.ruleCandidateID,
            ruleCandidateID:request.ruleCandidateID,proposalCandidateID:encoded.orderedCandidateIDs[proposal],
            adopted:adopt,reason:adopt ? "adopted":proposal == encoded.ruleIndex ? "same_as_rule":"below_adoption_threshold",
            evaluatedCandidateIDs:encoded.orderedCandidateIDs,scores:scores,acceptanceLogits:acceptance,
            adoptLogit:logit,adoptionProbability:probability)
    }
}
