import SwiftUI
import UIKit

struct CustomizationView: View {
    @EnvironmentObject private var preferences: Preferences
    @State private var hexInput = ""
    @State private var invalidHex = false
    @State private var showToolbarEditor = false
    private var customColor: Binding<Color> {
        Binding(get: { Color(preferences.settings.accentColor) }, set: { value in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(value).getRed(&r, green: &g, blue: &b, alpha: &a)
            preferences.settings.customAccentHex = RGBColor(red: Double(r), green: Double(g), blue: Double(b)).hex
            hexInput = preferences.settings.customAccentHex ?? ""; invalidHex = false
        })
    }
    private func applyHex() {
        guard let color = RGBColor(hex: hexInput) else { invalidHex = true; return }
        preferences.settings.customAccentHex = color.hex; hexInput = color.hex; invalidHex = false
    }
    var body: some View {
        AppPage(title: "你的风格。", eyebrow: "PERSONALIZE / 定制", subtitle: "从一抹颜色，到指尖的每次触碰。") {
            MaterialStudy(settings: preferences.settings)
            AppCard {
                AppSectionTitle(title: "材质", caption: "MATERIAL")
                Picker("材质", selection: $preferences.settings.glass) {
                    ForEach(GlassPreset.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("custom.glass")
                HStack {
                    Text("遮罩浓度").font(.system(size: 13))
                    Spacer()
                    Text(preferences.settings.glassOpacity, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
                Slider(value: $preferences.settings.glassOpacity, in: 0.15...1).accessibilityIdentifier("custom.opacity")
            }
            AppCard {
                AppSectionTitle(title: "点缀色", caption: "COLOR")
                HStack(spacing: 12) {
                    ForEach(Accent.allCases) { accent in
                        accentSwatch(accent)
                    }
                }
                Divider()
                ColorPicker("自由选色", selection: customColor, supportsOpacity: false)
                    .font(.system(size: 14)).accessibilityIdentifier("custom.color")
                HStack(spacing: 10) {
                    Text("HEX").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("#RRGGBB", text: $hexInput).accessibilityIdentifier("custom.hex")
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .font(.system(size: 13, design: .monospaced)).multilineTextAlignment(.trailing)
                        .submitLabel(.done).onSubmit(applyHex)
                    Button("应用", action: applyHex).font(.system(size: 13, weight: .semibold)).accessibilityIdentifier("custom.applyHex")
                }
                if invalidHex { Text("请输入 #RRGGBB 或 #RGB 色值").font(.caption).foregroundStyle(.red) }
            }
            AppCard {
                AppSectionTitle(title: "按键与手感", caption: "TOUCH")
                HStack {
                    Text("按键高度").font(.system(size: 14))
                    Spacer()
                    Text(preferences.settings.keyHeight == 50 ? "标准" : String(format: "%+.0f", preferences.settings.keyHeight - 50))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    Button("还原") { preferences.settings.keyHeight = 50 }.font(.system(size: 12)).accessibilityIdentifier("custom.resetHeight")
                }
                Slider(value: $preferences.settings.keyHeight, in: 44...58, step: 1).accessibilityIdentifier("custom.keyHeight")
                Divider()
                Picker("键盘宽度", selection: $preferences.settings.hand) {
                    ForEach(HandMode.allCases) { Text($0.title).tag($0) }
                }.font(.system(size: 14)).accessibilityIdentifier("custom.hand")
                if preferences.settings.hand != .full {
                    Slider(value: Binding(get: { preferences.settings.oneHandFraction }, set: { preferences.settings.oneHandWidth = $0 }), in: 0.68...0.88)
                        .accessibilityLabel("单手宽度")
                }
                Divider()
                PreferenceToggle(title: "轻触反馈", subtitle: "每次按下，轻轻回应。", isOn: $preferences.settings.haptics).accessibilityIdentifier("custom.haptics")
            }
            AppCard {
                AppSectionTitle(title: "工具栏", caption: "SHORTCUTS")
                HStack {
                    ForEach(preferences.settings.toolbar) { tool in
                        VStack(spacing: 8) {
                            Image(uiImage: ToolArtwork.image(symbol: tool.symbol, size: 28)).renderingMode(.original).frame(width: 32, height: 32)
                            Text(tool.title).font(.system(size: 10)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }.padding(.vertical, 6)
                Divider()
                Button { showToolbarEditor = true } label: { AppRow(title: "排列快捷工具", detail: "把常用的放在顺手的位置", symbol: "rectangle.3.group") }.buttonStyle(.plain)
            }
        }.accessibilityIdentifier("custom.page")
            .sheet(isPresented: $showToolbarEditor) { ToolbarEditorView() }
            .onAppear { preferences.reload(); hexInput = preferences.settings.accentRGB.hex }
    }
    private func accentSwatch(_ accent: Accent) -> some View {
        var sample = KeyboardSettings(); sample.accent = accent
        let selected = preferences.settings.customAccentHex == nil && preferences.settings.accent == accent
        return Button {
            preferences.settings.accent = accent; preferences.settings.customAccentHex = nil
            hexInput = preferences.settings.accentRGB.hex; invalidHex = false
        } label: {
            VStack(spacing: 8) {
                Circle().fill(Color(sample.accentColor)).frame(width: 32, height: 32)
                    .overlay { if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) } }
                    .padding(4).overlay(Circle().stroke(selected ? Color(sample.accentColor).opacity(0.5) : .clear, lineWidth: 1))
                Text(accent.title).font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.plain).accessibilityIdentifier("custom.accent." + accent.rawValue).accessibilityLabel(accent.title)
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
        AppPage(title: "越用，越顺手。", eyebrow: "PREFERENCES / 输入", subtitle: "让输入方式贴近你的表达习惯。") {
            AppCard {
                HStack(spacing: 12) {
                    Image(systemName: "text.bubble").font(.system(size: 23)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("中文与 English").font(.system(size: 17, weight: .semibold))
                        Text("离线词库 · 拼音纠错 · 混合输入").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Picker("默认语言", selection: $preferences.settings.language) {
                    Text("中文拼音").tag(InputLanguage.chinese); Text("English").tag(InputLanguage.english)
                }.font(.system(size: 14))
            }
            AppCard {
                AppSectionTitle(title: "候选与记忆", caption: "SUGGESTIONS")
                PreferenceToggle(title: "记住我的选词", subtitle: "同样的拼音，优先显示你选过的词。", isOn: $preferences.settings.learnChoices)
                    .accessibilityIdentifier("input.learning")
                Divider()
                PreferenceToggle(title: "续词预测", subtitle: "接着上一句话，给出下一词建议。", isOn: $preferences.settings.predictions)
                Divider()
                PreferenceToggle(title: "英文自动大写", isOn: $preferences.settings.autoCapitalization)
            }
            AppCard {
                NavigationLink { FuzzySettingsView() } label: { AppRow(title: "模糊拼音", detail: preferences.settings.fuzzyPairs.isEmpty ? "按你的发音习惯设置" : "已开启 \(preferences.settings.fuzzyPairs.count) 组", symbol: "waveform") }
                Divider()
                NavigationLink { ClipboardSettingsView() } label: { AppRow(title: "剪贴板", detail: "自动收录与保留时间", symbol: "doc.on.clipboard") }
                Divider()
                NavigationLink { InputAboutView() } label: { AppRow(title: "隐私与关于", detail: "本机存储 · 离线词库 · 开源许可", symbol: "lock.shield") }
            }.buttonStyle(.plain)
            Button { confirmClear = true } label: {
                HStack { Text("重置选词记忆"); Spacer(); Image(systemName: "arrow.counterclockwise") }.font(.system(size: 13)).foregroundStyle(.secondary)
            }.padding(.horizontal, 4)
        }.accessibilityIdentifier("input.page")
            .confirmationDialog("清除已记住的选词？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清除选词记忆", role: .destructive) { preferences.clearLearning() }
            }
            .onAppear { preferences.reload() }
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
        }.navigationTitle("模糊拼音").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}

private struct ClipboardSettingsView: View {
    @EnvironmentObject private var preferences: Preferences
    @State private var confirmClear = false
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
                Button("打开系统设置") { preferences.openClipboardSettings() }
                ClipboardSaveControl(capture: preferences.clipboardCapture).frame(height: 38)
                Text("在系统设置的「澈 → 从其他 App 粘贴」选择「允许」，并开启键盘完全访问。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("清空剪贴板记录", role: .destructive) { confirmClear = true }
            } footer: { Text("支持文字、链接、图片和 8 MB 内附件。最多保留 200 条，附件总计 32 MB。图片与附件需复制后在输入框粘贴。") }
        }.navigationTitle("剪贴板").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .confirmationDialog("清空复制记录？", isPresented: $confirmClear) {
                Button("清空", role: .destructive) { preferences.clearClipboard() }
            }
    }
}

private struct InputAboutView: View {
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
                Text("回车跟随当前 App 的发送、搜索或换行设置。有拼音时先确认候选。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }.navigationTitle("隐私与关于").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
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
