import CoreML
import Foundation
import OSLog
import SwiftUI
import Darwin

@main
@MainActor
struct ANEProbeApp: App {
    var body: some Scene { WindowGroup { ProbeView() } }
}

struct ProbeFixture: Decodable {
    let prompt: String
    let tokenIDs: [Int32]
}

struct ProbeModelInfo: Decodable, Sendable {
    let fingerprint: String
    let sourceRevision: String
    let embeddingFile: String
    let embeddingEncoding: String
    let headModels: [QwenANE.HeadModel]?
    let bodyOutput: String?
    let headInput: String?

    var modelNames: [String] {
        ANEPlan.bodyModelNames + (headModels ?? []).map(\.name)
    }
}

struct ProbeResult: Codable, Sendable {
    let modelRevision: String
    let computeUnits: String
    let promptTokens: Int
    let loadMilliseconds: Double
    let firstTokenMilliseconds: Double
    let decodeSteps: Int
    let decodeMilliseconds: Double
    let decodeStepMilliseconds: [Double]
    let outputTokenIDs: [Int32]
    let peakSampledPhysicalFootprintBytes: UInt64
    let thermalState: Int
}

private struct ProbeIncident: Codable, Sendable {
    let timestamp: Date
    let phase: String
    let model: String?
    let phaseElapsedMilliseconds: Double
    let cancelled: Bool
    let error: ANEFailure
}

private struct ProbeEvidence: Codable, Sendable {
    let schemaVersion = 3
    let runID: String
    let startedAt: Date
    let device: String
    let os: String
    let appVersion: String
    let appBuild: String
    let physicalMemoryBytes: UInt64
    let computeUnits: String
    let hardwareTraceCaptured = false
    let keyboardExtensionTested = false
    var updatedAt: Date
    var operationStartedAt: Date
    var operationFinishedAt: Date?
    var operation: String
    var phase: String
    var currentModel: String?
    var elapsedMilliseconds: Double = 0
    var fingerprint: String?
    var sourceRevision: String?
    var modelNames: [String] = []
    var compiledModelSource: String?
    var executionStatus = "尚未运行"
    var planStatus = "尚未诊断"
    var events: [ANEProgress] = []
    var plans: [ANEChunkPlan] = []
    var failures: [ProbeIncident] = []
    var result: ProbeResult?
}

private enum ProbeMode: String, Sendable { case execution, plan }

private enum ProbeBackend: String, CaseIterable, Identifiable, Sendable {
    case all, cpuAndNeuralEngine, cpuAndGPU

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "自动：CPU + GPU + ANE"
        case .cpuAndNeuralEngine: return "CPU + ANE"
        case .cpuAndGPU: return "CPU + GPU"
        }
    }
    var computeUnits: MLComputeUnits {
        switch self {
        case .all: return .all
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        case .cpuAndGPU: return .cpuAndGPU
        }
    }
}

private enum ProbeUpdate: Sendable {
    case metadata(ProbeModelInfo, String)
    case progress(ANEProgress)
    case runtime(String, Date)
    case inference(ProbeResult)
    case failed(ANEFailure, Bool)
    case completed(ProbeMode)
}

@MainActor
private final class ProbeSession: ObservableObject {
    @Published private(set) var status = "独立设备验证：先加载模型并执行短推理，可另行读取算子分配计划。"
    @Published private(set) var isRunning = false
    @Published private(set) var reportURL: URL?
    @Published private(set) var executionReportURL: URL?
    @Published private(set) var operationStartedAt: Date?
    @Published private(set) var stageStartedAt: Date?
    @Published private(set) var finishedAt: Date?
    @Published private(set) var executionStatus = "尚未运行"
    @Published private(set) var planStatus = "尚未诊断"
    @Published private(set) var recentEvents: [String] = []
    @Published private(set) var saveError: String?
    @Published private(set) var loadMilliseconds: Double?
    @Published private(set) var firstTokenMilliseconds: Double?
    @Published private(set) var decodeStepMilliseconds: [Double] = []
    private var evidence: ProbeEvidence?
    private var worker: Task<Void, Never>?
    private var currentMode = ProbeMode.execution
    private var currentBackend = ProbeBackend.all
    private var failuresAtStart = 0

