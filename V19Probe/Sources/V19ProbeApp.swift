import SwiftUI
import UIKit

@main
struct V19ProbeApp: App {
    var body: some Scene { WindowGroup { ProbeScreen() } }
}
@MainActor
final class ProbeViewModel: ObservableObject {
    @Published var report: SuiteReport?
    @Published var isRunning=false
    @Published var stopPending=false
    @Published var exportURL: URL?
    @Published var message: String?
    private var worker: ProbeWorker?
    private var operation: Task<Void,Never>?
    private var previousBattery=false
    private var previousIdle=false
    let directory: URL
    init() {
        directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("V19Evidence",isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            if let data=try? Data(contentsOf:directory.appendingPathComponent("v19-latest.json")) {
                let decoder=JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                report=try? decoder.decode(SuiteReport.self,from:data)
                if report?.status=="running" { message="上次运行中断，已保留最后记录，可直接导出。点击开始会建立新一轮。" }
            }
        } catch { message=error.localizedDescription }
    }
    func start() {
        guard !isRunning else { return }
        previousBattery=UIDevice.current.isBatteryMonitoringEnabled
        previousIdle=UIApplication.shared.isIdleTimerDisabled
        UIDevice.current.isBatteryMonitoringEnabled=true; UIApplication.shared.isIdleTimerDisabled=true
        isRunning=true; stopPending=false; message=nil; report=nil
        let device=["machine":deviceMachine(),"systemVersion":UIDevice.current.systemVersion,
                    "physicalMemoryBytes":String(ProcessInfo.processInfo.physicalMemory),
                    "processorCount":String(ProcessInfo.processInfo.processorCount),
                    "appBuild":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown",
                    "executionEnvironment":"standalone foreground iPhone app, not keyboard extension"]
        let worker=ProbeWorker(bundle:.main,device:device,outputDirectory:directory) { [weak self] update in
            await MainActor.run { self?.report=update }
        }
        self.worker=worker
        operation=Task.detached(priority:.userInitiated) { [weak self] in
            await worker.run(); await self?.finished()
        }
    }
    private func finished() {
        isRunning=false; stopPending=false; worker=nil; operation=nil
        UIDevice.current.isBatteryMonitoringEnabled=previousBattery
        UIApplication.shared.isIdleTimerDisabled=previousIdle
    }
    func stop(background: Bool=false) {
        guard isRunning else { return }; stopPending=true; worker?.requestStop()
        message=background ? "进入后台，已请求停止以免后台状态影响测量。当前系统调用返回后保存记录。" : "已请求停止，当前系统调用返回后保存。已有记录可导出。"
    }
    func export() {
        guard let id=report?.suiteID else { return }
        do {
            let data=try Data(contentsOf:directory.appendingPathComponent("v19-latest.json"))
            let url=directory.appendingPathComponent("v19-suite-\(id)-export.json")
            try data.write(to:url,options:.atomic); exportURL=url
        } catch { message="导出失败：\(error.localizedDescription)" }
    }
}
private struct SharedFile: Identifiable { let url: URL; var id: String { url.path } }
struct ProbeScreen: View {
    @StateObject private var state=ProbeViewModel()
    @State private var shared: SharedFile?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    VStack(alignment:.leading,spacing:8) {
                        Text("澈 · V19 本地测试").font(.system(size:29,weight:.bold))
                        Text("CPU / GPU / NPU").font(.headline).foregroundStyle(.blue)
                        Text("V19 · step 38750 · 原生 Core ML + 拼音拆分解码")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("点一次开始，自动测完四种配置。保持App在前台，完成后导出记录。")
                            .font(.subheadline)
                    }
                    HStack(spacing:12) {
                        Button { state.start() } label: {
                            Label(state.isRunning ? "正在运行" : "开始完整测试",systemImage:"play.fill")
                                .frame(maxWidth:.infinity).padding(.vertical,8)
                        }.buttonStyle(.borderedProminent).disabled(state.isRunning)
                        Button { state.export(); if let url=state.exportURL { shared=SharedFile(url:url) } } label: {
                            Label("导出记录",systemImage:"square.and.arrow.up")
                                .frame(maxWidth:.infinity).padding(.vertical,8)
                        }.buttonStyle(.bordered).disabled(state.report==nil)
                    }
                    if state.isRunning {
                        Button(role:.destructive) { state.stop() } label: {
                            Text(state.stopPending ? "等待当前调用结束…" : "停止并保存").frame(maxWidth:.infinity)
                        }.buttonStyle(.bordered).disabled(state.stopPending)
                    }
                    if let text=state.message { Text(text).font(.footnote).foregroundStyle(.orange) }
                    if let report=state.report {
                        VStack(alignment:.leading,spacing:8) {
                            HStack { if state.isRunning { ProgressView() }; Text(report.phase).font(.headline) }
                            TimelineView(.periodic(from:.now,by:1)) { tick in
                                let seconds=Int(max(0,(report.finishedAt ?? tick.date).timeIntervalSince(report.startedAt)))
                                Text("已用 \(seconds) 秒 · \(report.results.filter { ["completed","failed","cancelled"].contains($0.status) }.count) / 4项结束")
                                    .font(.subheadline).monospacedDigit()
                                if state.isRunning,let current=report.results.first(where:{$0.status=="running"}),let start=current.phaseStartedAt {
                                    Text("当前阶段 \(Int(max(0,tick.date.timeIntervalSince(start)))) 秒。系统调用未返回时不会伪造进度。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text("配置顺序随机 · 出错仍保存 · 不自动换配置重试")
                                .font(.caption).foregroundStyle(.secondary)
                        }.card()
                        ForEach(report.results) { result in modeCard(result) }
                        ForEach(Array(report.errors.enumerated()),id:\.offset) { _,error in
                            Text("\(error.domain) / \(error.code)\n\(error.message)").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                    } else {
                        VStack(alignment:.leading,spacing:10) {
                            ForEach(ProbeMode.allCases,id:\.rawValue) { mode in Label(mode.title,systemImage:"cpu") }
                        }.font(.subheadline).card()
                    }
                    VStack(alignment:.leading,spacing:8) {
                        Text("测量范围").font(.headline)
                        Text("• 首次模型加载：单独记录Core ML加载耗时。\n• 首次完整请求：包括第一次推理、拆分和解码。\n• 单次模型：预编码输入，20次预热后测300次。\n• 完整内核：原始拼音到候选，共120次；可能包含1～8次模型调用。\n• 再次加载：主动释放后，在同一进程重新加载。\n• 不清理系统缓存，首次加载不等于真正无缓存冷启动。\n• 计算配置表示允许使用的硬件，不证明三者同时工作。\n• 内存为进程采样值，电量与温度不等于精确功耗。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.card()
                    Text("独立测试App · 不改澈输入法 · 不联网 · 失败和中断也可导出\n参考样例用于接口对照，不代表日常输入准确率；不包含键盘UI刷新耗时。")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(20)
            }.background(Color(uiColor:.systemGroupedBackground))
                .sheet(item:$shared) { item in ShareSheet(url:item.url) }
                .onReceive(NotificationCenter.default.publisher(for:UIApplication.didEnterBackgroundNotification)) { _ in state.stop(background:true) }
        }
    }
    private func modeCard(_ result: ModeResult) -> some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(result.mode.title).font(.headline); Spacer()
                Text(status(result.status)).font(.caption.weight(.semibold))
                    .foregroundStyle(result.status=="failed" ? Color.red : result.status=="completed" ? Color.green : Color.secondary)
            }
            Text(result.phase).font(.caption).foregroundStyle(.secondary)
            HStack {
                metric("首次模型加载",result.firstModelLoadMS)
                metric("首次单次推理",result.firstPredictionMS)
                metric("首次完整请求",result.firstCompleteRequestMS)
            }
            if let preparation=result.kernelPreparationMS {
                Text("内核初始化共 \(format(preparation)) ms；其中资源准备 \(format(result.resourcePreparationMS ?? 0)) ms")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let summary=result.warmSummary { summaryRow("单次模型 · \(summary.count)次",summary) }
            if let summary=result.completeSummary { summaryRow("完整输入内核 · \(summary.count)次",summary) }
            HStack {
                metric("再次模型加载",result.sameProcessModelReloadMS)
                metric("再次内核初始化",result.sameProcessKernelReloadMS)
                metric("重载后首次请求",result.firstCompleteRequestAfterReloadMS)
            }
            if let idle=result.idleResumeSummary {
                Text("间歇完整请求：中位 \(format(idle.p50MS)) ms，最大 \(format(idle.maximumMS)) ms（仅4次）")
                    .font(.caption)
            }
            if let bytes=result.sampledPeakFootprintBytes {
                Text(String(format:"进程采样峰值 %.1f MiB",Double(bytes)/1_048_576)).font(.caption).foregroundStyle(.secondary)
            }
            if !result.comparisons.isEmpty {
                let matches=result.comparisons.filter(\.top1MatchesReference).count
                let paths=result.comparisons.filter { $0.expectedPaths==$0.actualPaths }.count
                Text("源参考首选一致 \(matches)/\(result.comparisons.count)；切分路径数一致 \(paths)/\(result.comparisons.count)")
                    .font(.caption).foregroundStyle(matches==result.comparisons.count ? Color.secondary : Color.orange)
            }
            ForEach(Array(result.errors.enumerated()),id:\.offset) { _,error in
                Text("\(error.domain) / \(error.code)\n\(error.message)").font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }.card()
    }
    private func summaryRow(_ title: String,_ summary: LatencySummary) -> some View {
        VStack(alignment:.leading,spacing:5) {
            Text(title).font(.caption.weight(.medium))
            HStack { metric("P50",summary.p50MS); metric("P95",summary.p95MS); metric("P99",summary.p99MS) }
        }
    }
    private func metric(_ label: String,_ value: Double?) -> some View {
        VStack(alignment:.leading,spacing:3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value.map { format($0)+" ms" } ?? "—").font(.system(.subheadline,design:.monospaced).weight(.semibold))
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func format(_ value: Double) -> String { String(format:value<10 ? "%.3f" : "%.1f",value) }
    private func status(_ value: String) -> String {
        switch value {
        case "completed": return "完成"
        case "failed": return "失败已保存"
        case "cancelled": return "已停止"
        case "running","measured": return "运行中"
        default: return "等待"
        }
    }
}
private extension View {
    func card() -> some View {
        padding().frame(maxWidth:.infinity,alignment:.leading)
            .background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:16))
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context:Context) -> UIActivityViewController { UIActivityViewController(activityItems:[url],applicationActivities:nil) }
    func updateUIViewController(_ uiViewController:UIActivityViewController,context:Context) {}
}
