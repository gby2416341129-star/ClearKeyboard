import CoreML
import Foundation
import OSLog
import SwiftUI
import UIKit
import Darwin

@main
@MainActor
struct ANEProbeApp: App {
    var body: some Scene { WindowGroup { ProbeView() } }
}

private struct ProbeFixture: Decodable, Sendable {
    let prompt: String
    let tokenIDs: [Int32]
}

private struct ProbeModelInfo: Decodable, Sendable {
    let fingerprint: String
    let sourceRevision: String
    let embeddingFile: String
    let embeddingEncoding: String
    let headModels: [QwenANE.HeadModel]?
    let bodyOutput: String?
    let headInput: String?
    var modelNames: [String] { ANEPlan.bodyModelNames + (headModels ?? []).map(\.name) }
}

private enum ProbeBackend: String, CaseIterable, Sendable {
    case all, cpuAndGPU, cpuAndNeuralEngine
    static let executionOrder: [ProbeBackend] = [.all, .cpuAndGPU, .cpuAndNeuralEngine]
    var title: String {
        switch self {
        case .all: return "CPU + GPU + ANE（自动分配）"
        case .cpuAndGPU: return "CPU + GPU"
        case .cpuAndNeuralEngine: return "CPU + ANE"
        }
    }
    var computeUnits: MLComputeUnits {
        switch self {
        case .all: return .all
        case .cpuAndGPU: return .cpuAndGPU
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        }
    }
}

private struct ProbeIncident: Codable, Sendable {
    let timestamp: Date
    let stage: String
    let model: String?
    let cancelled: Bool
    let error: ANEFailure
}

private struct ProbeTrace: Codable, Sendable {
    let stage: String
    let round: Int?
    let event: ANEProgress
}

private struct ProbeSummary: Codable, Sendable {
    let sampleCount: Int
    let minimumMilliseconds: Double
    let medianMilliseconds: Double
    let empiricalP95Milliseconds: Double
    let maximumMilliseconds: Double
    let meanMilliseconds: Double
    let p95Method = "Nearest-rank empirical p95: sorted[ceil(0.95*n)-1]. Nine samples are a small descriptive sample, not a stable tail-latency estimate."

    init?(_ samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        sampleCount = sorted.count
        minimumMilliseconds = sorted[0]
        let middle = sorted.count / 2
        medianMilliseconds = sorted.count % 2 == 0
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        empiricalP95Milliseconds = sorted[max(0, Int(ceil(0.95 * Double(sorted.count))) - 1)]
        maximumMilliseconds = sorted[sorted.count - 1]
        meanMilliseconds = samples.reduce(0, +) / Double(samples.count)
    }
}

private struct ProbeRound: Codable, Sendable {
    let stage: String
    let index: Int
    let startedAt: Date
    let finishedAt: Date
    let resetMilliseconds: Double
    let prefillMilliseconds: Double
    let decodeStepMilliseconds: [Double]
    let predictedTokenIDs: [Int32]
    let teacherForcedContinuationTokenIDs: [Int32]
    let completedModelPredictionCalls: Int
    let expectedModelPredictionCalls: Int
    let peakSampledPhysicalFootprintBytes: UInt64
    let thermalStateBefore: Int
    let thermalStateAfter: Int
}

private struct PrefixReplayRound: Codable, Sendable {
    let index: Int
    let prefixTokenCount: Int
    let tailTokenCount: Int
    let fullReplayMilliseconds: Double
    let snapshotSetupMilliseconds: Double
    let branchAdvanceMilliseconds: Double
    let restoreAndTailMilliseconds: Double
    let checkpointBytes: Int
    let restoreCount: Int
    let fullReplayModelCalls: Int
    let restoredTailModelCalls: Int
    let expectedFullReplayModelCalls: Int
    let expectedRestoredTailModelCalls: Int
    let fullReplayBestToken: Int32
    let restoredTailBestToken: Int32
    let maximumAbsoluteLogitDifference: Float
}

private struct ProbeCase: Codable, Sendable {
    let computeUnits: String
    let title: String
    var executionStatus = "pending"
    var planStatus = "pending"
    var startedAt: Date?
    var finishedAt: Date?
    var loadMilliseconds: Double?
    var rounds: [ProbeRound] = []
    var traces: [ProbeTrace] = []
    var plans: [ANEChunkPlan] = []
    var failures: [ProbeIncident] = []
    var measuredDecodeSummary: ProbeSummary?
    var measuredPrefillSummary: ProbeSummary?
    var prefixReplayStatus = "pending"
    var prefixReplayRounds: [PrefixReplayRound] = []
}

