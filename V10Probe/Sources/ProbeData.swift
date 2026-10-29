import Foundation
@preconcurrency import CoreML
import Darwin
import CryptoKit
import UIKit

enum ProbeMode: String, Codable, CaseIterable, Sendable {
    case cpuOnly, cpuAndGPU, cpuAndNeuralEngine, all
    var title: String {
        switch self {
        case .cpuOnly: return "CPU"
        case .cpuAndGPU: return "CPU + GPU"
        case .cpuAndNeuralEngine: return "CPU + ANE（NPU）"
        case .all: return "CPU + GPU + ANE（系统调度）"
        }
    }
    var units: MLComputeUnits {
        switch self {
        case .cpuOnly: return .cpuOnly
        case .cpuAndGPU: return .cpuAndGPU
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        case .all: return .all
        }
    }
}

struct NativeFailure: Codable, Sendable {
    let domain: String
    let code: Int
    let message: String
    let details: [String: String]
    let underlying: [NativeFailure]
    static func capture(_ error: Error) -> NativeFailure {
        var seen = Set<ObjectIdentifier>()
        func visit(_ error: NSError, depth: Int) -> NativeFailure {
            guard depth < 8, seen.insert(ObjectIdentifier(error)).inserted else {
                return NativeFailure(domain: error.domain, code: error.code,
                    message: "Previously captured NSError", details: [:], underlying: [])
            }
            var children: [NativeFailure] = []
            var details: [String: String] = [:]
            for (key, value) in error.userInfo {
                details[key] = String(reflecting: value)
                if let child = value as? NSError { children.append(visit(child, depth: depth + 1)) }
                if let array = value as? [NSError] {
                    children.append(contentsOf: array.map { visit($0, depth: depth + 1) })
                }
            }
            return NativeFailure(domain: error.domain, code: error.code,
                message: error.localizedDescription, details: details, underlying: children)
        }
        return visit(error as NSError, depth: 0)
    }
}

struct FixtureTensor: Decodable {
    let shape: [Int]
    let dtype: String
    let data: [Double]
    func multiArray() throws -> MLMultiArray {
        guard shape.reduce(1, *) == data.count, ["int32", "float32"].contains(dtype) else {
            throw ProbeError.invalid("Invalid frozen tensor")
        }
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) },
                                    dataType: dtype == "int32" ? .int32 : .float32)
        for index in data.indices { array[index] = NSNumber(value: data[index]) }
        return array
    }
}

struct FixtureRequest: Decodable {
    let rawInput: String
    let committedContext: String
    let inputMode: V10InputMode
    let candidates: [V10Candidate]
    let ruleID: String
    enum CodingKeys: String, CodingKey {
        case rawInput = "raw_input", committedContext = "committed_context"
        case inputMode = "input_mode", candidates, ruleID = "rule_id"
    }
    func request(revision: UInt64) -> V10Request {
        V10Request(revision: revision, committedContext: committedContext, rawInput: rawInput,
                   mode: inputMode, candidates: candidates, ruleCandidateID: ruleID)
    }
}

struct SourceOutputs: Decodable {
    let scores: [Float]
    let acceptanceLogits: [Float]
    let proposalIndex: [Int]
    let adoptLogit: [Float]
    enum CodingKeys: String, CodingKey {
        case scores, acceptanceLogits = "acceptance_logits"
        case proposalIndex = "proposal_index", adoptLogit = "adopt_logit"
    }
}
struct SourceDecision: Decodable {
    let finalID: String
    let adopted: Bool
    enum CodingKeys: String, CodingKey { case finalID = "final_id", adopted }
}
struct FixedCase: Decodable {
    let caseID: String
    let request: FixtureRequest
    let tensors: [String: FixtureTensor]
    let source: SourceOutputs
    let decision: SourceDecision
    enum CodingKeys: String, CodingKey {
        case caseID = "case_id", request, tensors = "input_tensors"
        case source = "source_outputs_fp32", decision = "source_final_decision"
    }
}
struct FixtureFile: Decodable {
    let allCases: [FixedCase]
    enum CodingKeys: String, CodingKey { case allCases = "all_cases" }
}
struct PreparedCase {
    let source: FixedCase
    let provider: MLDictionaryFeatureProvider
}

