import Foundation
import CoreML

public struct V21Range: Codable, Sendable, Equatable {
    public let start: Int
    public let end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
    public var length: Int { end - start }
}
public struct V21NormalizationUnit: Codable, Sendable {
    public let normalizedUTF8Range: V21Range
    public let originalUTF8Range: V21Range
    public let originalUTF16Range: V21Range
}
public struct V21Alignment: Codable, Sendable {
    public let characterUTF16Range: V21Range
    public let rawUTF8Range: V21Range
    public let rawUTF16Range: V21Range
    public let normalizedUTF8Range: V21Range
    public let syllable: String
}
public struct V21Candidate: Codable, Sendable {
    public let id: String
    public let text: String
    public let reading: String
    public let score: Double
    public let consumedRawUTF8Range: V21Range
    public let consumedRawUTF16Range: V21Range
    public let fullConsumption: Bool
    public let remainingPinyin: String
    public let matchType: String
    public let alignment: [V21Alignment]
    public let inputVersion: UInt64
    public let pathIndex: Int
    public let completionSuffix: String
    public let inputEvidence: V23PathEvidence
    /// Legacy flag: no unfinished tail, not a claim of exact full-pinyin spelling.
    public var isCompletePinyinInput: Bool { completionSuffix.isEmpty }
    public var isExactFullPinyin:Bool {inputEvidence.edges.allSatisfy{$0.type == "EXACT"}}
}
public enum V21ResultStatus: String, Codable, Sendable {
    case ok, emptyInput, unsupportedInput, noSyllablePath, noCandidateAfterConstraints
}
public struct V21Timings: Codable, Sendable {
    public internal(set) var sequencePredictionMS: Double = 0
    public internal(set) var sequencePredictionCalls: Int = 0
    public internal(set) var queueOverlapWithPreviousPredictionStageMS: Double = 0
    public internal(set) var parsedPathCount: Int? = nil
    public internal(set) var waitingForPreviousPrediction: Bool = false
    public internal(set) var waitingForStartupPreparation: Bool? = nil
    public internal(set) var finalCandidateReadyMS: Double? = nil
    public internal(set) var predictions: [V21PredictionTiming] = []
    public internal(set) var memorySamples: [V21MemorySample] = []
    public internal(set) var certification: [V21CertificationSample] = []
    public internal(set) var sdkEntryUptimeNS: UInt64 = 0
    public internal(set) var queueMS: Double = 0
    public internal(set) var parseMS: Double = 0
    public internal(set) var encodeMS: Double = 0
    public internal(set) var predictionMS: Double = 0
    public internal(set) var decodeMS: Double = 0
    public internal(set) var firstCandidateReadyMS: Double? = nil
    public internal(set) var firstSDKResultMS: Double? = nil
    public internal(set) var finalSDKResultMS: Double? = nil
    public internal(set) var firstPredictionInThisInstance: Bool = false
    /// True when at least one call in this request uses a previously unseen shape.
    public internal(set) var firstPredictionForShape: Bool = false
    public internal(set) var candidateConversionMS: Double = 0
    public internal(set) var otherSDKMS: Double = 0
    public internal(set) var scoreBoundSkippedPaths: Int = 0
    public internal(set) var candidateResultCacheHit: Bool? = nil
    public internal(set) var tensorScoreCacheHits: Int = 0
    public internal(set) var tensorScoreCacheMisses: Int = 0
    public internal(set) var inferenceCalls: Int = 0
    public internal(set) var modelBatch: Int = 0
    /// Maximum width across this request; predictionShapes records each actual call.
    public internal(set) var targetWidth: Int = 0
    public internal(set) var predictionShapes: [String] = []
    public internal(set) var diagnosticPackagingMS: Double = 0
    public internal(set) var cacheState: String = "no cross-input result cache; CoreML internal cache unknown"
}
public struct V21Selection: Codable, Sendable {
    public let inputVersion: UInt64
    public let candidateID: String
    public let selectedText: String
    public let selectedReading: String
    public let consumedRawUTF8Range: V21Range
    public let consumedRawUTF16Range: V21Range
    public let remainingPinyin: String
    public let fullConsumption: Bool
    public let alignment: [V21Alignment]
}
public struct V21Result: Sendable {
    public let inputVersion: UInt64
    public let rawInput: String
    public let normalizedPinyin: String
    public let normalizationMap: [V21NormalizationUnit]
    public let candidates: [V21Candidate]
    public let recommendedID: String?
    public let status: V21ResultStatus
    public let reason: String?
    public let syllablePathsExamined: Int
    public let completedPaths: Int
    public let isFinal: Bool
    public let previewRecommendationIsFinalRankCertified: Bool
    public let requestedCount: Int
    public var maximumSupportedCount: Int { 8 }
    public internal(set) var timings: V21Timings
    internal let generation: UInt64
    internal let instanceID: UUID
    internal var diagnosticData: Data?
    internal func rebased(version:UInt64,generation:UInt64,timings:V21Timings)->V21Result {
        let items=candidates.map {c in V21Candidate(id:c.id,text:c.text,reading:c.reading,score:c.score,consumedRawUTF8Range:c.consumedRawUTF8Range,consumedRawUTF16Range:c.consumedRawUTF16Range,fullConsumption:c.fullConsumption,remainingPinyin:c.remainingPinyin,matchType:c.matchType,alignment:c.alignment,inputVersion:version,pathIndex:c.pathIndex,completionSuffix:c.completionSuffix,inputEvidence:c.inputEvidence)}
        return V21Result(inputVersion:version,rawInput:rawInput,normalizedPinyin:normalizedPinyin,normalizationMap:normalizationMap,candidates:items,recommendedID:recommendedID,status:status,reason:reason,syllablePathsExamined:syllablePathsExamined,completedPaths:completedPaths,isFinal:isFinal,previewRecommendationIsFinalRankCertified:previewRecommendationIsFinalRankCertified,requestedCount:requestedCount,timings:timings,generation:generation,instanceID:instanceID,diagnosticData:nil)
    }
    /// Pure immutable conversion: render an entire batch without per-candidate actor hops.
    public func selections(prefixCharacterCount: Int? = nil) throws -> [V21Selection] {
        try candidates.map { try selection(candidateID: $0.id, prefixCharacterCount: prefixCharacterCount) }
    }
    public func selection(candidateID: String, prefixCharacterCount: Int? = nil) throws -> V21Selection {
        guard let c = candidates.first(where: { $0.id == candidateID }) else { throw V21Error.selection("Unknown candidate") }
        let n = prefixCharacterCount ?? c.alignment.count
        guard n > 0 && n <= c.alignment.count else { throw V21Error.selection("Invalid selected prefix length") }
        let full = n == c.alignment.count, alignment = Array(c.alignment.prefix(n))
        let end = full ? rawInput.utf8.count : alignment[n-1].rawUTF8Range.end
        let range = V21Range(start: 0, end: end), text = String(c.text.prefix(n)), reading = alignment.map(\.syllable).joined(separator: " ")
        return V21Selection(inputVersion: inputVersion, candidateID: full ? c.id : V21Input.candidateID(raw: rawInput, text: text, reading: reading, consumedEnd: end), selectedText: text, selectedReading: reading, consumedRawUTF8Range: range, consumedRawUTF16Range: try V21Input.utf16Range(range, in: rawInput), remainingPinyin: try V21Input.suffix(after: end, in: rawInput), fullConsumption: full, alignment: alignment)
    }
}
public enum V21Error: Error, LocalizedError {
    case resource(String), contract(String), model(String), selection(String), released
    public var errorDescription: String? {
        switch self { case .resource(let s), .contract(let s), .model(let s), .selection(let s): return s
        case .released: return "V21 kernel released" }
    }
}
public struct V21Configuration: @unchecked Sendable {
    public let computeUnits: MLComputeUnits
    public var performanceSink: (@Sendable (V21PerformanceRecord) -> Void)?
    public var performanceCaptureEnabled: (@Sendable () -> Bool)?
    public var allowIncompleteTail: Bool
    public init(computeUnits: MLComputeUnits = .cpuOnly, allowIncompleteTail: Bool = true, performanceSink: (@Sendable (V21PerformanceRecord) -> Void)? = nil, performanceCaptureEnabled: (@Sendable () -> Bool)? = nil) {
        self.performanceCaptureEnabled=performanceCaptureEnabled
        self.performanceSink=performanceSink
        self.computeUnits = .cpuOnly // Build105 locks both models to CPU.
        self.allowIncompleteTail = allowIncompleteTail
    }
}
public struct V21DiagnosticReport: Sendable {
    public let json: Data
    /// Explicit one-shot export only. App receipt/visible timestamps must be supplied by App.
    public func exportJSON(to url: URL, appBuild: String? = nil, appInputUptimeNS: UInt64? = nil, appReceivedUptimeNS: UInt64? = nil, appVisibleUptimeNS: UInt64? = nil) throws {
        var object = (try JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        var app: [String: Any] = ["source": "App supplied; SDK does not measure screen visibility"]
        if let appBuild { app["build"] = appBuild }
        if let appInputUptimeNS { app["input_received_uptime_ns"] = appInputUptimeNS }
        if let appReceivedUptimeNS { app["received_uptime_ns"] = appReceivedUptimeNS }
        if let appVisibleUptimeNS { app["visible_uptime_ns"] = appVisibleUptimeNS }
        object["app_evidence"] = app
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}

// V22 runtime-only additions. Compatibility names preserve the existing App's thin API.
public struct V21PredictionTiming: Codable, Sendable {
    public let ordinal: Int
    public let pathIndex: Int
    public let shape: String
    public let durationMS: Double
    public let firstInInstance: Bool
    public let firstForShape: Bool
    public let status: String
}
public struct V21MemorySample: Codable, Sendable {
    public let phase: String
    public let shape: String?
    public let uptimeNS: UInt64
    public let processFootprintBytes: UInt64
}
public struct V21CandidateScoreSample: Codable, Sendable {
    public let id: String
    public let path: Int
    public let model_mean_logp: Double
    public let character_mean_logp: Double
    public let word_backoff_mean_logp: Double
    public let segmentation_log_prior: Double
    public let score: Double
    public let complete_word_log_prior: Double?
    public let lexical_fusion_gain_mean: Double? // historical Build104 field only
    public let input_and_learned_adjustment: Double? // actual V23/V24 score adjustment
}
public struct V21CertificationSample: Codable, Sendable {
    public let ranking_policy: String?
    public internal(set) var candidate_scores: [V21CandidateScoreSample]?
    public let completed_paths: Int
    public let total_paths: Int
    public let certification: String
    public let remaining_score_upper_bound: Double?
    public let leading_score: Double?
    public let char_log_cache_hits: UInt64
    public let char_log_cache_misses: UInt64
    public let char_log_cache_slots: Int
    public let reading_checks: UInt64
}
/// Bounded lengths/status only. No raw text, target, context, candidates or tensors.
public struct V21PerformanceRecord: Codable, Sendable {
    public let processID: Int32
    public let instanceID: String
    public let inputVersion: UInt64
    public let rawUTF8Length: Int
    public let contextScalarLength: Int
    public let status: String
    public let cancellationReason: String?
    public let error: String?
    public let stage: String
    public let unfinishedStageElapsedMS: Double
    public let pathCount: Int?
    public let completedPaths: Int
    public let recommendedID: String?
    public let sdkElapsedMS: Double
    public let timings: V21Timings
    public let preparationMS: [String:Double]
    public let preparationMemory: [V21MemorySample]
    public let identity: [String:String]
}

public struct V23InputSettings: Codable, Hashable, Sendable {
    public var preserveLiteral:Bool=false
    public var allowInitials:Bool=true
    public var allowTypos:Bool=true
    /// bits0..7: zh/z,ch/c,sh/s,n/l,f/h,an/ang,en/eng,in/ing.
    public var fuzzyGroups:UInt32=0
    public var maximumEdits:Int=2
    public var segmentState:String=""
    public var personalLearningVersion:UInt64=0 // Cache boundary only; no personal weights are trained.
    public init() {}
}
public struct V23Edit: Codable, Sendable {
    public let operation:String
    public let cross_syllable_boundary:Bool?
    public let raw_utf8_range:[Int]?
    public let charged_once_on_first_segment:Bool?
    public let raw_utf8_offset:Int
    public let normalized_offset:Int
    public let source:String
    public let target:String
}
public struct V23InputEdge: Codable, Sendable {
    public let type:String
    public let syllable_id:Int
    public let syllable:String
    public let normalized_range:[Int]
    public let raw_utf8_range:[Int]
    public let fuzzy_group_bits:UInt32
    public let edit_count:Int
    public let cost:Double
    public let completion:String
    public let edits:[V23Edit]
    public let shared_boundary_transpose_offset:Int?
    public let shared_boundary_side:Int?
}
public struct V23PathEvidence: Codable, Sendable {
    public let input_cost:Double
    public let mixed:Bool
    public let edges:[V23InputEdge]
}
