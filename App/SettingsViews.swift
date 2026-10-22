import SwiftUI
import UIKit

struct CustomizationView: View {
    @EnvironmentObject private var preferences: Preferences
    @State private var showToolbarEditor = false
    @State private var showSyncDetails = false
    var body: some View {
        AppPage(title: "定制") {
            AppSectionTitle(title: "玻璃与颜色")
            AppCard {
                ForEach(Array(AppearanceItem.allCases.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    NavigationLink {
                        AppAppearanceDetail(item: item)
                            .background(AppPalette.canvas).navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
                    } label: { AppRow(title: item.title, detail: detail(item), symbol: item.symbol) }
                        .accessibilityIdentifier("custom.edit." + item.rawValue)
                }
            }.buttonStyle(.plain)
            AppSectionTitle(title: "布局与手感")
            AppCard {
                HStack {
                    Text("材质").font(.system(size: 16)); Spacer()
                    Picker("材质", selection: $preferences.settings.glass) {
                        ForEach(GlassPreset.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("custom.glass")
                }
                Divider()
                HStack {
                    Text("按键高度").font(.system(size: 16)); Spacer()
                    Text(Int(preferences.settings.keyHeight).description).monospacedDigit().foregroundStyle(.secondary)
                    Button("还原") { preferences.settings.keyHeight = 50 }.font(.caption).accessibilityIdentifier("custom.resetHeight")
                }
                Slider(value: $preferences.settings.keyHeight, in: 44...58, step: 1).accessibilityIdentifier("custom.keyHeight")
                Divider()
                Picker("单手模式", selection: $preferences.settings.hand) {
                    ForEach(HandMode.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("custom.hand")
                if preferences.settings.hand != .full {
                    Slider(value: Binding(get: { preferences.settings.oneHandFraction }, set: { preferences.settings.oneHandWidth = $0 }), in: 0.68...0.88).accessibilityLabel("单手宽度")
                }
                Divider()
                PreferenceToggle(title: "轻触反馈", isOn: $preferences.settings.haptics).accessibilityIdentifier("custom.haptics")
            }
            AppCard {
                Button { showToolbarEditor = true } label: { AppRow(title: "快捷工具", detail: "排列与选择", symbol: "rectangle.3.group") }
                    .buttonStyle(.plain).accessibilityIdentifier("custom.toolbarEditor")
            }
            HStack(spacing: 12) {
                Text(preferences.appearanceSyncStatus.title).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { showSyncDetails = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("外观同步详情")
            }.padding(.horizontal, 4).accessibilityIdentifier("custom.footer")
        }.accessibilityIdentifier("custom.page").tint(AppPalette.accent)
            .sheet(isPresented: $showToolbarEditor) { ToolbarEditorView().tint(AppPalette.accent) }
            .sheet(isPresented: $showSyncDetails) { AppearanceSyncDetails().environmentObject(preferences) }
            .onAppear { preferences.reload() }
    }
    private func detail(_ item: AppearanceItem) -> String {
        switch item {
        case .backgroundGlass: return "\(Int(preferences.settings.resolvedBackgroundGlassStrength * 100))%"
        case .keyGlass: return "\(Int(preferences.settings.resolvedKeyGlassStrength * 100))%"
        case .candidateSize: return preferences.settings.resolvedCandidateTextSize.title
        default: return item.colorPath.flatMap { preferences.settings[keyPath: $0] } ?? "默认"
        }
    }
}

private struct AppearanceSyncDetails: View {
    @EnvironmentObject private var preferences: Preferences
    @Environment(\.dismiss) private var dismiss
    private var diagnostics: AppearanceSyncDiagnostics { preferences.appearanceSyncDiagnostics }
    private var diagnosticText: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(diagnostics)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    var body: some View {
        NavigationStack {
            AppPage(title: "外观同步") {
                AppCard {
                    Label(preferences.appearanceSyncStatus.title, systemImage:
                        preferences.appearanceSyncStatus == .receivedByKeyboard ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                    Divider()
                    LabeledContent("共享存储", value: diagnostics.backend.containerAvailable ? "可用" : "尚未连接")
                    if let receiver = diagnostics.expectedReceiver {
                        LabeledContent("键盘版本", value: receiver.version + " (" + receiver.build + ")")
                    }
                }
                Button {
                    UIPasteboard.general.string = diagnosticText
                } label: { Label("复制同步信息", systemImage: "doc.on.doc") }
                    .buttonStyle(PrimaryAppButton()).accessibilityIdentifier("appearance.copySyncDiagnostics")
                Text("同步信息不包含输入内容或剪贴板记录。")
                    .font(.caption).foregroundStyle(.secondary)
            }.toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(AppPalette.accent)
    }
}

struct AppAppearanceDetail: View {
    let item: AppearanceItem
    @EnvironmentObject private var preferences: Preferences
    var body: some View {
        AppearanceDetailContent(item: item, settings: $preferences.settings, value: preferences.settings)
    }
}

private struct ToolbarEditorView: View {
    @EnvironmentObject private var preferences: Preferences
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("按住右侧拖动排序") {
                    ForEach(preferences.settings.toolbar) { item in
                        Label { Text(item.title) } icon: { Image(uiImage: ToolArtwork.image(symbol: item.symbol, size: 26)).renderingMode(.original) }
                            .deleteDisabled(item == .language)
                    }.onMove { preferences.settings.toolbar.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { offsets in
                            preferences.settings.toolbar.remove(atOffsets: IndexSet(offsets.filter { preferences.settings.toolbar[$0] != .language }))
                        }
                }
                Section("添加工具") {
                    ForEach(ToolbarTool.allCases.filter { !preferences.settings.toolbar.contains($0) }) { item in
                        Button { preferences.settings.toolbar.append(item) } label: { Label(item.title, systemImage: "plus.circle") }
                            .disabled(preferences.settings.toolbar.count >= 4)
                    }
                }
            }.environment(\.editMode, .constant(.active)).navigationTitle("快捷工具").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct InputSettingsView: View {
    @EnvironmentObject private var preferences: Preferences
    @State private var confirmClear = false
    var body: some View {
        AppPage(title: "输入") {
            AppSectionTitle(title: "语言")
            AppCard {
                Picker("默认语言", selection: $preferences.settings.language) {
                    Text("中文拼音").tag(InputLanguage.chinese); Text("English").tag(InputLanguage.english)
                }.font(.system(size: 16))
                Divider()
                PreferenceToggle(title: "英文自动大写", isOn: $preferences.settings.autoCapitalization)
            }
            AppSectionTitle(title: "选词与预测")
            AppCard {
                PreferenceToggle(title: "记住我的选词", isOn: $preferences.settings.learnChoices).accessibilityIdentifier("input.learning")
                Divider()
                PreferenceToggle(title: "续词预测", isOn: $preferences.settings.predictions)
                Divider()
                NavigationLink { FuzzySettingsView() } label: { AppRow(title: "模糊拼音", detail: preferences.settings.fuzzyPairs.isEmpty ? "关闭" : "\(preferences.settings.fuzzyPairs.count) 组", symbol: "waveform") }
            }.buttonStyle(.plain)
            AppSectionTitle(title: "管理")
            AppCard {
                NavigationLink { ClipboardSettingsView() } label: { AppRow(title: "剪贴板", detail: "", symbol: "doc.on.clipboard") }
                Divider()
                NavigationLink { InputAboutView() } label: { AppRow(title: "隐私与关于", detail: "", symbol: "lock.shield") }
            }.buttonStyle(.plain)
            Button { confirmClear = true } label: {
                Label("重置选词记忆", systemImage: "arrow.counterclockwise").font(.subheadline)
            }.padding(.horizontal, 4).accessibilityIdentifier("input.resetLearning")
        }.accessibilityIdentifier("input.page")
            .confirmationDialog("清除已记住的选词？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清除选词记忆", role: .destructive) { preferences.clearLearning() }
            }.onAppear { preferences.reload() }
    }
}

private struct FuzzySettingsView: View {
    @EnvironmentObject private var preferences: Preferences
    var body: some View {
        List {
            Section {
                ForEach(FuzzyPinyin.availablePairs, id: \.self) { pair in
                    Toggle(pair.replacingOccurrences(of: "/", with: " ↔ "), isOn: Binding(
                        get: { preferences.settings.fuzzyPairs.contains(pair) },
                        set: { if $0 { preferences.settings.fuzzyPairs.insert(pair) } else { preferences.settings.fuzzyPairs.remove(pair) } }))
                }
            } footer: { Text("只开启你需要的发音组合。普通拼音错按与漏按无需开启模糊拼音。") }
        }.scrollContentBackground(.hidden).background(AppPalette.canvas).navigationTitle("模糊拼音").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}

struct ClipboardSettingsView: View {
    @EnvironmentObject private var preferences: Preferences
    @State private var confirmClear = false
    @State private var accessMessage = ""
    var body: some View {
        List {
            Section {
                Toggle("自动收录复制内容", isOn: Binding(get: { preferences.settings.capturesClipboard }, set: { preferences.settings.automaticClipboard = $0 }))
                Picker("内容保留", selection: $preferences.settings.clipboardLifetimeHours) {
                    Text("15 分钟").tag(0.25); Text("1 小时").tag(1.0); Text("1 天").tag(24.0)
                    Text("7 天").tag(168.0); Text("30 天").tag(720.0); Text("永久").tag(0.0)
                }
            } footer: { Text("App 或澈键盘打开时自动收录。常用语不会随保留时间过期。") }
            Section("粘贴权限") {
                Button("检查粘贴访问") {
                    switch preferences.clipboardCapture.checkAccess() {
                    case .empty: accessMessage = "当前没有可检查的复制内容。请先在其他 App 复制文字、链接或图片，再回来检查。"
                    case .contentRead: accessMessage = "本次读取成功。若希望自动收录时不再询问，请在系统设置中选择「允许」。本次成功不代表已开启长期允许。"
                    case .unavailable: accessMessage = "本次未读取到可保存内容。若系统询问，请按你的意愿选择；也可在系统设置中检查粘贴权限。"
                    }
                }.accessibilityIdentifier("clipboard.checkAccess")
                if !accessMessage.isEmpty { Text(accessMessage).font(.caption).foregroundStyle(.secondary) }
                Button("打开系统设置") { preferences.openClipboardSettings() }
                ClipboardSaveControl(capture: preferences.clipboardCapture).frame(height: 38)
                DisclosureGroup("系统粘贴权限说明") {
                    Text("权限由 iOS 管理。首次读取其他 App 的复制内容后，可到系统设置选择询问、拒绝或允许；自动收录需完全访问。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("清空剪贴板记录", role: .destructive) { confirmClear = true }
            } footer: { Text("支持文字、链接、图片和 8 MB 内附件。最多保留 200 条，附件总计 32 MB。图片与附件需复制后在输入框粘贴。") }
        }.scrollContentBackground(.hidden).background(AppPalette.canvas).navigationTitle("剪贴板").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .confirmationDialog("清空复制记录？", isPresented: $confirmClear) {
                Button("清空", role: .destructive) { preferences.clearClipboard() }
            }
    }
}

struct InputAboutView: View {
    var body: some View {
        List {
            Section("留在本机") {
                Label("无需账号，也无需联网输入", systemImage: "lock.shield")
                Text("选词记忆保存你主动确认的词和对应拼音，可在输入设置中关闭或清除。剪贴板可单独关闭和清空。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("离线引擎") {
                Text("Rime · 万象拼音")
                Text("中文词库与上下文语言模型支持整句、简拼和拼写纠错；中文模式中也可输入 English。")
                    .font(.subheadline).foregroundStyle(.secondary)
                NavigationLink("开源许可") { LicenseView() }
            }
            Section("使用手势") {
                Label("长按空格，滑动定位光标", systemImage: "cursorarrow.motionlines")
                Label("删除键上滑清空，下滑撤回", systemImage: "delete.left")
                Text("有拼音时，回车原样输入拼音，空格选择候选；没有拼音时，回车跟随当前 App 的发送、搜索或换行设置。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }.scrollContentBackground(.hidden).background(AppPalette.canvas).navigationTitle("隐私与关于").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}

private struct ClipboardSaveControl: UIViewRepresentable {
    let capture: ClipboardCapture
    func makeUIView(context: Context) -> ClipboardPasteButton { ClipboardPasteButton(capture: capture) }
    func updateUIView(_ uiView: ClipboardPasteButton, context: Context) {}
}

private struct LicenseView: View {
    private var license: String {
        ["THIRD_PARTY_NOTICES", "Rime-and-dependencies", "RimeXCFramework-license", "CC-BY-4.0", "Apache-2.0", "CMUdict"].compactMap { name in
            Bundle.main.url(forResource: name, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }.joined(separator: "\n\n")
    }
    var body: some View {
        ScrollView { Text(license).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(22) }
            .navigationTitle("开源许可").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}
