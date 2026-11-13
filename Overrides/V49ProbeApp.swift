import SwiftUI
import UIKit

@MainActor final class ProbeViewModel:ObservableObject {
    @Published var report:SuiteReport?
    @Published var running=false
    @Published var message="点击开始后才会加载模型并运行测量。"
    private var worker:ProbeWorker?
    private var task:Task<Void,Never>?
    let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
    var latestURL:URL {directory.appendingPathComponent("v49-latest.json")}
    func start() {
        guard !running else{return}
        running=true;UIApplication.shared.isIdleTimerDisabled=true;UIDevice.current.isBatteryMonitoringEnabled=true
        let device=["machine":deviceMachine(),"system":UIDevice.current.systemVersion,
                    "app":"V49Probe build1","process":String(ProcessInfo.processInfo.processIdentifier)]
        let active=ProbeWorker(directory:directory,device:device) {[weak self] value in
            await MainActor.run {self?.report=value;self?.message=value.phase}
        }
        worker=active
        task=Task {
            await active.run()
            running=false;worker=nil;UIApplication.shared.isIdleTimerDisabled=false
        }
    }
    func stop(){worker?.requestStop();task?.cancel()}
    func background(){if running{message="App 离开前台，正在停止并保存现有记录。";stop()}}
}
@main struct V49ProbeApp:App {
    @StateObject private var model=ProbeViewModel()
    @Environment(\.scenePhase) private var scenePhase
    var body:some Scene {
        WindowGroup {
            NavigationStack {
                ScrollView {
                    VStack(alignment:.leading,spacing:18) {
                        Text("V49 速度测试").font(.largeTitle.bold())
                        Text("最佳点 1408 · 两个 FP16 模型 · 约 2102 万参数")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(model.message).font(.headline)
                        HStack {
                            Button(model.running ? "测量中…":"开始完整测试"){model.start()}
                                .buttonStyle(.borderedProminent).disabled(model.running)
                            if model.running {Button("停止"){model.stop()}.buttonStyle(.bordered)}
                        }
                        if FileManager.default.fileExists(atPath:model.latestURL.path) {
                            ShareLink(item:model.latestURL){Label("导出记录",systemImage:"square.and.arrow.up")}
                        }
                        Text("CPU / CPU+GPU / CPU+ANE / 全部计算单元，顺序随机。每种配置记录首次加载与请求、300 次主模型推理、120 次完整解码、间歇唤醒、释放后重载及采样内存。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let report=model.report {
                            ForEach(report.results){result in
                                VStack(alignment:.leading,spacing:9) {
                                    HStack {Text(result.mode.title).font(.headline);Spacer();Text(result.status).font(.caption)}
                                    Text(result.phase).font(.caption).foregroundStyle(.secondary)
                                    if let value=result.preparationMS["total_prepare_ms"]{metric("资源和双模型准备",value)}
                                    if let value=result.firstBodyPredictionMS{metric("首次主模型推理",value)}
                                    if let value=result.firstCompleteRequest?.milliseconds{metric("首次完整请求",value)}
                                    if let s=result.bodySummary{Text("主模型 P50 / P95 / P99").font(.caption);Text(format(s)).monospacedDigit()}
                                    if let s=result.completeSummary{Text("完整解码 P50 / P95 / P99").font(.caption);Text(format(s)).monospacedDigit()}
                                    if let bytes=result.peakFootprintBytes{Text(String(format:"进程采样峰值 %.1f MiB",Double(bytes)/1048576)).font(.caption)}
                                    ForEach(Array(result.errors.enumerated()),id:\.offset){_,error in Text(error.message).font(.caption).foregroundStyle(.red)}
                                }.padding().frame(maxWidth:.infinity,alignment:.leading)
                                    .background(Color(.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:16))
                            }
                            ForEach(Array(report.errors.enumerated()),id:\.offset){_,error in Text(error.message).foregroundStyle(.red)}
                        }
                        Text("保持 App 在前台。应用层预测与结果缓存已关闭；系统缓存无法可靠清空，首次加载不代表真正无缓存冷启动。计算配置不证明实际 ANE 硬件执行。此版用于独立 App 测速，不测键盘界面延迟或打字准确率。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(20)
                }.background(Color(.systemGroupedBackground)).navigationTitle("澈 · V49")
                    .navigationBarTitleDisplayMode(.inline)
            }.onChange(of:scenePhase){_,phase in if phase == .background{model.background()}}
        }
    }
    private func metric(_ title:String,_ value:Double)->some View {
        HStack {Text(title);Spacer();Text(String(format:"%.2f ms",value)).monospacedDigit()}.font(.subheadline)
    }
    private func format(_ s:LatencySummary)->String {String(format:"%.2f / %.2f / %.2f ms",s.p50MS,s.p95MS,s.p99MS)}
}
