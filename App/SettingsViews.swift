import SwiftUI
import UIKit

struct CustomizationView: View {
    @EnvironmentObject private var preferences: Preferences
    @State private var hexInput = ""
    @State private var invalidHex = false
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
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(uiImage: ClearBrand.image(30)).renderingMode(.template).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("你的清透，自有分寸。").font(.headline)
                        Text("外观改变，熟悉的按键位置不变。").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            }
            Section("玻璃材质") {
                Picker("材质", selection: $preferences.settings.glass) { ForEach(GlassPreset.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                VStack(alignment: .leading) {
                    HStack { Text("遮罩浓度"); Spacer(); Text(preferences.settings.glassOpacity, format: .percent.precision(.fractionLength(0))).foregroundStyle(.secondary) }
                    Slider(value: $preferences.settings.glassOpacity, in: 0.15...1)
                }
                ColorPicker("自定义任意颜色", selection: customColor, supportsOpacity: false)
                HStack {
                    Text("HEX")
                    TextField("#RRGGBB", text: $hexInput).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced)).multilineTextAlignment(.trailing).submitLabel(.done).onSubmit(applyHex)
                    Button("应用", action: applyHex)
                }
                if invalidHex { Text("请输入 #RRGGBB 或 #RGB 色值").font(.caption).foregroundStyle(.red) }
                HStack {
                    ForEach(Accent.allCases) { color in
                        Button(color.title) { preferences.settings.accent = color; preferences.settings.customAccentHex = nil; hexInput = preferences.settings.accentRGB.hex; invalidHex = false }
                            .frame(maxWidth: .infinity)
                    }
                }.buttonStyle(.borderless)
                Text("iOS 26 使用原生 Liquid Glass；iOS 18–25 使用系统材质。减少透明度和低电量模式会自动降低渲染开销。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("按键与单手") {
                VStack(alignment: .leading) {
                    HStack { Text("按键高度"); Spacer(); Text("\(Int(preferences.settings.keyHeight)) pt").foregroundStyle(.secondary) }
                    Slider(value: $preferences.settings.keyHeight, in: 44...58, step: 1)
                }
                Picker("键盘宽度", selection: $preferences.settings.hand) { ForEach(HandMode.allCases) { Text($0.title).tag($0) } }
                if preferences.settings.hand != .full {
                    VStack(alignment: .leading) {
                        Text("单手宽度").font(.subheadline)
                        Slider(value: Binding(get: { preferences.settings.oneHandFraction }, set: { preferences.settings.oneHandWidth = $0 }), in: 0.68...0.88)
                    }
                }
                Toggle("轻触反馈", isOn: $preferences.settings.haptics)
                Text("字母、数字、符号页均沿用 iOS 的位置关系。长按空格可拖动光标；长按删除连续删除；双击 Shift 锁定大写。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(preferences.settings.toolbar) { item in
                    HStack { Label(item.title, systemImage: item.symbol); Spacer(); Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary) }
                }
                .onMove { source, destination in preferences.settings.toolbar.move(fromOffsets: source, toOffset: destination) }
                .onDelete { offsets in
                    let deletable = offsets.filter { preferences.settings.toolbar[$0] != .language }
                    preferences.settings.toolbar.remove(atOffsets: IndexSet(deletable))
                }
                ForEach(ToolbarTool.allCases.filter { !preferences.settings.toolbar.contains($0) }) { item in
                    Button { preferences.settings.toolbar.append(item) } label: { Label("添加" + item.title, systemImage: "plus.circle") }
                        .disabled(preferences.settings.toolbar.filter { $0 != .language }.count >= 3)
                }
            } header: { Text("工具栏 · 拖动排序") } footer: { Text("最多放三个快捷工具；也可在键盘内长按工具栏调整。中 / EN 始终可在工具面板中切换。") }
        }
        .navigationTitle("定制").toolbar { EditButton() }
        .onAppear { preferences.reload(); hexInput = preferences.settings.accentRGB.hex }
    }
}

struct InputSettingsView: View {
    @EnvironmentObject private var preferences: Preferences
    var body: some View {
        Form {
            Section("离线输入") {
                Picker("默认语言", selection: $preferences.settings.language) { Text("中文拼音").tag(InputLanguage.chinese); Text("English").tag(InputLanguage.english) }
                Toggle("续词预测", isOn: $preferences.settings.predictions)
                Toggle("英文自动大写", isOn: $preferences.settings.autoCapitalization)
                Toggle("学习我的选词", isOn: $preferences.settings.learnChoices)
                Text("内置约 6.5 万中文词条、5 万英文词条。中文支持全拼、简拼及基础词句组合；英文支持前缀补全。选词学习仅在本机保存，最多 512 个词条。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("清除选词学习", role: .destructive) { preferences.clearLearning() }
            }
            Section("模糊拼音") {
                ForEach(FuzzyPinyin.availablePairs, id: \.self) { pair in
                    Toggle(pair.replacingOccurrences(of: "/", with: " ↔ "), isOn: Binding(
                        get: { preferences.settings.fuzzyPairs.contains(pair) },
                        set: { if $0 { preferences.settings.fuzzyPairs.insert(pair) } else { preferences.settings.fuzzyPairs.remove(pair) } }))
                }
            }
            Section("剪贴板") {
                Picker("未固定内容保留", selection: $preferences.settings.clipboardLifetimeHours) {
                    Text("15 分钟").tag(0.25); Text("1 小时").tag(1.0); Text("24 小时").tag(24.0)
                }
                Text("不自动读取系统剪贴板。最多保存 20 条、每条 2,000 字，最多固定 10 条。固定内容保留至你手动删除。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("清空剪贴板记录", role: .destructive) { preferences.clearClipboard() }
            }
            Section("回车与表情") {
                Label("回车跟随当前 App", systemImage: "return")
                Text("优先显示宿主声明的「发送」「搜索」「前往」或「换行」。有拼音时先确认候选；再次回车才向 App 发送回车字符。第三方键盘无法保证所有 App 都将它作为发送指令。")
                    .font(.caption).foregroundStyle(.secondary)
                Label("Emoji · 颜文字 · 文字贴纸", systemImage: "face.smiling")
            }
            Section("隐私") {
                Label("没有账号、广告或网络请求", systemImage: "lock.shield")
                Text("不记录原始按键或整段输入。可选的选词学习只记录已选词的次数。剪贴板由你主动保存，文件使用设备数据保护。")
                    .font(.caption).foregroundStyle(.secondary)
                NavigationLink("开源许可") { LicenseView() }
            }
        }.navigationTitle("输入").onAppear { preferences.reload() }
    }
}

private struct LicenseView: View {
    private var license: String {
        let names = ["THIRD_PARTY_NOTICES", "Apache-2.0", "CMUdict"]
        return names.compactMap { name in Bundle.main.url(forResource: name, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } }.joined(separator: "\n\n")
    }
    var body: some View { ScrollView { Text(license).font(.system(size: 12, design: .monospaced)).padding() }.navigationTitle("开源许可") }
}
