import SwiftUI
#if canImport(V21NativeIME)
import V21NativeIME
#endif

/// Small opt-in control in the existing About page. Nothing starts on page appearance.
struct KernelMeasurementControls: View {
    @State private var sessionID: String?
    @State private var busy = false
    @State private var status = "未开始；实际显示延迟尚未测量"
    @State private var exported: URL?
    var body: some View {
        AppSectionTitle(title: "V22 本地测量")
        AppCard {
            Text(status).font(.caption).foregroundStyle(.secondary)
            Button("开始记录实际输入") {
                do { sessionID = try KernelMeasurement.shared.startCapture(); exported = nil; status = "已开始。可切到微信或备忘录使用澈；最多记录 200 次，不记录输入正文。" }
                catch { status = error.localizedDescription }
            }.disabled(sessionID != nil || busy)
            Button("开始 160 次 SDK 测量") {
                busy = true
                Task { @MainActor in
                    do {
                        sessionID = try KernelMeasurement.shared.startCapture()
                        exported = nil
                        try await V21InputService.shared.startMeasurement()
                        status = "已手动启动有限 SDK 测量。可以停止并导出；SDK 结果不代表屏幕显示时间。"
                    } catch { status = error.localizedDescription }
                    busy = false
                }
            }.disabled(busy)
            Button("停止") {
                Task { @MainActor in
                    do { try KernelMeasurement.shared.stopCapture(); await V21InputService.shared.stopMeasurement(); status = "已请求停止；正在执行的同步预测仍需返回。可立即导出。" }
                    catch { status = error.localizedDescription }
                }
            }.disabled(sessionID == nil)
            Button("导出记录") {
                guard let id = sessionID else { return }
                Task { @MainActor in
                    do {
                        let finite = try await V21InputService.shared.exportMeasurement()
                        exported = try await KernelMeasurement.shared.export(id: id, finiteSession: finite)
                        status = "记录已生成，请点下方分享。未收到的进程记录与屏幕可见时间保持未测。"
                    } catch { status = error.localizedDescription }
                }
            }.disabled(sessionID == nil)
            if let exported { ShareLink("分享记录", item: exported) }
            Text("键盘记录通过现有 App Group 共享。容器不可用时会标注缺少键盘记录。默认配置加载遇到执行计划 -14 时，仅同模型重试一次 CPU+GPU；导出会记录实际采用的配置。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