private struct ProbeEvidence: Codable, Sendable {
    let schemaVersion = 5
    let suiteID: String
    let startedAt: Date
    let device: String
    let os: String
    let appVersion: String
    let appBuild: String
    let physicalMemoryBytes: UInt64
    let executionOrder = ProbeBackend.executionOrder.map(\.rawValue)
    let uniqueConfigurationNote = "CPU+NPU and NPU+CPU are the same cpuAndNeuralEngine configuration; they are run once. No automatic backend fallback."
    let cachePolicy = [
        "modelInstance": "Fresh QwenANE and MLModel instances for each backend; no instance is shared across backend cases.",
        "recurrentState": "reset() before every round clears KV/recurrent state, prompt history and last logits; the model instance stays loaded within its backend.",
        "systemCache": "Core ML device compilation/specialization caches are NOT cleared. First round means first call of this instance, not guaranteed system-cold execution.",
        "orderEffect": "Backends execute in the recorded fixed order. System caches, temperature and memory pressure can influence cross-backend comparisons.",
        "telemetry": "Per-model callback data is buffered in memory. UI updates and JSON writes occur outside timed inference, after each round.",
        "plans": "All placement-plan diagnostics run after all execution cases, so this suite does not inspect a backend plan before its execution benchmark.",
        "prefixReplay": "After the unchanged baseline, compare full replay with an explicit 18-token stable-prefix checkpoint and a one-token rewritten tail. Snapshot setup and tail advance are recorded separately. No automatic text truncation. Each timed restored-tail call must execute 8 real model predictions."
    ]
    let methodology = "Same bundled prompt plus fixed teacher-forced continuation for every backend. One first-call round, one warm-up round, then three measured rounds. Each round resets model state and performs a full prompt plus exactly three incremental calls, regardless of predicted EOS. Raw full-vocabulary logits are validated, argmax is recorded outside timed calls. This is a short model benchmark, not keyboard latency or accuracy."
    let fixedContinuationTokenIDs: [Int32] = [109266, 1710, 248046]
    let firstCallRounds = 1
    let warmupRounds = 1
    let measuredRounds = 3
    let plannedMeasuredDecodeSamples = 9
    let hardwareTraceCaptured = false
    let keyboardExtensionTested = false
    var updatedAt: Date
    var finishedAt: Date?
    var elapsedMilliseconds: Double = 0
    var status = "running"
    var stopReason: String?
    var phase = "prepare"
    var currentBackend: String?
    var currentModel: String?
    var fingerprint: String?
    var sourceRevision: String?
    var compiledModelSource: String?
    var modelNames: [String] = []
    var prompt: String?
    var promptTokenIDs: [Int32] = []
    var preparationEvents: [ANEProgress] = []
    var failures: [ProbeIncident] = []
    var cases = ProbeBackend.executionOrder.map { ProbeCase(computeUnits: $0.rawValue, title: $0.title) }
}

private enum ProbeUpdate: Sendable {
    case snapshot(ProbeEvidence)
    case stage(String, String?, String)
    case load(String, ANEProgress)
    case preparation(ANEProgress)
    case plan(String, ANEProgress)
    case checkpoint(CheckedContinuation<Void, Never>)
}

/// Native prediction callbacks only append to a small memory buffer. They never
/// write JSON or schedule UI work inside the measured inference interval.
private final class ProbeTraceBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ANEProgress] = []
    func append(_ event: ANEProgress) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
    func drain() -> [ANEProgress] {
        lock.lock()
        let result = events
        events.removeAll(keepingCapacity: true)
        lock.unlock()
        return result
    }
}

@MainActor
private final class ProbeSession: ObservableObject {
    @Published private(set) var status = "点开始后自动完成三种配置、首次计算、预热、重复测量及计划诊断。"
    @Published private(set) var isRunning = false
    @Published private(set) var reportURL: URL?
    @Published private(set) var startedAt: Date?
    @Published private(set) var stageStartedAt: Date?
    @Published private(set) var finishedAt: Date?
    @Published private(set) var currentBackend = "准备资源"
    @Published private(set) var cases: [ProbeCase] = []
    @Published private(set) var recentEvents: [String] = []
    @Published private(set) var saveError: String?
    @Published private(set) var stopRequested = false
    private var evidence: ProbeEvidence?
    private var worker: Task<Void, Never>?
    private var finalFileWritten = false
    private var previousIdleTimerDisabled = false

    init() {
        if let path = UserDefaults.standard.string(forKey: "latestAutomaticSuiteReport"),
           FileManager.default.fileExists(atPath: path) {
            reportURL = URL(fileURLWithPath: path)
        }
    }

