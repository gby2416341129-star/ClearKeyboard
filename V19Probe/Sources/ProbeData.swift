import Foundation
@preconcurrency import CoreML

struct ProbeFixtureFile: Decodable {
    let sourceSHA256: String
    let cases: [ProbeFixture]
}
struct ReferenceCandidate: Codable, Sendable { let text: String; let score: Double }
struct LogitProbe: Decodable {
    let position: Int
    let ids: [Int]
    let values: [Float]
    enum CodingKeys: String, CodingKey {
        case position, ids = "legal_top8_character_ids", values = "source_float32_logits"
    }
}
struct ProbeFixture: Decodable {
    let id: String
    let raw: String
    let context: String
    let tensors: [String: [Int32]]
    let expectedPaths: Int
    let referenceCandidates: [ReferenceCandidate]
    let path0Probes: [LogitProbe]
    func provider() throws -> MLDictionaryFeatureProvider {
        var features: [String: MLFeatureValue] = [:]
        for (name, width) in [("context_ids",32),("context_mask",32),("pinyin_ids",64),("pinyin_mask",64)] {
            guard let values = tensors[name], values.count == width else { throw ProbeError.invalid("Invalid reference tensor: \(id) / \(name)") }
            let array = try MLMultiArray(shape: [1, NSNumber(value:width)], dataType: .int32)
            let destination = array.dataPointer.assumingMemoryBound(to: Int32.self)
            for i in values.indices { destination[i] = values[i] }
            features[name] = MLFeatureValue(multiArray: array)
        }
        return try MLDictionaryFeatureProvider(dictionary: features)
    }
}
struct RequestTiming: Codable, Sendable {
    let caseID: String
    let milliseconds: Double
    let paths: Int
    let candidateCount: Int
    let status: String
    let modelCallsMS: [Double]
    let nonPredictionWallMS: Double
}
struct FixtureComparison: Codable, Sendable {
    let caseID: String
    let raw: String
    let context: String
    let expectedPaths: Int
    let actualPaths: Int
    let referenceTop8: [String]
    let actualTop8: [String]
    let top1MatchesReference: Bool
    let orderedTop8MatchesReference: Bool
    let actualStatus: String
    let scores: [Double]
}
struct SourceLogitComparison: Codable, Sendable {
    let caseID: String
    let comparedScalarCount: Int
    let maximumAbsoluteDifference: Double
    let nonFiniteCount: Int
}
struct JournalEvent: Codable, Sendable {
    let time: Date
    let mode: String?
    let phase: String
    let detail: String
}
struct ModeResult: Codable, Sendable, Identifiable {
    var id: String { mode.rawValue }
    let mode: ProbeMode
    var status = "pending"
    var phase = "等待"
    var phaseStartedAt: Date?
    var startedAt: Date?
    var finishedAt: Date?
    var kernelPreparationMS: Double?
    var resourcePreparationMS: Double?
    var firstModelLoadMS: Double?
    var firstPredictionMS: Double?
    var firstCompleteRequestMS: Double?
    var firstRequestPathCount: Int?
    var firstRequestModelCallsMS: [Double] = []
    var sameProcessKernelReloadMS: Double?
    var sameProcessModelReloadMS: Double?
    var firstCompleteRequestAfterReloadMS: Double?
    var warmedModelTimingsMS: [Double] = []
    var predictionCaseIDs: [String] = []
    var completeRequestTimings: [RequestTiming] = []
    var idleResumeTimingsMS: [Double] = []
    var warmSummary: LatencySummary?
    var completeSummary: LatencySummary?
    var idleResumeSummary: LatencySummary?
    var byPathCount: [String: LatencySummary] = [:]
    var comparisons: [FixtureComparison] = []
    var sourceLogitComparisons: [SourceLogitComparison] = []
    var before: SystemSample?
    var after: SystemSample?
    var footprintAfterLoad: UInt64?
    var sampledPeakFootprintBytes: UInt64?
    var memorySamples = 0
    var completedNativePredictions = 0
    var outputChecksum: Double = 0
    var errors: [NativeFailure] = []
    let applicationPredictionCacheEnabled = false
    let implicitConfigurationFallbackUsed = false
    let trueUncachedColdStartVerified = false
}
struct SuiteReport: Codable, Sendable {
    let schemaVersion = 1
    let suiteID: String
    let modelVersion = "V19"
    let sourceStep = 38750
    let parameterCount = 20730368
    let checkpointSHA256 = "d9d1c4974a513236d72f489d0b13f51cb6c7a94b4f2cd5d51400d314dfba80a7"
    let probeBuild = 2
    let startedAt: Date
    var finishedAt: Date?
    var status = "running"
    var phase = "准备"
    var modeOrder: [ProbeMode]
    var results: [ModeResult]
    var events: [JournalEvent] = []
    var errors: [NativeFailure] = []
    let device: [String:String]
    var resourceSHA256: [String:String] = [:]
    var compiledModelIntegrityVerified = false
    let modelWarmupCount = 20
    let measuredModelCountPerMode = 300
    let measuredCompleteRequestCountPerMode = 120
    let hardwareTraceCaptured = false
    let hardwarePlacementPlanCollected = false
    let keyboardExtensionTested = false
    let UIFrameLatencyMeasured = false
    let wattsMeasured = false
    let samplesAreQualityAcceptance = false
    let measurementNotes = [
        "V19 step38750 FP16 CoreML; original Swift/C++ decoder with read-only diagnostic hooks in an independent source copy.",
        "First flow: resource preparation -> first MLModel load -> first complete SDK request. First prediction is the first synchronous native model call inside that request.",
        "Single-model timings use pre-encoded reference path0 inputs and still execute CoreML every time; they exclude parsing and decoding.",
        "Complete requests call the original SDK from raw pinyin/context through up to8 distinct segmentation predictions, decoding, constraints and candidate output. No oracle segmentation or candidate injection.",
        "Model shape is fixed [1,64] pinyin and [1,32] context; short inputs are padded to the same exported shapes.",
        "Full request nonPredictionWallMS is an elapsed-time subtraction, including CPU work, allocations and scheduling; it is not exclusive measured CPU time.",
        "Idle-resume is four full SDK requests after specified idle periods, not enough samples for a reliable tail percentile.",
        "Model instance is reused until explicit same-process reload. No application prediction cache. OS/CoreML caches are uncontrolled, not cleared or duplicated to manufacture cold starts.",
        "First configuration and execution order are randomized and recorded; configurations may influence later OS caches.",
        "Reference candidates/logits are interface/export comparisons, not a typing accuracy benchmark. FP16 may differ from source FP32.",
        "No implicit switch to another computeUnits configuration on failure; CoreML itself schedules within the allowed devices.",
        "Compiled model hash verification runs after latency measurements to avoid pre-reading model weights.",
        "Memory is20ms-sampled process footprint; battery/thermal are context, not watts or total GPU/ANE allocations.",
        "No compute-plan collection or hardware traces. Actual use of every allowed compute unit is not proven.",
        "The app is foreground-only. Stop takes effect between synchronous CoreML calls; failure/interruption records remain exportable."
    ]
}