    init() {
        let previous = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("latest-execution/ane-execution-evidence.json")
        if FileManager.default.fileExists(atPath: previous.path) {
            executionReportURL = previous
        }
    }

    func start(_ mode: ProbeMode, backend: ProbeBackend) {
        guard !isRunning else { return }
        let now = Date()
        currentMode = mode
        currentBackend = backend
        // Each operation owns its backend, plans, failures and file. The latest
        // execution file survives a later plan-only operation.
        evidence = ProbeEvidence(runID: UUID().uuidString, startedAt: now,
                device: machineIdentifier(),
                os: ProcessInfo.processInfo.operatingSystemVersionString,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                computeUnits: backend.rawValue,
                updatedAt: now, operationStartedAt: now,
                operation: mode.rawValue, phase: "prepare")
        recentEvents = []
        loadMilliseconds = nil
        firstTokenMilliseconds = nil
        decodeStepMilliseconds = []
        executionStatus = mode == .execution ? "准备加载和实际推理" : "本轮未执行；最近推理记录单独保留"
        planStatus = mode == .plan ? "正在独立诊断；此步骤不执行模型推理" : "本轮未诊断"
        evidence?.executionStatus = executionStatus
        evidence?.planStatus = planStatus
        operationStartedAt = now
        stageStartedAt = now
        finishedAt = nil
        isRunning = true
        evidence?.operation = mode.rawValue
        evidence?.operationStartedAt = now
        evidence?.operationFinishedAt = nil
        evidence?.phase = "prepare"
        evidence?.currentModel = nil
        failuresAtStart = evidence?.failures.count ?? 0
        if mode == .execution {
            executionStatus = "准备加载和实际推理"
            evidence?.executionStatus = executionStatus
        } else {
            planStatus = "正在独立诊断；此步骤不执行模型推理"
            evidence?.planStatus = planStatus
        }
        status = mode == .execution ? "读取模型资料……" : "准备独立读取计算计划……"
        persist()
        let (updates, continuation) = AsyncStream<ProbeUpdate>.makeStream()
        worker = Task.detached(priority: .userInitiated) {
            await performProbe(mode: mode, backend: backend, updates: continuation)
        }
        Task { [weak self] in
            for await update in updates {
                self?.accept(update)
            }
            guard let self else { return }
            self.finishedAt = Date()
            self.evidence?.operationFinishedAt = self.finishedAt
            self.isRunning = false
            self.worker = nil
            self.persist()
        }
    }

    func requestStop() {
        guard isRunning else { return }
        worker?.cancel()
        status = "已请求停止。正在执行的 Core ML 编译或加载无法中断；原生调用结束后停止。"
        record(ANEProgress(phase: evidence?.phase ?? "prepare",
            model: evidence?.currentModel, state: "message", detail: status))
    }