    func start() {
        guard !isRunning else { return }
        let now = Date()
        let initial = ProbeEvidence(suiteID: UUID().uuidString, startedAt: now,
            device: machineIdentifier(), os: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, updatedAt: now)
        evidence = initial
        cases = initial.cases
        startedAt = now
        stageStartedAt = now
        finishedAt = nil
        stopRequested = false
        finalFileWritten = false
        reportURL = nil
        recentEvents = []
        status = "读取模型资料……"
        isRunning = true
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        persist()
        let (stream, continuation) = AsyncStream<ProbeUpdate>.makeStream()
        worker = Task.detached(priority: .userInitiated) {
            await performAutomaticSuite(initial: initial, updates: continuation)
        }
        Task { [weak self] in
            for await update in stream {
                if let self {
                    self.accept(update)
                } else if case .checkpoint(let checkpoint) = update {
                    checkpoint.resume()
                }
            }
            guard let self else { return }
            self.finishedAt = self.evidence?.finishedAt ?? Date()
            self.isRunning = false
            self.worker = nil
            UIApplication.shared.isIdleTimerDisabled = self.previousIdleTimerDisabled
            if self.evidence?.status == "running" {
                self.evidence?.status = "interrupted"
                self.evidence?.finishedAt = self.finishedAt
            }
            if let reason = self.evidence?.stopReason, self.stopRequested {
                self.status = "测试已停止：\(reason)。已保存完成阶段，可导出记录。"
            } else if self.evidence?.status == "completed" {
                let count = self.cases.filter { $0.executionStatus == "succeeded" }.count
                self.status = "自动测试完成：\(count)/3 种配置完成基线短推理。缓存改写对照、失败和计算计划也已保存在同一份记录中。"
            } else {
                self.status = "自动测试未完成，已保存已有结果和错误，可导出记录。"
            }
            self.persist(final: true)
        }
    }

    func requestStop(background: Bool = false) {
        guard isRunning, !stopRequested else { return }
        stopRequested = true
        evidence?.stopReason = background ? "App 进入后台，停止后续测试以避免后台调度影响测量" : "用户请求停止"
        worker?.cancel()
        status = "已请求停止。当前 Core ML 原生调用无法强制中断，调用返回后停止后续步骤。"
        persist()
    }

    private func accept(_ update: ProbeUpdate) {
        switch update {
        case .snapshot(var snapshot):
            if stopRequested { snapshot.stopReason = evidence?.stopReason }
            evidence = snapshot
            cases = snapshot.cases
            persist()
        case .stage(let phase, let backend, let message):
            evidence?.phase = phase
            evidence?.currentBackend = backend
            evidence?.currentModel = nil
            currentBackend = backend.flatMap(ProbeBackend.init(rawValue:))?.title ?? "准备资源"
            stageStartedAt = Date()
            if !stopRequested { status = message }
            appendLine(message)
            persist()
        case .load(let backend, let event):
            if let index = evidence?.cases.firstIndex(where: { $0.computeUnits == backend }) {
                evidence?.cases[index].traces.append(ProbeTrace(stage: "load", round: nil, event: event))
            }
            evidence?.currentModel = event.model
            if event.state == "started" { stageStartedAt = event.timestamp }
            let line = "\(ProbeBackend(rawValue: backend)?.title ?? backend) · 加载 \(event.model ?? "") · " +
                (event.state == "started" ? "开始" : String(format: "%.2f 秒", event.elapsedMilliseconds / 1000))
            if !stopRequested { status = line }
            appendLine(line)
            persist()
        case .preparation(let event):
            evidence?.preparationEvents.append(event)
            evidence?.currentModel = event.model
            if event.state == "started" { stageStartedAt = event.timestamp }
            if !stopRequested { status = event.detail ?? "准备模型 \(event.model ?? "") · \(event.state)" }
            persist()
        case .plan(let backend, let incoming):
            var event = incoming
            if let index = evidence?.cases.firstIndex(where: { $0.computeUnits == backend }) {
                if let plan = event.plan {
                    evidence?.cases[index].plans.append(plan)
                    event.plan = nil
                }
                evidence?.cases[index].traces.append(ProbeTrace(stage: "plan", round: nil, event: event))
                cases = evidence?.cases ?? []
            }
            evidence?.currentModel = event.model
            if event.state == "started" { stageStartedAt = event.timestamp }
            if !stopRequested { status = "\(ProbeBackend(rawValue: backend)?.title ?? backend) · 诊断 \(event.model ?? "") · \(event.state)" }
            persist()
        case .checkpoint(let continuation):
            // Acknowledge every preceding UI/file update before the worker
            // enters its next timed round. File I/O cannot overlap that round.
            continuation.resume()
        }
    }

