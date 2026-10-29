import SwiftUI
import UIKit

@main
struct V10ProbeApp: App {
    var body: some Scene { WindowGroup { ProbeScreen() } }
}

@MainActor
final class ProbeViewModel: ObservableObject {
    @Published var report: SuiteReport?
    @Published var isRunning = false
    @Published var stopPending = false
    @Published var exportURL: URL?
    @Published var message: String?
    private var worker: ProbeWorker?
    private var task: Task<Void, Never>?
    private var previousBatteryMonitoring = false
    private var previousIdleDisabled = false
    let directory: URL
    init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("V10Evidence", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("v10-latest.json")
            if let data = try? Data(contentsOf: url) {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                report = try? decoder.decode(SuiteReport.self, from: data)
                if report?.status == "running" {
                    message = "上次运行未正常结束，已保留中断前记录，可直接导出。开始会建立新一轮。"
                }
            }
        } catch { message = error.localizedDescription }
    }
    func start() {
        guard !isRunning else { return }
        previousBatteryMonitoring = UIDevice.current.isBatteryMonitoringEnabled
        previousIdleDisabled = UIApplication.shared.isIdleTimerDisabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        UIApplication.shared.isIdleTimerDisabled = true
        isRunning = true; stopPending = false; message = nil; report = nil
        let device = [
            "machine": deviceMachine(), "systemVersion": UIDevice.current.systemVersion,
            "systemName": UIDevice.current.systemName,
            "physicalMemoryBytes": String(ProcessInfo.processInfo.physicalMemory),
            "processorCount": String(ProcessInfo.processInfo.processorCount),
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "executionEnvironment": "standalone foreground iPhone app; no keyboard extension",
            "hardwareUsageEvidence": "CoreML allowed configuration and compiler plan only"
        ]
        let operation = ProbeWorker(bundle: .main, device: device, outputDirectory: directory) { [weak self] update in
            await MainActor.run { self?.report = update }
        }
        worker = operation
        task = Task.detached(priority: .userInitiated) { [weak self] in
            await operation.run()
            await self?.finished()
        }
    }
    private func finished() {
        isRunning = false; stopPending = false; worker = nil; task = nil
        UIDevice.current.isBatteryMonitoringEnabled = previousBatteryMonitoring
        UIApplication.shared.isIdleTimerDisabled = previousIdleDisabled
    }
    func stop() {
        guard isRunning else { return }
        stopPending = true; worker?.requestStop()
        message = "已请求停止。当前 Core ML 系统调用返回后自动保存；界面仍可导出最近检查点。"
    }
    func export() {
        let latest = directory.appendingPathComponent("v10-latest.json")
        guard FileManager.default.fileExists(atPath: latest.path) else { message = "尚无记录，请先点开始。"; return }
        do {
            let name = "v10-suite-\(report?.suiteID ?? UUID().uuidString)-export.json"
            let url = directory.appendingPathComponent(name)
            // Copy the last atomically committed checkpoint, including failures or incomplete runs.
            try Data(contentsOf: latest).write(to: url, options: .atomic)
            exportURL = url
        } catch { message = "导出失败：\(error.localizedDescription)" }
    }
}

private struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}
struct ProbeScreen: View {
    @StateObject private var state = ProbeViewModel()
    @State private var shared: SharedFile?
    private let blue = Color(red: 0.10, green: 0.39, blue: 0.94)
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("澈 · V10 本地测试").font(.system(size: 29, weight: .bold))
                        Text("CPU / GPU / ANE").font(.headline).foregroundStyle(blue)
                        Text("一次开始，自动完成四种计算配置。记录每阶段耗时、延迟分位数、数值差异和完整错误。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button { state.start() } label: {
                            Label(state.isRunning ? "正在运行" : "开始完整测试", systemImage: "play.fill")
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }.buttonStyle(.borderedProminent).tint(blue).disabled(state.isRunning)
                        Button { state.export(); if let url = state.exportURL { shared = SharedFile(url: url) } } label: {
                            Label("导出记录", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }.buttonStyle(.bordered).disabled(state.report == nil)
                    }
                    if state.isRunning {
                        Button(role: .destructive) { state.stop() } label: {
                            Text(state.stopPending ? "等待当前系统调用返回…" : "停止并保存")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).disabled(state.stopPending)
                    }
                    if let message = state.message {
                        Text(message).font(.footnote).foregroundStyle(.orange)
                    }
                    if let report = state.report {
                        statusCard(report)
                        ForEach(report.results) { result in modeCard(result) }
                        if !report.inputParity.isEmpty {
                            let bad = report.inputParity.filter { $0.integerMismatches != 0 || $0.floatMismatchesAboveTolerance != 0 }.count
                            Text("Swift 编码与源输入：\(report.inputParity.count - bad) / \(report.inputParity.count) 个样例在记录容差内。")
                                .font(.footnote).foregroundStyle(bad == 0 ? Color.secondary : Color.orange)
                        }
                        if !report.errors.isEmpty {
                            ForEach(Array(report.errors.enumerated()), id: \.offset) { _, error in
                                Text("\(error.domain) / \(error.code)\n\(error.message)")
                                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(ProbeMode.allCases, id: \.rawValue) { mode in
                                Label(mode.title, systemImage: "cpu").font(.subheadline)
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("记录范围").font(.headline)
                        Text("• “纯模型”使用预先编码的固定输入。\n• “适配调用”加入文本编码与候选决策，不含候选搜索和屏幕刷新。\n• 首次加载不代表已清空系统缓存后的冷启动。\n• ANE 是苹果 NPU；计算配置和分配计划不等于实际硬件轨迹。\n• 内存是进程采样值；电量与温度状态不能换算成准确功耗。\n• 15 个参考样例只用于导出与接口对照，不代表真实打字准确率。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                    Text("独立测试 App · 不修改澈输入法 · 无 Qwen/Rime/万象模型 · 失败与中断也可导出")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(20)
            }.background(Color(uiColor: .systemGroupedBackground))
                .sheet(item: $shared) { item in ShareSheet(url: item.url) }
                .navigationBarTitleDisplayMode(.inline)
        }
    }
    private func statusCard(_ report: SuiteReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if state.isRunning { ProgressView() }
                Text(report.phase).font(.headline)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let end = report.finishedAt ?? context.date
                Text("本轮已用 \(Int(max(0, end.timeIntervalSince(report.startedAt)))) 秒 · \(report.results.filter { $0.status == "completed" || $0.status == "failed" }.count) / 4 项结束")
                    .font(.subheadline).monospacedDigit()
                if state.isRunning, let result = report.results.first(where: { $0.status == "running" }),
                   let start = result.phaseStartedAt {
                    Text("当前阶段 \(Int(max(0, context.date.timeIntervalSince(start)))) 秒；系统调用中不伪造进度或超时成功。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("配置顺序随机并已记录 · 严格模式，不自动切换硬件配置")
                .font(.caption).foregroundStyle(.secondary)
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
    private func modeCard(_ result: ModeResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(result.mode.title).font(.headline)
                Spacer()
                Text(statusLabel(result.status)).font(.caption.weight(.semibold))
                    .foregroundStyle(result.status == "failed" ? Color.red : result.status == "completed" ? Color.green : Color.secondary)
            }
            Text(result.phase).font(.caption).foregroundStyle(.secondary)
            HStack {
                metric("首次加载", result.firstModelLoadMS)
                metric("首次推理", result.firstPredictionMS)
                metric("再次加载", result.sameProcessReloadMS)
            }
            if let summary = result.warmSummary {
                summaryRow("纯模型 · \(summary.count) 次", summary)
            }
            if let summary = result.adapterSummary {
                summaryRow("适配调用 · \(summary.count) 次", summary)
            }
            if let summary = result.idleResumeSummary {
                Text("间歇调用：中位 \(format(summary.p50MS)) ms；最大 \(format(summary.maximumMS)) ms（仅 8 次）")
                    .font(.caption).monospacedDigit()
            }
            if let memory = result.sampledPeakFootprintBytes {
                Text(String(format: "进程采样峰值 %.1f MiB · %d 次采样", Double(memory) / 1_048_576, result.memorySamples))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !result.comparisons.isEmpty {
                let matching = result.comparisons.filter(\.finalDecisionMatchesSource).count
                let maxError = result.comparisons.map(\.maximumScoreError).max() ?? 0
                Text("源决策一致 \(matching) / \(result.comparisons.count)；最大排序分数偏差 \(String(format: "%.5f", maxError))")
                    .font(.caption).foregroundStyle(matching == result.comparisons.count ? Color.secondary : Color.orange)
            }
            if result.plan.status == "completed" {
                Text("编译器计划：CPU \(result.plan.plannedCPU) / GPU \(result.plan.plannedGPU) / ANE \(result.plan.plannedANE) 个非恒定算子")
                    .font(.caption).foregroundStyle(.secondary)
            } else if result.plan.status == "failed" {
                Text("分配计划读取失败；推理结果单独保留").font(.caption).foregroundStyle(.orange)
            }
            ForEach(Array(result.errors.enumerated()), id: \.offset) { _, error in
                Text("\(error.domain) / \(error.code)\n\(error.message)").font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
    private func summaryRow(_ label: String, _ summary: LatencySummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium))
            HStack { metric("P50", summary.p50MS); metric("P95", summary.p95MS); metric("P99", summary.p99MS) }
        }
    }
    private func metric(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value.map { format($0) + " ms" } ?? "—").font(.system(.subheadline, design: .monospaced).weight(.semibold))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func format(_ value: Double) -> String { String(format: value < 10 ? "%.3f" : "%.1f", value) }
    private func statusLabel(_ status: String) -> String {
        switch status {
        case "running": return "运行中"
        case "completed": return "执行完成"
        case "failed": return "失败已保存"
        case "cancelled": return "已停止"
        default: return "等待"
        }
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
