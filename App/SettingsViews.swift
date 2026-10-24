import SwiftUI
import UIKit

struct CustomizationView: View {
    @EnvironmentObject private var preferences: Preferences
    @State private var showToolbarEditor = false
    var body: some View {
        AppPage(title: "定制") {
            AppSectionTitle(title: "按键与候选")
            AppCard {
                ForEach(Array(AppearanceItem.allCases.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    NavigationLink {
                        AppAppearanceDetail(item: item)
                            .background(AppPalette.canvas).navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
                    } label: {
                        AppRow(title: item.title, detail: item.colorPath == nil ? detail(item) : "", symbol: item.symbol,
                               color: item.colorPath.map { color(at: $0) })
                    }
                        .accessibilityIdentifier("custom.edit." + item.rawValue)
                }
            }.buttonStyle(.plain)
            AppSectionTitle(title: "布局与手感")
            AppCard {
                GlassValueSlider(title: "按键高度", value: $preferences.settings.keyHeight, range: 44...58, defaultValue: 50, identifier: "custom.keyHeight")
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    Text("单手模式").font(.system(size: 16, weight: .medium))
                    Picker("单手模式", selection: $preferences.settings.hand) {
                        ForEach(HandMode.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("custom.hand")
                    if preferences.settings.hand != .full {
                        GlassValueSlider(title: "键盘宽度", value: Binding(get: { preferences.settings.oneHandFraction }, set: { preferences.settings.oneHandWidth = $0 }), range: 0.68...0.88, defaultValue: 0.78, identifier: "custom.oneHandWidth", percent: true)
                    }
                }
            }
            AppSectionTitle(title: "触感")
            AppCard {
                PreferenceToggle(title: "按键震动", isOn: Binding(get: { preferences.settings.usesVibration }, set: { preferences.settings.vibrationEnabled = $0 }))
                    .accessibilityIdentifier("custom.vibration")
                if preferences.settings.usesVibration {
                    Divider()
                    GlassValueSlider(title: "震动力度", value: Binding(get: { preferences.settings.resolvedVibrationIntensity }, set: { preferences.settings.vibrationIntensity = $0; KeyboardVibration.shared.pulse(intensity: $0) }), range: 0...1, defaultValue: 0.45, identifier: "custom.vibrationIntensity", percent: true)
                }
            }
            AppCard {
                Button { showToolbarEditor = true } label: { AppRow(title: "快捷工具", detail: "排列与选择", symbol: "rectangle.3.group") }
                    .buttonStyle(.plain).accessibilityIdentifier("custom.toolbarEditor")
            }
        }.accessibilityIdentifier("custom.page").tint(AppPalette.accent)
            .sheet(isPresented: $showToolbarEditor) { ToolbarEditorView().tint(AppPalette.accent) }
            .onAppear { preferences.reload() }
    }
    private func color(at path: WritableKeyPath<KeyboardSettings, String?>) -> UIColor {
        if let hex = preferences.settings[keyPath: path], let rgb = RGBColor(hex: hex) {
            return UIColor(red: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
        }
        return path == \.candidateColorHex ? .label : .secondarySystemFill
    }
    private func detail(_ item: AppearanceItem) -> String {
        switch item {
        case .keyGlass: return "\(Int(preferences.settings.resolvedKeyGlassStrength * 100))%"
        case .candidateSize: return preferences.settings.resolvedCandidateTextSize.title
        default: return item.colorPath.flatMap { preferences.settings[keyPath: $0] } ?? "默认"
        }
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
                        Label { Text(item.title) } icon: { ToolIcon(symbol: item.symbol).frame(width: 28,height: 28) }
                            .deleteDisabled(item == .language)
                    }.onMove { preferences.settings.toolbar.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { offsets in
                            preferences.settings.toolbar.remove(atOffsets: IndexSet(offsets.filter { preferences.settings.toolbar[$0] != .language }))
                        }
                }
                Section("添加工具") {
                    ForEach(ToolbarTool.allCases.filter { !preferences.settings.toolbar.contains($0) }) { item in
                        Button { preferences.settings.toolbar.append(item) } label: { Label(item.title, systemImage: "plus.circle") }
                    }
                }
            }.scrollContentBackground(.hidden).background(AppPalette.canvas)
                .environment(\.editMode, .constant(.active)).navigationTitle("快捷工具").navigationBarTitleDisplayMode(.inline)
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

struct FuzzySettingsView: View {
    @EnvironmentObject private var preferences: Preferences
    var body: some View {
        AppPage(title: "模糊拼音") {
            AppSectionTitle(title: "发音组合")
            AppCard {
                ForEach(Array(FuzzyPinyin.availablePairs.enumerated()), id: \.element) { index, pair in
                    if index > 0 { Divider() }
                    PreferenceToggle(title: pair.replacingOccurrences(of: "/", with: " ↔ "), isOn: Binding(
                        get: { preferences.settings.fuzzyPairs.contains(pair) },
                        set: { if $0 { preferences.settings.fuzzyPairs.insert(pair) } else { preferences.settings.fuzzyPairs.remove(pair) } }))
                }
            }
            Text("只开启你需要的发音组合。普通拼音错按与漏按无需开启模糊拼音。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
        }.navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar).tint(AppPalette.accent)
    }
}

struct ClipboardSettingsView: View {
    @EnvironmentObject private var preferences: Preferences
    @State private var confirmClear = false
    @State private var accessMessage = ""
    var body: some View {
        AppPage(title: "剪贴板") {
            AppSectionTitle(title: "收录与保留")
            AppCard {
                PreferenceToggle(title: "自动收录复制内容", isOn: Binding(get: { preferences.settings.capturesClipboard }, set: { preferences.settings.automaticClipboard = $0 }))
                Divider()
                Picker("内容保留", selection: $preferences.settings.clipboardLifetimeHours) {
                    Text("15 分钟").tag(0.25); Text("1 小时").tag(1.0); Text("1 天").tag(24.0)
                    Text("7 天").tag(168.0); Text("30 天").tag(720.0); Text("永久").tag(0.0)
                }.font(.system(size: 16))
            }
            Text("App 或澈键盘打开时自动收录。常用语不会随保留时间过期。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            AppSectionTitle(title: "粘贴权限")
            AppCard {
                Button("检查粘贴访问") {
                    switch preferences.clipboardCapture.checkAccess() {
                    case .empty: accessMessage = "当前没有可检查的复制内容。请先在其他 App 复制文字、链接或图片，再回来检查。"
                    case .contentRead: accessMessage = "本次读取成功。若希望自动收录时不再询问，请在系统设置中选择「允许」。本次成功不代表已开启长期允许。"
                    case .unavailable: accessMessage = "本次未读取到可保存内容。若系统询问，请按你的意愿选择；也可在系统设置中检查粘贴权限。"
                    }
                }.buttonStyle(PrimaryAppButton()).accessibilityIdentifier("clipboard.checkAccess")
                if !accessMessage.isEmpty { Text(accessMessage).font(.caption).foregroundStyle(.secondary) }
                Button("打开系统设置") { preferences.openClipboardSettings() }.font(.system(size: 16))
                Divider()
                ClipboardSaveControl(capture: preferences.clipboardCapture).frame(height: 38)
                DisclosureGroup("系统粘贴权限说明") {
                    Text("权限由 iOS 管理。首次读取其他 App 的复制内容后，可到系统设置选择询问、拒绝或允许；自动收录需完全访问。")
                        .font(.caption).foregroundStyle(.secondary)
                }.font(.system(size: 14))
            }
            Button("清空剪贴板记录", role: .destructive) { confirmClear = true }
                .buttonStyle(PrimaryAppButton(bodyColor: .red))
            Text("支持文字、链接、图片和 8 MB 内附件。最多保留 200 条，附件总计 32 MB。图片与附件需复制后在输入框粘贴。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
        }.navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar).tint(AppPalette.accent)
            .confirmationDialog("清空复制记录？", isPresented: $confirmClear) {
                Button("清空", role: .destructive) { preferences.clearClipboard() }
            }
    }
}

struct InputAboutView: View {
    var body: some View {
        AppPage(title: "隐私与关于") {
            AppSectionTitle(title: "留在本机")
            AppCard {
                Label("无需账号，也无需联网输入", systemImage: "lock.shield").font(.system(size: 16, weight: .medium))
                Text("选词记忆保存你主动确认的词和对应拼音，可在输入设置中关闭或清除。剪贴板可单独关闭和清空。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            AppSectionTitle(title: "离线引擎")
            AppCard {
                Text("Rime · 万象拼音").font(.system(size: 16, weight: .medium))
                Text("中文词库与上下文语言模型支持整句、简拼和拼写纠错；中文模式中也可输入 English。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Divider()
                NavigationLink { LicenseView() } label: { AppRow(title: "开源许可", detail: "", symbol: "doc.text") }.buttonStyle(.plain)
            }
            AppSectionTitle(title: "使用手势")
            AppCard {
                Label("长按空格，滑动定位光标", systemImage: "cursorarrow.motionlines")
                Divider()
                Label("删除键上滑清空，下滑撤回", systemImage: "delete.left")
                Text("有拼音时，回车原样输入拼音，空格选择候选；没有拼音时，回车跟随当前 App 的发送、搜索或换行设置。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }.font(.system(size: 16))
        }.navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar).tint(AppPalette.accent)
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
        AppPage(title: "开源许可") { AppCard { Text(license).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) } }
            .navigationTitle("开源许可").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}