    private func appendLine(_ line: String) {
        recentEvents.append(line)
        if recentEvents.count > 8 { recentEvents.removeFirst(recentEvents.count - 8) }
    }

    private func persist(final: Bool = false) {
        guard !finalFileWritten, var snapshot = evidence else { return }
        let now = Date()
        snapshot.updatedAt = now
        snapshot.elapsedMilliseconds = max(0, (snapshot.finishedAt ?? now).timeIntervalSince(snapshot.startedAt) * 1000)
        evidence = snapshot
        do {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AutomaticSuites")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let base = "ane-suite-\(formatter.string(from: snapshot.startedAt))-\(snapshot.suiteID)"
            let suffix = final ? snapshot.status : "partial"
            let output = directory.appendingPathComponent("\(base)-\(suffix).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: output, options: .atomic)
            reportURL = output
            UserDefaults.standard.set(output.path, forKey: "latestAutomaticSuiteReport")
            saveError = nil
            if final { finalFileWritten = true }
        } catch {
            saveError = "记录保存失败：\(error.localizedDescription)"
        }
    }
}

@MainActor
struct ProbeView: View {
    @StateObject private var session = ProbeSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Qwen 0.8B · 自动设备测试").font(.title2)
                Text("CPU + GPU + ANE → CPU + GPU → CPU + ANE")
                    .font(.callout).foregroundStyle(.secondary)
                Text(session.status).textSelection(.enabled)
                if let started = session.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        let end = session.finishedAt ?? timeline.date
                        Text("总耗时 \(Int(max(0, end.timeIntervalSince(started)))) 秒 · 当前阶段 \(Int(max(0, end.timeIntervalSince(session.stageStartedAt ?? started)))) 秒")
                            .font(.callout.monospacedDigit())
                    }
                }
                if session.isRunning { ProgressView(session.currentBackend) }
                Button("开始全部自动测试") { session.start() }
                    .buttonStyle(.borderedProminent).disabled(session.isRunning)
                if let report = session.reportURL {
                    ShareLink(session.isRunning ? "导出当前记录" : "导出全部记录", item: report)
                }
                if session.isRunning {
                    Button("当前调用结束后停止", role: .destructive) { session.requestStop() }
                        .disabled(session.stopRequested)
                }
                ForEach(session.cases, id: \.computeUnits) { result in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(result.title).font(.headline)
                        Text("执行：\(statusLabel(result.executionStatus)) · 计划：\(statusLabel(result.planStatus))")
                            .font(.caption)
                        if let load = result.loadMilliseconds {
                            Text(String(format: "加载：%.2f 秒", load / 1000))
                        }
                        if let first = result.rounds.first(where: { $0.stage == "firstCall" }) {
                            Text(String(format: "本实例首次提示词计算：%.1f ms", first.prefillMilliseconds))
                        }
                        if let summary = result.measuredDecodeSummary {
                            Text(String(format: "正式单步：中位数 %.2f ms · 经验 P95 %.2f ms（%d 个样本）",
                                summary.medianMilliseconds, summary.empiricalP95Milliseconds, summary.sampleCount))
                        }
                        if let full = ProbeSummary(result.prefixReplayRounds.map(\.fullReplayMilliseconds)),
                           let cached = ProbeSummary(result.prefixReplayRounds.map(\.restoreAndTailMilliseconds)) {
                            Text(String(format: "改写对照：整段重算 %.2f ms → 恢复前缀并重算尾部 %.2f ms",
                                full.medianMilliseconds, cached.medianMilliseconds))
                        }
                        if let error = result.failures.first(where: { !$0.cancelled }) {
                            Text("\(error.stage)\(error.model.map { " · \($0)" } ?? "")：\(error.error.domain) (\(error.error.code))")
                                .foregroundStyle(.red).textSelection(.enabled)
                        }
                    }.font(.callout.monospacedDigit())
                }
                if let error = session.saveError { Text(error).foregroundStyle(.red) }
                ForEach(Array(session.recentEvents.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).textSelection(.enabled)
                }
                Text("每种配置自动跑首次计算、1 轮预热、3 轮正式测量、3 轮前缀缓存改写对照，然后统一诊断计算计划。一种配置失败会继续下一种。CPU + NPU 与 NPU + CPU 是同一配置，合并测试。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("每轮清空上下文状态，固定相同输入。系统 Core ML 缓存不会清除；首次调用不代表系统完全冷启动。9 个单步样本的 P95 仅供本次观察。总耗时含加载与诊断，不等于打字延迟。测试期间请保持前台，App 会暂时关闭自动锁屏；进入后台后停止后续测试。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("计算计划是编译器分配信息，不是硬件执行轨迹。本工具不测试键盘扩展或输入准确率。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.requestStop(background: true) }
        }
    }
}

