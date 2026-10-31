import SwiftUI
#if canImport(V21NativeIME)
import V21NativeIME
#endif

/// Small opt-in control in the existing About page. Nothing starts on page appearance.
struct KernelMeasurementControls: View {
    @State private var sessionID: String?
    @State private var recording = false
    @State private var busy = false
    @State private var status = "未开始；实际显示延迟尚未测量"
    @State private var exported: URL?
    var body: some View {
        AppSectionTitle(title: "V22 本地测量")
        AppCard {
            Text(status).font(.caption).foregroundStyle(.secondary)
            Button("开始记录实际输入") {
                busy=true
                Task { @MainActor in
                    do { sessionID = try await KernelMeasurement.shared.startCapture(); recording = true; exported = nil; status = "已开始实际输入记录。切到微信或备忘录使用澈，随后返回这里停止、导出；最多 200 次，不记录输入正文。" }
                    catch { status = error.localizedDescription }
                    busy=false
                }
            }.disabled(recording || busy)
            Button("开始 160 次 SDK 测量") {
                busy = true
                Task { @MainActor in
                    do {
                        sessionID = try await KernelMeasurement.shared.startCapture(); recording = true
                        exported = nil
                        try await V21InputService.shared.startMeasurement()
                        status = "已启动主 App 的 160 次 SDK 测量。若要测微信或备忘录的键盘，请改用“开始记录实际输入”。"
                    } catch { status = error.localizedDescription }
                    busy = false
                }
            }.disabled(busy)
            Button("停止") {
                Task { @MainActor in
                    do { try await KernelMeasurement.shared.stopCapture(); await V21InputService.shared.stopMeasurement(); recording = false; status = "已请求停止；正在执行的同步预测仍需返回。可立即导出。" }
                    catch { status = error.localizedDescription }
                }
            }.disabled(sessionID == nil)
            Button("导出记录") {
                guard let id = sessionID else { return }
                Task { @MainActor in
                    do {
                        let finite = try await V21InputService.shared.exportMeasurement()
                        exported = try await KernelMeasurement.shared.export(id: id, finiteSession: finite)
                        status = "记录已生成，请点下方分享。分别列出 App 与键盘扩展；实际绘制、提交、刷新有时间戳，物理屏幕呈现仍未测。"
                    } catch { status = error.localizedDescription }
                }
            }.disabled(sessionID == nil)
            if let exported { ShareLink("分享记录", item: exported) }
            Text("键盘记录优先通过 App Group 共享；容器不可用时使用签名授权的共享钥匙串。导出会核对键盘回执；两种权限均缺失时明确显示缺失原因。优先 CPU；加载遇到执行计划 -14 时，仅同模型重试一次 CPU+GPU。导出会记录实际采用的配置。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