    private func accept(_ update: ProbeUpdate) {
        switch update {
        case .metadata(let info, let source):
            evidence?.fingerprint = info.fingerprint
            evidence?.sourceRevision = info.sourceRevision
            evidence?.modelNames = info.modelNames
            evidence?.compiledModelSource = source
            persist()
        case .progress(let event):
            record(event)
        case .runtime(let message, let timestamp):
            let fields = message.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if fields.count >= 3, fields[0] == "load",
               fields[1] == "start" || fields[1] == "complete" {
                let names = evidence?.modelNames ?? []
                let position = names.firstIndex(of: fields[2]).map { $0 + 1 }
                let duration = fields.count > 3 ? Double(fields[3]) ?? 0 : 0
                record(ANEProgress(phase: "load", model: fields[2],
                    index: position, total: names.count,
                    state: fields[1] == "start" ? "started" : "succeeded",
                    timestamp: timestamp, elapsedMilliseconds: duration, detail: message))
            } else if fields.count >= 4, fields[0] == "inference",
                      ["start", "complete", "failed"].contains(fields[1]) {
                let duration = fields.count > 4 ? Double(fields[4]) ?? 0 : 0
                let state = ["start": "started", "complete": "succeeded", "failed": "failed"][fields[1]]!
                record(ANEProgress(phase: "inference", model: fields[2],
                    tokenOffset: Int(fields[3]), state: state,
                    timestamp: timestamp, elapsedMilliseconds: duration, detail: message))
            } else {
                record(ANEProgress(phase: evidence?.phase ?? "load",
                    model: evidence?.currentModel, state: "message",
                    timestamp: timestamp, detail: message))
            }
        case .inference(let result):
            evidence?.result = result
            loadMilliseconds = result.loadMilliseconds
            firstTokenMilliseconds = result.firstTokenMilliseconds
            decodeStepMilliseconds = result.decodeStepMilliseconds
            persist()
        case .failed(let error, let cancelled):
            let phase = evidence?.phase ?? "prepare"
            let model = evidence?.currentModel
            let last = evidence?.failures.last
            if last?.error.domain != error.domain || last?.error.code != error.code
                || last?.phase != phase || last?.model != model {
                addFailure(error, phase: phase, model: model, cancelled: cancelled)
            }
            status = cancelled ? "已停止，可导出已完成阶段的记录。" :
                "\(stageLabel(phase))\(model.map { " · \($0)" } ?? "")失败：\(error.domain) (\(error.code))\n\(error.description)"
            if currentMode == .execution {
                executionStatus = cancelled ? "已停止，实际推理未完成" : "实际推理未完成"
                evidence?.executionStatus = executionStatus
            } else {
                planStatus = cancelled ? "计算计划诊断已停止" : "计算计划诊断失败；与实际推理状态独立"
                evidence?.planStatus = planStatus
            }
            persist()
        case .completed(let mode):
            if mode == .execution {
                executionStatus = "实际短推理已完成"
                evidence?.executionStatus = executionStatus
                status = "已在\(currentBackend.title)配置下完成短推理。所选配置允许系统分配计算，不代表每种硬件都参与执行。"
            } else {
                let failures = (evidence?.failures.count ?? 0) - failuresAtStart
                planStatus = failures == 0 ? "计算计划读取完成" : "计算计划读取结束，\(failures) 个模型失败"
                evidence?.planStatus = planStatus
                status = "计算计划诊断结束，计划和错误已保存。CPU 规划也是正常结果；计划不代表实际推理已成功。"
            }
            persist()
        }
    }

    private func record(_ incoming: ANEProgress) {
        var event = incoming
        if let plan = event.plan {
            evidence?.plans.removeAll { $0.chunk == plan.chunk }
            evidence?.plans.append(plan)
            event.plan = nil
        }
        if event.state == "started" {
            stageStartedAt = event.timestamp
            evidence?.phase = event.phase
            evidence?.currentModel = event.model
        }
        if let error = event.error {
            addFailure(error, phase: event.phase, model: event.model,
                cancelled: error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError)
        }
        evidence?.events.append(event)
        if event.phase == "initialize", event.state == "succeeded" {
            loadMilliseconds = event.elapsedMilliseconds
        } else if event.phase == "prefill", event.state == "succeeded" {
            firstTokenMilliseconds = event.elapsedMilliseconds
        } else if event.phase == "decode", event.state == "succeeded" {
            decodeStepMilliseconds.append(event.elapsedMilliseconds)
        }
        let model = event.model.map { " · \($0)" } ?? ""
        let position: String
        if let index = event.index, let total = event.total { position = " [\(index)/\(total)]" }
        else if let token = event.tokenOffset { position = " · token \(token)" }
        else { position = "" }
        let duration = event.elapsedMilliseconds > 0
            ? String(format: " · %.2f 秒", event.elapsedMilliseconds / 1000) : ""
        let state = ["started": "开始", "succeeded": "完成", "cached": "已缓存",
                     "failed": "失败", "message": "状态"][event.state] ?? event.state
        var line = "\(stageLabel(event.phase))\(model)\(position) · \(state)\(duration)"
        if event.phase == "plan", let detail = event.detail { line += "\n" + detail }
        recentEvents.append(line)
        if recentEvents.count > 10 { recentEvents.removeFirst(recentEvents.count - 10) }
        status = event.state == "message" ? event.detail ?? line : line
        // A completed load no longer attributes subsequent initializer failures to that model.
        if event.phase == "load", event.state == "succeeded" {
            evidence?.phase = "initialize"
            evidence?.currentModel = nil
            stageStartedAt = event.timestamp
        }
        persist()
    }