private func statusLabel(_ status: String) -> String {
    ["pending": "等待", "running": "进行中", "succeeded": "完成",
     "failed": "失败", "partial": "部分失败", "cancelled": "已停止",
     "completed": "完成"][status] ?? status
}

private func performAutomaticSuite(initial: ProbeEvidence,
                                   updates: AsyncStream<ProbeUpdate>.Continuation) async {
    defer { updates.finish() }
    var report = initial
    do {
        updates.yield(.stage("prepare", nil, "准备统一模型资源……"))
        guard let root = Bundle.main.resourceURL else { throw ANEError.invalid("Missing bundle resource directory") }
        let directory = root.appendingPathComponent("Qwen3.5-0.8B-IME-Q4")
        let info = try JSONDecoder().decode(ProbeModelInfo.self,
            from: Data(contentsOf: directory.appendingPathComponent("model-info.json")))
        guard let fixtureURL = Bundle.main.url(forResource: "fixture", withExtension: "json") else {
            throw ANEError.invalid("Missing fixture.json")
        }
        let fixture = try JSONDecoder().decode(ProbeFixture.self, from: Data(contentsOf: fixtureURL))
        guard !fixture.tokenIDs.isEmpty else { throw ANEError.invalid("Empty prompt fixture") }
        report.fingerprint = info.fingerprint
        report.sourceRevision = info.sourceRevision
        report.modelNames = info.modelNames
        report.prompt = fixture.prompt
        report.promptTokenIDs = fixture.tokenIDs
        let compiled: URL
        if info.modelNames.allSatisfy({ FileManager.default.fileExists(atPath: root.appendingPathComponent($0 + ".mlmodelc").path) }) {
            compiled = root
            report.compiledModelSource = "bundle-precompiled-ios"
        } else {
            compiled = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ANE").appendingPathComponent(info.fingerprint)
            report.compiledModelSource = "device-compiled-cache"
            let buffer = ProbeTraceBuffer()
            do {
                try await ANEPlan.prepare(packages: directory, cache: compiled, modelNames: info.modelNames) { event in
                    buffer.append(event)
                    updates.yield(.preparation(event))
                }
                report.preparationEvents += buffer.drain()
            } catch {
                report.preparationEvents += buffer.drain()
                throw error
            }
        }
        updates.yield(.snapshot(report))

        // Execute all cases before any compute-plan diagnostic can pre-warm one.
        for (index, backend) in ProbeBackend.executionOrder.enumerated() {
            try Task.checkCancellation()
            report.phase = "execution"
            report.currentBackend = backend.rawValue
            report.currentModel = nil
            report.cases[index].executionStatus = "running"
            updates.yield(.snapshot(report))
            report.cases[index] = await runExecutionCase(backend: backend, compiled: compiled,
                directory: directory, info: info, fixture: fixture,
                continuation: report.fixedContinuationTokenIDs, updates: updates,
                priorCases: report.cases, baseReport: report, caseIndex: index)
            updates.yield(.snapshot(report))
        }
        for (index, backend) in ProbeBackend.executionOrder.enumerated() {
            try Task.checkCancellation()
            report.phase = "plan"
            report.currentBackend = backend.rawValue
            report.currentModel = nil
            report.cases[index].planStatus = "running"
            updates.yield(.snapshot(report))
            updates.yield(.stage("plan", backend.rawValue, "\(backend.title) · 自动读取计算计划……"))
            let buffer = ProbeTraceBuffer()
            do {
                let plans = try await ANEPlan.inspect(directory: compiled, modelNames: info.modelNames,
                    computeUnits: backend.computeUnits, continueOnFailure: true) { event in
                    buffer.append(event)
                    updates.yield(.plan(backend.rawValue, event))
                }
                let events = buffer.drain()
                report.cases[index].plans = plans
                report.cases[index].traces += events.map { ProbeTrace(stage: "plan", round: nil, event: withoutPlan($0)) }
                for event in events where event.error != nil {
                    report.cases[index].failures.append(ProbeIncident(timestamp: event.timestamp,
                        stage: "plan", model: event.model, cancelled: false, error: event.error!))
                }
                report.cases[index].planStatus = plans.count == info.modelNames.count ? "succeeded" : "partial"
            } catch {
                let events = buffer.drain()
                report.cases[index].plans = events.compactMap(\.plan)
                report.cases[index].traces += events.map { ProbeTrace(stage: "plan", round: nil, event: withoutPlan($0)) }
                for event in events where event.error != nil {
                    report.cases[index].failures.append(ProbeIncident(timestamp: event.timestamp,
                        stage: "plan", model: event.model, cancelled: false, error: event.error!))
                }
                report.cases[index].failures.append(ProbeIncident(timestamp: Date(), stage: "plan",
                    model: events.last?.model, cancelled: error is CancellationError || Task.isCancelled,
                    error: ANEFailure.capture(error)))
                report.cases[index].planStatus = Task.isCancelled ? "cancelled" : "failed"
                if error is CancellationError || Task.isCancelled { throw error }
            }
            updates.yield(.snapshot(report))
        }
        try Task.checkCancellation()
        report.status = "completed"
        report.phase = "finished"
    } catch {
        let cancelled = error is CancellationError || Task.isCancelled
        report.status = cancelled ? "cancelled" : "failed"
        report.failures.append(ProbeIncident(timestamp: Date(), stage: report.phase,
            model: report.currentModel, cancelled: cancelled, error: ANEFailure.capture(error)))
    }
    report.finishedAt = Date()
    report.updatedAt = Date()
    report.elapsedMilliseconds = report.finishedAt!.timeIntervalSince(report.startedAt) * 1000
    updates.yield(.snapshot(report))
}