struct LatencySummary: Codable, Sendable {
    let count: Int
    let p50MS: Double
    let p95MS: Double
    let p99MS: Double
    let minimumMS: Double
    let maximumMS: Double
    let meanMS: Double
    let percentileMethod: String
    init?(_ values: [Double]) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double {
            sorted[max(0, min(sorted.count - 1, Int(ceil(p * Double(sorted.count))) - 1))]
        }
        count = sorted.count; p50MS = percentile(0.50); p95MS = percentile(0.95)
        p99MS = percentile(0.99); minimumMS = sorted[0]; maximumMS = sorted[sorted.count - 1]
        meanMS = values.reduce(0, +) / Double(values.count)
        percentileMethod = "nearest-rank; raw timings included"
    }
}

struct SystemSample: Codable, Sendable {
    let time: Date
    let footprintBytes: UInt64?
    let thermalState: String
    let lowPowerMode: Bool
    let processCPUSeconds: Double?
    let batteryLevel: Float?
    let batteryState: String
    static func capture(battery: Float?, batteryState: String) -> SystemSample {
        var usage = rusage()
        let cpu: Double?
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        } else { cpu = nil }
        return SystemSample(time: Date(), footprintBytes: physicalFootprint(),
            thermalState: String(describing: ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            processCPUSeconds: cpu, batteryLevel: battery, batteryState: batteryState)
    }
}

func physicalFootprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let code = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return code == KERN_SUCCESS ? info.phys_footprint : nil
}

final class MemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var samples = 0
    private var timer: DispatchSourceTimer?
    func start() {
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "che.v10.memory", qos: .utility))
        source.schedule(deadline: .now(), repeating: .milliseconds(20))
        source.setEventHandler { [weak self] in
            guard let self, let value = physicalFootprint() else { return }
            self.lock.lock(); self.peak = max(self.peak, value); self.samples += 1; self.lock.unlock()
        }
        timer = source; source.resume()
    }
    func stop() -> (UInt64?, Int) {
        timer?.cancel(); timer = nil
        lock.lock(); defer { lock.unlock() }
        return (samples == 0 ? nil : peak, samples)
    }
}