    private func addFailure(_ error: ANEFailure, phase: String, model: String?, cancelled: Bool) {
        evidence?.failures.append(ProbeIncident(timestamp: Date(), phase: phase, model: model,
            phaseElapsedMilliseconds: max(0, Date().timeIntervalSince(stageStartedAt ?? Date()) * 1000),
            cancelled: cancelled, error: error))
    }

    private func persist() {
        guard var snapshot = evidence else { return }
        let now = Date()
        snapshot.updatedAt = now
        snapshot.elapsedMilliseconds = max(0,
            (snapshot.operationFinishedAt ?? now).timeIntervalSince(snapshot.operationStartedAt) * 1000)
        evidence = snapshot
        do {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("latest-" + snapshot.operation)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = directory.appendingPathComponent("ane-\(snapshot.operation)-evidence.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: output, options: .atomic)
            reportURL = output
            if currentMode == .execution { executionReportURL = output }
            saveError = nil
        } catch {
            saveError = "设备记录保存失败：\(error.localizedDescription)"
        }
    }
}

@MainActor
struct ProbeView: View {
    @StateObject private var session = ProbeSession()
    @State private var backend = ProbeBackend.all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Qwen 0.8B · iPhone ANE").font(.title2)
                Picker("计算配置", selection: $backend) {
                    ForEach(ProbeBackend.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }.pickerStyle(.menu).disabled(session.isRunning)
                Text(session.status).textSelection(.enabled)
                if let started = session.operationStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        let end = session.finishedAt ?? timeline.date
                        let total = max(0, end.timeIntervalSince(started))
                        let phase = max(0, end.timeIntervalSince(session.stageStartedAt ?? started))
                        Text("本次总耗时 \(Int(total)) 秒 · 当前阶段 \(Int(phase)) 秒")
                            .font(.callout.monospacedDigit())
                    }
                }
                if session.isRunning {
                    ProgressView()
                    Text("长时间停留在加载或编译阶段时，原生 Core ML 调用仍在运行；界面和导出保持可用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("实际执行：\(session.executionStatus)")
                    Text("计划诊断：\(session.planStatus)")
                }.font(.callout)
                if let load = session.loadMilliseconds {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(format: "加载与初始化：%.2f 秒", load / 1000))
                        if let first = session.firstTokenMilliseconds {
                            Text(String(format: "首个输出（含提示词处理）：%.1f 毫秒", first))
                        } else {
                            Text("首个输出：尚未完成")
                        }
                        ForEach(Array(session.decodeStepMilliseconds.enumerated()), id: \.offset) { index, milliseconds in
                            Text(String(format: "后续第 %d 步：%.1f 毫秒", index + 1, milliseconds))
                        }
                    }.font(.callout.monospacedDigit())
                    Text("加载时间不等于打字延迟。首个输出和后续步骤才是本次短推理耗时；尚未验证输入法候选响应。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("加载模型并执行短推理") { session.start(.execution, backend: backend) }
                    .buttonStyle(.borderedProminent).disabled(session.isRunning)
                Button("单独诊断算子分配计划") { session.start(.plan, backend: backend) }
                    .buttonStyle(.bordered).disabled(session.isRunning)
                if session.isRunning {
                    Button("当前原生调用结束后停止", role: .destructive) { session.requestStop() }
                }
                if let report = session.reportURL {
                    ShareLink("导出本轮记录（失败也可导出）", item: report)
                }
                if let executionReport = session.executionReportURL,
                   executionReport != session.reportURL {
                    ShareLink("导出最近推理记录", item: executionReport)
                }
                if let error = session.saveError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                ForEach(Array(session.recentEvents.enumerated()), id: \.offset) { _, event in
                    Text(event).font(.caption.monospaced()).textSelection(.enabled)
                }
                Text("自动配置允许 CPU、GPU、ANE 参与调度，不代表三者同时计算；本工具不会自动切换配置。计划、实际推理和硬件轨迹是独立证据；本工具不验证键盘扩展。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
    }
}

private func stageLabel(_ phase: String) -> String {
    ["prepare": "准备资源", "compile": "编译模型", "load": "加载模型",
     "initialize": "初始化状态", "plan": "读取计算计划",
     "inference": "执行模型",
     "prefill": "执行提示词推理", "decode": "执行后续短推理"][phase] ?? phase
}

/// Runs outside MainActor. A single ordered stream carries progress and failures.
private func performProbe(
    mode: ProbeMode, backend: ProbeBackend, updates: AsyncStream<ProbeUpdate>.Continuation
) async {
    defer { updates.finish() }
    do {
        updates.yield(.progress(ANEProgress(phase: "prepare", state: "started")))
        guard let bundleRoot = Bundle.main.resourceURL else {
            throw ANEError.invalid("Missing application resource directory")
        }
        let directory = bundleRoot.appendingPathComponent("Qwen3.5-0.8B-IME-Q4")
        let info = try JSONDecoder().decode(ProbeModelInfo.self,
            from: Data(contentsOf: directory.appendingPathComponent("model-info.json")))
        let names = info.modelNames
        let precompiled = names.allSatisfy {
            FileManager.default.fileExists(atPath:
                bundleRoot.appendingPathComponent($0 + ".mlmodelc").path)
        }
        let compiled: URL
        if precompiled {
            compiled = bundleRoot
            updates.yield(.metadata(info, "bundle-precompiled-ios"))
            updates.yield(.progress(ANEProgress(phase: "prepare", state: "cached",
                detail: "全部模型已随 App 预编译，跳过手机编译。")))
        } else {
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ANE").appendingPathComponent(info.fingerprint)
            compiled = cache
            updates.yield(.metadata(info, "device-compiled-cache"))
            try await ANEPlan.prepare(packages: directory, cache: cache, modelNames: names) {
                updates.yield(.progress($0))
            }
        }
        try Task.checkCancellation()
        if mode == .plan {
            _ = try await ANEPlan.inspect(directory: compiled, modelNames: names,
                computeUnits: backend.computeUnits,
                continueOnFailure: true) { updates.yield(.progress($0)) }
            try Task.checkCancellation()
            updates.yield(.completed(.plan))
            return
        }

        guard let encoding = QwenANE.EmbeddingEncoding(rawValue: info.embeddingEncoding) else {
            throw ANEError.invalid("Unknown embedding format: \(info.embeddingEncoding)")
        }
        guard let fixtureURL = Bundle.main.url(forResource: "fixture", withExtension: "json") else {
            throw ANEError.invalid("Missing fixture.json")
        }
        let fixture = try JSONDecoder().decode(ProbeFixture.self, from: Data(contentsOf: fixtureURL))
        updates.yield(.progress(ANEProgress(phase: "initialize", state: "started")))
        let loadStart = ProcessInfo.processInfo.systemUptime
        let engine = try QwenANE(compiledDirectory: compiled,
            embeddingURL: directory.appendingPathComponent(info.embeddingFile),
            embeddingEncoding: encoding, headModels: info.headModels ?? [],
            bodyOutput: info.bodyOutput, headInput: info.headInput ?? "normed_hidden",
            computeUnits: backend.computeUnits,
            progress: { updates.yield(.runtime($0, Date())) })
        let loadMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
        updates.yield(.progress(ANEProgress(phase: "initialize", state: "succeeded",
            elapsedMilliseconds: loadMs)))
        try Task.checkCancellation()
        let log = OSLog(subsystem: "local.QwenANEProbe", category: .pointsOfInterest)
        var sequence = fixture.tokenIDs
        var footprint = physicalFootprint()
        updates.yield(.progress(ANEProgress(phase: "prefill", state: "started",
            detail: "\(sequence.count) prompt tokens")))
        os_signpost(.begin, log: log, name: "QwenANEFirstToken")
        let start = ProcessInfo.processInfo.systemUptime
        var logits: [Float]
        do {
            logits = try await engine.logits(for: sequence)
        } catch {
            os_signpost(.end, log: log, name: "QwenANEFirstToken")
            throw error
        }
        let firstTokenMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        os_signpost(.end, log: log, name: "QwenANEFirstToken")
        footprint = max(footprint, physicalFootprint())
        updates.yield(.progress(ANEProgress(phase: "prefill", state: "succeeded",
            elapsedMilliseconds: firstTokenMs)))
        var emitted: [Int32] = []
        var decodeSteps = 0
        var decodeStepMs: [Double] = []
        let decodeStart = ProcessInfo.processInfo.systemUptime
        // Four output tokens are sufficient to exercise state reuse; this is not a typing benchmark.
        for index in 0..<4 {
            try Task.checkCancellation()
            guard logits.count == QwenANE.vocabularySize, logits.allSatisfy({ $0.isFinite }),
                  let best = logits.indices.max(by: { logits[$0] < logits[$1] }) else {
                throw ANEError.invalid("Expected finite, complete vocabulary logits")
            }
            let token = Int32(best)
            emitted.append(token)
            if [248044, 248045, 248046].contains(token) || index == 3 { break }
            sequence.append(token)
            updates.yield(.progress(ANEProgress(phase: "decode", index: index + 1,
                total: 3, state: "started")))
            let stepStart = ProcessInfo.processInfo.systemUptime
            os_signpost(.begin, log: log, name: "QwenANEDecode")
            do {
                logits = try await engine.logits(for: sequence)
            } catch {
                os_signpost(.end, log: log, name: "QwenANEDecode")
                throw error
            }
            os_signpost(.end, log: log, name: "QwenANEDecode")
            decodeSteps += 1
            let stepMs = (ProcessInfo.processInfo.systemUptime - stepStart) * 1000
            decodeStepMs.append(stepMs)
            footprint = max(footprint, physicalFootprint())
            updates.yield(.progress(ANEProgress(phase: "decode", index: index + 1,
                total: 3, state: "succeeded",
                elapsedMilliseconds: stepMs)))
        }
        try Task.checkCancellation()
        updates.yield(.inference(ProbeResult(
            modelRevision: info.sourceRevision + "/" + info.fingerprint,
            computeUnits: backend.rawValue, promptTokens: fixture.tokenIDs.count,
            loadMilliseconds: loadMs, firstTokenMilliseconds: firstTokenMs, decodeSteps: decodeSteps,
            decodeMilliseconds: (ProcessInfo.processInfo.systemUptime - decodeStart) * 1000,
            decodeStepMilliseconds: decodeStepMs,
            outputTokenIDs: emitted,
            peakSampledPhysicalFootprintBytes: max(footprint, physicalFootprint()),
            thermalState: ProcessInfo.processInfo.thermalState.rawValue)))
        updates.yield(.completed(.execution))
    } catch {
        updates.yield(.failed(ANEFailure.capture(error), error is CancellationError || Task.isCancelled))
    }
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
        $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
            String(cString: $0)
        }
    }
}