private func runExecutionCase(backend: ProbeBackend, compiled: URL, directory: URL,
                              info: ProbeModelInfo, fixture: ProbeFixture, continuation: [Int32],
                              updates: AsyncStream<ProbeUpdate>.Continuation,
                              priorCases: [ProbeCase], baseReport: ProbeEvidence, caseIndex: Int) async -> ProbeCase {
    var result = priorCases[caseIndex]
    result.startedAt = Date()
    result.executionStatus = "running"
    let buffer = ProbeTraceBuffer()
    var currentStage = "load"
    var currentRound: Int?
    func publish() {
        var snapshot = baseReport
        snapshot.cases = priorCases
        snapshot.cases[caseIndex] = result
        snapshot.currentBackend = backend.rawValue
        snapshot.phase = currentStage
        snapshot.updatedAt = Date()
        updates.yield(.snapshot(snapshot))
    }
    do {
        try Task.checkCancellation()
        updates.yield(.stage("load", backend.rawValue, "\(backend.title) · 加载独立模型实例……"))
        guard let encoding = QwenANE.EmbeddingEncoding(rawValue: info.embeddingEncoding) else {
            throw ANEError.invalid("Unknown embedding encoding: \(info.embeddingEncoding)")
        }
        let start = ProcessInfo.processInfo.systemUptime
        let engine = try QwenANE(compiledDirectory: compiled,
            embeddingURL: directory.appendingPathComponent(info.embeddingFile), embeddingEncoding: encoding,
            headModels: info.headModels ?? [], bodyOutput: info.bodyOutput,
            headInput: info.headInput ?? "normed_hidden", computeUnits: backend.computeUnits,
            progress: { message in
                let event = runtimeEvent(message)
                buffer.append(event)
                if event.phase == "load" { updates.yield(.load(backend.rawValue, event)) }
            })
        result.loadMilliseconds = milliseconds(since: start)
        result.traces += buffer.drain().map { ProbeTrace(stage: "load", round: nil, event: $0) }
        publish()
        await acknowledgeUpdates(updates)
        try Task.checkCancellation()
        let stages = [("firstCall", 1), ("warmup", 1), ("measured", 3)]
        for (stage, count) in stages {
            currentStage = stage
            for index in 1...count {
                try Task.checkCancellation()
                currentRound = index
                let label = stage == "firstCall" ? "首次完整短推理" : stage == "warmup" ? "预热" : "正式测量"
                updates.yield(.stage(stage, backend.rawValue, "\(backend.title) · \(label) \(index)/\(count)"))
                await acknowledgeUpdates(updates)
                try Task.checkCancellation()
                let startedAt = Date()
                let thermalBefore = ProcessInfo.processInfo.thermalState.rawValue
                let resetStart = ProcessInfo.processInfo.systemUptime
                try await engine.reset()
                let resetMs = milliseconds(since: resetStart)
                var sequence = fixture.tokenIDs
                var footprint = physicalFootprint()
                var predictions: [Int32] = []
                var decode: [Double] = []
                let log = OSLog(subsystem: "local.QwenANEProbe", category: .pointsOfInterest)
                os_signpost(.begin, log: log, name: "SuitePrefill")
                let prefillStart = ProcessInfo.processInfo.systemUptime
                var logits: [Float]
                do { logits = try await engine.logits(for: sequence) }
                catch { os_signpost(.end, log: log, name: "SuitePrefill"); throw error }
                let prefillMs = milliseconds(since: prefillStart)
                os_signpost(.end, log: log, name: "SuitePrefill")
                predictions.append(try bestToken(logits))
                footprint = max(footprint, physicalFootprint())
                for token in continuation {
                    try Task.checkCancellation()
                    sequence.append(token)
                    os_signpost(.begin, log: log, name: "SuiteDecode")
                    let stepStart = ProcessInfo.processInfo.systemUptime
                    do { logits = try await engine.logits(for: sequence) }
                    catch { os_signpost(.end, log: log, name: "SuiteDecode"); throw error }
                    decode.append(milliseconds(since: stepStart))
                    os_signpost(.end, log: log, name: "SuiteDecode")
                    predictions.append(try bestToken(logits))
                    footprint = max(footprint, physicalFootprint())
                }
                let events = buffer.drain()
                result.traces += events.map { ProbeTrace(stage: stage, round: index, event: $0) }
                let completedCalls = events.filter { $0.phase == "inference" && $0.state == "succeeded" }.count
                let expectedCalls = (fixture.tokenIDs.count + continuation.count) * ANEPlan.bodyModelNames.count
                    + (continuation.count + 1) * (info.headModels?.count ?? 0)
                guard completedCalls == expectedCalls else {
                    throw ANEError.invalid("Prediction-call count \(completedCalls), expected \(expectedCalls); a fresh round must execute every required model, not reuse previous logits")
                }
                result.rounds.append(ProbeRound(stage: stage, index: index, startedAt: startedAt,
                    finishedAt: Date(), resetMilliseconds: resetMs, prefillMilliseconds: prefillMs,
                    decodeStepMilliseconds: decode, predictedTokenIDs: predictions,
                    teacherForcedContinuationTokenIDs: continuation,
                    completedModelPredictionCalls: completedCalls, expectedModelPredictionCalls: expectedCalls,
                    peakSampledPhysicalFootprintBytes: footprint, thermalStateBefore: thermalBefore,
                    thermalStateAfter: ProcessInfo.processInfo.thermalState.rawValue))
                let measured = result.rounds.filter { $0.stage == "measured" }
                result.measuredDecodeSummary = ProbeSummary(measured.flatMap(\.decodeStepMilliseconds))
                result.measuredPrefillSummary = ProbeSummary(measured.map(\.prefillMilliseconds))
                publish()
                await acknowledgeUpdates(updates)
            }
        }
        try Task.checkCancellation()
        result.executionStatus = "succeeded"
        currentStage = "prefixReplay"
        result.prefixReplayStatus = "running"
        publish()
        await acknowledgeUpdates(updates)
        do {
            for index in 1...3 {
                currentRound = index
                updates.yield(.stage("prefixReplay", backend.rawValue,
                    "\(backend.title) · 前缀缓存改写对照 \(index)/3"))
                await acknowledgeUpdates(updates)
                let (round, traces) = try await prefixReplayRound(engine: engine,
                    fixture: fixture, continuation: continuation, heads: info.headModels?.count ?? 0,
                    index: index, buffer: buffer)
                result.prefixReplayRounds.append(round)
                result.traces += traces
                publish()
                await acknowledgeUpdates(updates)
            }
            result.prefixReplayStatus = "succeeded"
        } catch {
            if error is CancellationError || Task.isCancelled {
                result.prefixReplayStatus = "cancelled"
                throw error
            }
            result.prefixReplayStatus = "failed"
            result.traces += buffer.drain().map { ProbeTrace(stage: "prefixReplay", round: currentRound, event: $0) }
            result.failures.append(ProbeIncident(timestamp: Date(), stage: "prefixReplay", model: nil,
                cancelled: false, error: ANEFailure.capture(error)))
        }
    } catch {
        let events = buffer.drain()
        result.traces += events.map { ProbeTrace(stage: currentStage, round: currentRound, event: $0) }
        let cancelled = error is CancellationError || Task.isCancelled
        result.executionStatus = cancelled ? "cancelled" : "failed"
        let last = events.last ?? result.traces.last?.event
        result.failures.append(ProbeIncident(timestamp: Date(), stage: currentStage,
            model: last?.model, cancelled: cancelled, error: ANEFailure.capture(error)))
    }
    result.finishedAt = Date()
    return result
}

