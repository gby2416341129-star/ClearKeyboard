import Foundation
@preconcurrency import CoreML

let v49Checkpoint = "6b2a81977f112ebdc1763198dac5e7e68caeef0d4d65fc7819ec3133e5929f58"
struct ProbeFixtureFile: Decodable { let sourceSHA256: String; let cases: [ProbeFixture] }
struct ProbeFixture: Decodable {
    let id: String, raw: String, context: String
    let tensors: [String:[Int32]]
    func provider() throws -> MLDictionaryFeatureProvider {
        guard let mask=tensors["pinyin_mask"],mask.count==64 else { throw ProbeError.invalid("Missing fixture mask") }
        let used=(mask.lastIndex(where:{$0 != 0}) ?? 0)+1
        let width=64
        var result:[String:MLFeatureValue]=[:]
        for name in ["context_ids","context_mask","pinyin_ids","pinyin_mask"] {
            let size=name.hasPrefix("pinyin") ? width : 32
            guard let values=tensors[name],values.count>=size else { throw ProbeError.invalid("Missing fixture tensor: \(name)") }
            let array=try MLMultiArray(shape:[1,NSNumber(value:size)],dataType:.int32)
            let pointer=array.dataPointer.assumingMemoryBound(to:Int32.self)
            for i in 0..<size { pointer[i]=values[i] }
            result[name]=MLFeatureValue(multiArray:array)
        }
        return try MLDictionaryFeatureProvider(dictionary:result)
    }
}
struct RequestTiming: Codable, Sendable {
    let caseID: String
    let raw: String
    let milliseconds: Double
    let paths: Int
    let candidateCount: Int
    let status: String
    let timings: V21Timings
}
struct ModeResult: Codable, Sendable, Identifiable {
    var id:String { mode.rawValue }
    let mode:ProbeMode
    var status="pending"
    var phase="等待"
    var preparationMS:[String:Double]=[:]
    var firstCompleteRequest:RequestTiming?
    var firstBodyPredictionMS:Double?
    var warmedBodyMS:[Double]=[]
    var warmedBodyCaseIDs:[String]=[]
    var completeRequests:[RequestTiming]=[]
    var idleRequests:[RequestTiming]=[]
    var bodySummary:LatencySummary?
    var completeSummary:LatencySummary?
    var reloadPreparationMS:[String:Double]=[:]
    var firstRequestAfterReload:RequestTiming?
    var before:SystemSample?
    var after:SystemSample?
    var peakFootprintBytes:UInt64?
    var memorySamples=0
    var checksum:Double=0
    var errors:[NativeFailure]=[]
}
struct SuiteReport: Codable, Sendable {
    let schemaVersion=1
    let suiteID:String
    let modelVersion="V49"
    let sourceLocalStep=1408
    let sourceGlobalStep=94661
    let graphRevision="v49-static64-bc1s-2"
    let outputLayout="B,C,1,T=1,8192,1,64"
    let parameterCount=21020402
    let checkpointSHA256=v49Checkpoint
    let probeBuild=2
    let startedAt:Date
    var finishedAt:Date?
    var status="running"
    var phase="准备"
    let modeOrder:[ProbeMode]
    var results:[ModeResult]
    let device:[String:String]
    var errors:[NativeFailure]=[]
    var compiledModelIntegrityVerified=false
    let warmupCount=20
    let measuredBodyCountPerMode=300
    let measuredCompleteRequestCountPerMode=120
    let applicationPredictionCacheEnabled=false
    let implicitComputeConfigurationFallback=false
    let hardwareTraceCaptured=false
    let keyboardExtensionTested=false
    let UIFrameLatencyMeasured=false
    let wattsMeasured=false
    let researchOnly=true
    let qualityPassed=false
    let measurementNotes=[
        "User starts this independent foreground app. Both Core ML models are V49 local1408/global94661.",
        "Four allowed compute configurations are randomized. No configuration fallback or prediction before the first SDK request.",
        "Build2 changes only the export layout and CPU legal-ID extraction. Fixed64 BC1S, 1x1 convolution projections, per-head attention; same V49 tensors and native parsing/scoring/beam.",
        "Body-only timings use pre-encoded path0 inputs, with original token IDs and fixed64 padding, matching the repaired SDK. They exclude parsing, decoding and auxiliary scoring.",
        "Full requests include real parsing, body predictions, native search, sequence/channel model and final candidates. Individual SDK component timings are saved.",
        "Fourteen original V19 latency stimuli are retained only as inputs. V19 output logits/candidates are not reused as V49 correctness references.",
        "Application tensor/result caches and startup priming are disabled in this standalone copy. Core ML and OS caches are uncontrolled; this is not verified uncached cold start.",
        "Compiled model hashes are read after timings. Resources are verified by SDK preparation. Memory is 20ms-sampled process footprint.",
        "Allowed compute units do not prove actual ANE/GPU placement. No hardware trace, watts, keyboard-extension latency, UI latency or accuracy acceptance is measured."
    ]
}