struct TensorParity: Codable, Sendable {
    let caseID: String
    let maximumFloatError: Double
    let integerMismatches: Int
    let floatMismatchesAboveTolerance: Int
    let tolerance: Double
}
struct OutputComparison: Codable, Sendable {
    let caseID: String
    let maximumScoreError: Float
    let maximumAcceptanceError: Float
    let adoptionLogitError: Float
    let proposalMatchesSource: Bool
    let finalDecisionMatchesSource: Bool
    let expectedFinalID: String
    let actualFinalID: String
    let actualProposalID: String
    let actualFinalText: String
    let actualAdopted: Bool
    let adoptionProbability: Float
    let sourceProposalIndex: Int
    let actualProposalIndex: Int
    let validCandidateCount: Int
    let isProtected: Bool
    let scores: [Float]
    let acceptanceLogits: [Float]
    let adoptLogit: Float
}
struct OperationPlacement: Codable, Sendable {
    let function: String
    let operation: String
    let preferred: String
    let supported: [String]
    let relativeCost: Double?
    let constant: Bool
}
struct PlanRecord: Codable, Sendable {
    var status = "not_started"
    var milliseconds: Double?
    var plannedCPU = 0
    var plannedGPU = 0
    var plannedANE = 0
    var operations: [OperationPlacement] = []
    var error: NativeFailure?
    let evidenceKind = "compiler placement plan, not a hardware execution trace"
}
struct ModeResult: Codable, Sendable, Identifiable {
    var id: String { mode.rawValue }
    let mode: ProbeMode
    let effectiveConfiguration: ProbeMode
    var status = "pending"
    var phase = "等待"
    var phaseStartedAt: Date?
    var phaseNumber = 0
    var startedAt: Date?
    var finishedAt: Date?
    var firstModelLoadMS: Double?
    var sameProcessReloadMS: Double?
    var firstPredictionMS: Double?
    var warmedModelTimingsMS: [Double] = []
    var adapterTimingsMS: [Double] = []
    var protectedAdapterTimingsMS: [Double] = []
    var idleResumeTimingsMS: [Double] = []
    var predictionCaseIDs: [String] = []
    var adapterCaseIDs: [String] = []
    var warmSummary: LatencySummary?
    var adapterSummary: LatencySummary?
    var idleResumeSummary: LatencySummary?
    var comparisons: [OutputComparison] = []
    var plan = PlanRecord()
    var before: SystemSample?
    var after: SystemSample?
    var footprintAfterLoad: UInt64?
    var sampledPeakFootprintBytes: UInt64?
    var memorySamples = 0
    var completedNativePredictions = 0
    var outputChecksum: Double = 0
    var errors: [NativeFailure] = []
    let implicitFallbackUsed = false
    let cacheState = "OS/CoreML specialization cache uncontrolled; no application prediction cache"
    let trueUncachedColdStartVerified = false
}
struct JournalEvent: Codable, Sendable {
    let time: Date
    let mode: String?
    let phase: String
    let detail: String
}
struct SuiteReport: Codable, Sendable {
    let schemaVersion = 1
    let suiteID: String
    let modelVersion = "V10"
    let probeBuild = 1
    let checkpointSHA256 = "0d27285db15f626a04d37e00070e3c63c803ddb176860be409d069119aca9423"
    let startedAt: Date
    var finishedAt: Date?
    var status = "running"
    var phase = "准备资源"
    var modeOrder: [ProbeMode]
    var results: [ModeResult]
    var inputParity: [TensorParity] = []
    var events: [JournalEvent] = []
    var errors: [NativeFailure] = []
    let device: [String: String]
    var resourceSHA256: [String: String] = [:]
    var resourcePreparationMS: Double?
    var compiledModelIntegrityVerified = false
    let hardwareTraceCaptured = false
    let keyboardExtensionTested = false
    let candidateSearchIncluded = false
    let UIFrameLatencyMeasured = false
    let wattsMeasured = false
    let applicationPredictionCacheEnabled = false
    let samplesAreQualityAcceptance = false
    let researchOnly = true
    let deploymentReady = false
    let measurementNotes = [
        "Four strict public CoreML configurations. No GPU-only or ANE-only public selection.",
        "Model latency: synchronous prediction plus one scalar output read; prebuilt frozen tensors.",
        "Adapter latency: V10 tokenization, tensors, inference and full selection policy; no candidate search or UI.",
        "15 fixed source cases verify export/interface behavior, not real typing accuracy.",
        "Protected literals bypass the adapter model; their timings are reported separately.",
        "Warm samples cycle across fixed cases; each sample still calls CoreML, internal caches uncontrolled.",
        "First load is first for that configuration in this suite, not proven uncached OS/device cold start.",
        "Compiled model bytes are hash-verified AFTER timing runs to avoid pre-reading weights before first load.",
        "Peak is 20ms sampled process physical footprint, not total GPU/ANE allocation or guaranteed absolute peak.",
        "Battery/thermal/CPU time are context only, not energy in joules or power in watts.",
        "Compute plans are collected after timed inference to avoid warming the first-load measurements.",
        "Native CoreML calls cannot be forcibly interrupted safely; stop takes effect between calls."
    ]
}

enum ProbeError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
func elapsedMS(_ start: TimeInterval) -> Double { (ProcessInfo.processInfo.systemUptime - start) * 1000 }
func fileSHA256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func deviceMachine() -> String {
    var system = utsname(); uname(&system)
    let capacity = MemoryLayout.size(ofValue: system.machine)
    return withUnsafePointer(to: &system.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
    }
}