private func prefixReplayRound(engine: QwenANE, fixture: ProbeFixture, continuation: [Int32],
                               heads: Int, index: Int, buffer: ProbeTraceBuffer) async throws
    -> (PrefixReplayRound, [ProbeTrace]) {
    try Task.checkCancellation()
    guard !continuation.isEmpty else { throw ANEError.invalid("Missing fixed tail fixture") }
    let rewritten = fixture.tokenIDs + Array(continuation.prefix(1))
    let advanced = fixture.tokenIDs + continuation
    var traces: [ProbeTrace] = []
    func take(_ stage: String) -> Int {
        let events = buffer.drain()
        traces += events.map { ProbeTrace(stage: stage, round: index, event: $0) }
        return events.filter { $0.phase == "inference" && $0.state == "succeeded" }.count
    }
    try await engine.reset()
    let fullStart = ProcessInfo.processInfo.systemUptime
    let full = try await engine.logits(for: rewritten)
    let fullMs = milliseconds(since: fullStart)
    let fullCalls = take("prefixReplay.full")
    try await engine.reset()
    let setupStart = ProcessInfo.processInfo.systemUptime
    let saved = try await engine.prepareStablePrefix(fixture.tokenIDs)
    let setupMs = milliseconds(since: setupStart)
    _ = take("prefixReplay.setup")
    let advanceStart = ProcessInfo.processInfo.systemUptime
    _ = try await engine.logits(for: advanced)
    let advanceMs = milliseconds(since: advanceStart)
    _ = take("prefixReplay.advance")
    let cachedStart = ProcessInfo.processInfo.systemUptime
    let restored = try await engine.logits(for: rewritten)
    let cachedMs = milliseconds(since: cachedStart)
    let cachedCalls = take("prefixReplay.restore")
    guard let usage = await engine.prefixCacheInfo() else { throw ANEError.invalid("Missing stable checkpoint") }
    let fullExpected = rewritten.count * ANEPlan.bodyModelNames.count + heads
    let restoredExpected = (rewritten.count - fixture.tokenIDs.count) * ANEPlan.bodyModelNames.count + heads
    guard fullCalls == fullExpected, cachedCalls == restoredExpected, usage.restoreCount == 1 else {
        throw ANEError.invalid("Prefix replay did not execute the required full/tail predictions and one actual restore")
    }
    let difference = zip(full, restored).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
    return (PrefixReplayRound(index: index, prefixTokenCount: fixture.tokenIDs.count,
        tailTokenCount: rewritten.count - fixture.tokenIDs.count,
        fullReplayMilliseconds: fullMs, snapshotSetupMilliseconds: setupMs,
        branchAdvanceMilliseconds: advanceMs, restoreAndTailMilliseconds: cachedMs,
        checkpointBytes: saved.bytes, restoreCount: usage.restoreCount,
        fullReplayModelCalls: fullCalls, restoredTailModelCalls: cachedCalls,
        expectedFullReplayModelCalls: fullExpected, expectedRestoredTailModelCalls: restoredExpected,
        fullReplayBestToken: try bestToken(full), restoredTailBestToken: try bestToken(restored),
        maximumAbsoluteLogitDifference: difference), traces)
}

