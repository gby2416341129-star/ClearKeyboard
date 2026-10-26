import CoreML
import Foundation
import OSLog
import SwiftUI
import Darwin

@main
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
}

struct ProbeResult: Codable, Sendable {
    let modelRevision: String
    let device: String
    let os: String
    let computeUnits: String
    let promptTokens: Int
    let firstTokenMilliseconds: Double
    let decodeSteps: Int
    let decodeMilliseconds: Double
    let outputTokenIDs: [Int32]
    let peakSampledPhysicalFootprintBytes: UInt64
    let thermalState: Int
    let plan: [ANEChunkPlan]
    let hardwareTraceCaptured: Bool
    let keyboardExtensionTested: Bool
}

struct ProbeView: View {
    @State private var status = "独立 ANE 验证；首次编译可能较久。"
    @State private var report: URL?
    @State private var running: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Qwen 0.8B · iPhone ANE").font(.title2)
            Text(status).textSelection(.enabled)
            Button("运行独立验证") {
                running = Task { await run() }
            }.disabled(running != nil)
            if let report { ShareLink("导出设备证据", item: report) }
        }.padding()
        .onDisappear { running?.cancel() }
    }

    @MainActor private func run() async {
        defer { running = nil }
        do {
            status = "准备本机编译缓存……"
            let directory = Bundle.main.resourceURL!.appendingPathComponent("Qwen3.5-0.8B-IME-Q4")
            let modelInfo = try JSONDecoder().decode(ProbeModelInfo.self,
                from: Data(contentsOf: directory.appendingPathComponent("model-info.json")))
            guard let encoding = QwenANE.EmbeddingEncoding(rawValue: modelInfo.embeddingEncoding) else {
                throw ANEError.invalid("Unknown embedding format")
            }
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ANE/" + modelInfo.fingerprint)
            let fixtureURL = Bundle.main.url(forResource: "fixture", withExtension: "json")!
            let fixture = try JSONDecoder().decode(ProbeFixture.self, from: Data(contentsOf: fixtureURL))
            let prepared = Task.detached(priority: .userInitiated) {
                try ANEPlan.compile(packages: directory, cache: cache)
            }
            try await withTaskCancellationHandler(operation: {
                try await prepared.value
            }, onCancel: { prepared.cancel() })
            try Task.checkCancellation()
            status = "读取当前 iPhone 的算子分配计划……"
            let plan = try await ANEPlan.inspect(directory: cache)
            status = "执行原始 logits 推理；不加重复惩罚……"
            let work = Task.detached(priority: .userInitiated) { () async throws -> ProbeResult in
                let log = OSLog(subsystem: "local.QwenANEProbe", category: .pointsOfInterest)
                let engine = try QwenANE(compiledDirectory: cache,
                    embeddingURL: directory.appendingPathComponent(modelInfo.embeddingFile),
                    embeddingEncoding: encoding)
                var sequence = fixture.tokenIDs
                var footprint = physicalFootprint()
                os_signpost(.begin, log: log, name: "QwenANEFirstToken")
                let start = ProcessInfo.processInfo.systemUptime
                var logits = try await engine.logits(for: sequence)
                let firstTokenMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
                os_signpost(.end, log: log, name: "QwenANEFirstToken")
                var emitted: [Int32] = []
                var decodeSteps = 0
                let decodeStart = ProcessInfo.processInfo.systemUptime
                os_signpost(.begin, log: log, name: "QwenANEDecode")
                for index in 0..<16 {
                    try Task.checkCancellation()
                    guard let best = logits.indices.max(by: { logits[$0] < logits[$1] }) else {
                        throw ANEError.invalid("Empty output")
                    }
                    let token = Int32(best)
                    emitted.append(token)
                    if [248044, 248045, 248046].contains(token) || index == 15 { break }
                    sequence.append(token)
                    logits = try await engine.logits(for: sequence)
                    decodeSteps += 1
                    footprint = max(footprint, physicalFootprint())
                }
                let decodeMs = (ProcessInfo.processInfo.systemUptime - decodeStart) * 1000
                os_signpost(.end, log: log, name: "QwenANEDecode")
                return ProbeResult(
                    modelRevision: modelInfo.sourceRevision + "/" + modelInfo.fingerprint,
                    device: machineIdentifier(), os: ProcessInfo.processInfo.operatingSystemVersionString,
                    computeUnits: "cpuAndNeuralEngine", promptTokens: fixture.tokenIDs.count,
                    firstTokenMilliseconds: firstTokenMs, decodeSteps: decodeSteps,
                    decodeMilliseconds: decodeMs, outputTokenIDs: emitted,
                    peakSampledPhysicalFootprintBytes: max(footprint, physicalFootprint()),
                    thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                    plan: plan, hardwareTraceCaptured: false, keyboardExtensionTested: false)
            }
            let result = try await withTaskCancellationHandler(operation: {
                try await work.value
            }, onCancel: { work.cancel() })
            let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ane-device-evidence.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: output, options: .atomic)
            report = output
            status = "四块模型已执行并生成设备记录。需结合 Instruments 的 Neural Engine 轨迹确认硬件执行；尚未验证键盘扩展。"
        } catch {
            status = "验证未完成：\(error.localizedDescription)"
        }
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