private func bestToken(_ logits: [Float]) throws -> Int32 {
    guard logits.count == QwenANE.vocabularySize else { throw ANEError.invalid("Incomplete vocabulary logits") }
    var index = 0
    var best = -Float.infinity
    for (offset, value) in logits.enumerated() {
        guard value.isFinite else { throw ANEError.invalid("Non-finite vocabulary logit at \(offset)") }
        if value > best { best = value; index = offset }
    }
    return Int32(index)
}

private func acknowledgeUpdates(_ updates: AsyncStream<ProbeUpdate>.Continuation) async {
    await withCheckedContinuation { continuation in
        updates.yield(.checkpoint(continuation))
    }
}

private func runtimeEvent(_ message: String) -> ANEProgress {
    let fields = message.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    if fields.count >= 3, fields[0] == "load" {
        return ANEProgress(phase: "load", model: fields[2],
            state: fields[1] == "start" ? "started" : "succeeded",
            elapsedMilliseconds: fields.count > 3 ? Double(fields[3]) ?? 0 : 0, detail: message)
    }
    if fields.count >= 4, fields[0] == "inference" {
        return ANEProgress(phase: "inference", model: fields[2], tokenOffset: Int(fields[3]),
            state: ["start": "started", "complete": "succeeded", "failed": "failed"][fields[1]] ?? fields[1],
            elapsedMilliseconds: fields.count > 4 ? Double(fields[4]) ?? 0 : 0, detail: message)
    }
    return ANEProgress(phase: "runtime", state: "message", detail: message)
}

private func withoutPlan(_ incoming: ANEProgress) -> ANEProgress {
    var event = incoming
    event.plan = nil
    return event
}

private func milliseconds(since start: TimeInterval) -> Double {
    (ProcessInfo.processInfo.systemUptime - start) * 1000
}

private func physicalFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let code = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return code == KERN_SUCCESS ? info.phys_footprint : 0
}

private func machineIdentifier() -> String {
    var system = utsname()
    uname(&system)
    let capacity = MemoryLayout.size(ofValue: system.machine)
    return withUnsafePointer(to: &system.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
    }
}
