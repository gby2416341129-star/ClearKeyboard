import SwiftUI
import UIKit

@MainActor final class Preferences: ObservableObject {
    private let store: SettingsStore
    let clipboardCapture: ClipboardCapture
    private var active = false
    private var returningFromClipboardSettings = false
    @Published private var storedSettings: KeyboardSettings
    var settings: KeyboardSettings {
        get { storedSettings }
        set {
            // Normalize a local value before publishing. Mutating an @Published value
            // from its own observer re-enters the wrapped setter during a UI binding write.
            var clean = newValue; clean.sanitize()
            guard clean != storedSettings else { return }
            storedSettings = clean
            store.save(clean)
            if active { clipboardCapture.activate(settings: clean, allowed: true) }
        }
    }
    init(store: SettingsStore? = nil, clipboardCapture: ClipboardCapture? = nil) {
        let activeStore = store ?? SettingsStore(defaults: SharedStorage.defaults(allowShared: true))
        self.store = activeStore; self.clipboardCapture = clipboardCapture ?? ClipboardCapture()
        storedSettings = activeStore.load()
    }
    func reload() {
        let saved = store.load()
        if saved != settings { settings = saved }
    }
    func clearLearning() {
        store.defaults.set(UUID().uuidString, forKey: "clear.learned.epoch")
        store.defaults.removeObject(forKey: "clear.learned.v1")
        store.defaults.removeObject(forKey: "clear.choices.v2")
    }
    func clearClipboard() { ClipboardStore(url: SharedStorage.clipboardURL(allowShared: true)).clear() }
    func activate() {
        active = true; clipboardCapture.activate(settings: settings, allowed: true)
        if returningFromClipboardSettings { returningFromClipboardSettings = false; clipboardCapture.retryAfterPermissionChange() }
    }
    func deactivate() { active = false; clipboardCapture.stop() }
    func openClipboardSettings() {
        returningFromClipboardSettings = true
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

enum AppTab: String, CaseIterable {
    case home, custom, input
    var title: String { switch self { case .home: return "澈"; case .custom: return "定制"; case .input: return "输入" } }
    var symbol: String { switch self { case .home: return "square.stack.3d.up"; case .custom: return "slider.horizontal.3"; case .input: return "textformat.abc" } }
}

struct RootView: View {
    @EnvironmentObject private var preferences: Preferences
    @State private var tab: AppTab = .home
    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .home: HomeView(selectedTab: $tab)
                case .custom: CustomizationView()
                case .input: InputSettingsView()
                }
            }
        }.id(tab)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(AppTab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        VStack(spacing: 5) {
                            Image(systemName: item.symbol).font(.system(size: 20, weight: tab == item ? .semibold : .regular))
                            Text(item.title).font(.system(size: 10, weight: .medium))
                        }.frame(maxWidth: .infinity).padding(.vertical, 11)
                            .foregroundStyle(tab == item ? Color(preferences.settings.accentInkColor) : Color.secondary)
                            .background(tab == item ? Color(preferences.settings.accentColor).opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain).accessibilityIdentifier("tab." + item.rawValue)
                        .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }.padding(6).background(AppPalette.card, in: RoundedRectangle(cornerRadius: 25))
                .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(AppPalette.line, lineWidth: 0.5))
                .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 4)
                .background(AppPalette.canvas)
        }
        .onAppear { preferences.activate() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in preferences.reload(); preferences.activate() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in preferences.deactivate() }
    }
}

struct HomeView: View {
    @EnvironmentObject private var preferences: Preferences
    @Binding var selectedTab: AppTab
    @State private var showSetup = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(uiImage: ClearBrand.image(36)).renderingMode(.original).frame(width: 36, height: 36)
                    Text("澈").font(.system(size: 21, weight: .semibold))
                    Spacer()
                    Text("CLEAR KEYBOARD").font(.system(size: 9, weight: .medium)).tracking(2).foregroundStyle(.secondary)
                }.padding(.top, 20)
                VStack(alignment: .leading, spacing: 16) {
                    Text("每一句，\n都顺手。").font(.system(size: 44, weight: .bold)).tracking(-1.5).lineSpacing(3)
                    Text("中文、English，自在切换。\n把喜欢的手感，留在每一次输入里。")
                        .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(6)
                }.padding(.top, 14)
                AppCard {
                    HStack {
                        Label("从这里开始", systemImage: "sparkle").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("01 / SET UP").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Text("让澈成为你的键盘").font(.system(size: 22, weight: .semibold)).tracking(-0.5)
                    Text("添加一次，之后在任何输入框切换使用。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Button { showSetup = true } label: {
                        HStack { Text("设置键盘"); Spacer(); Image(systemName: "arrow.up.right") }.padding(.horizontal, 18)
                    }.buttonStyle(PrimaryAppButton(bodyColor: Color(preferences.settings.accentColor)))
                        .accessibilityIdentifier("home.setup")
                }
                AppSectionTitle(title: "按你的习惯", caption: "MAKE IT YOURS")
                HStack(alignment: .top, spacing: 12) {
                    homeTile("外观与手感", detail: "材质 · 色彩 · 工具栏", symbol: "slider.horizontal.3", tab: .custom)
                    homeTile("输入偏好", detail: "选词 · 拼音 · 剪贴板", symbol: "textformat.abc", tab: .input)
                }
                NavigationLink { TypingPracticeView() } label: {
                    AppRow(title: "试打一段", detail: "在独立页面体验输入", symbol: "arrow.up.right.square")
                }.buttonStyle(.plain).padding(.horizontal, 4).accessibilityIdentifier("home.practice")
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield").font(.system(size: 10))
                    Text("离线输入，选词记忆留在本机。")
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 2)
            }.padding(.horizontal, 22).padding(.bottom, 28)
        }.background(AppPalette.canvas.ignoresSafeArea()).toolbar(.hidden, for: .navigationBar)
            .accessibilityIdentifier("home.page")
            .sheet(isPresented: $showSetup) { SetupView() }
            .onAppear { preferences.reload() }
    }
    private func homeTile(_ title: String, detail: String, symbol: String, tab: AppTab) -> some View {
        Button { selectedTab = tab } label: {
            VStack(alignment: .leading, spacing: 19) {
                Image(systemName: symbol).font(.system(size: 23, weight: .regular)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain)
    }
}

struct TypingPracticeView: View {
    @EnvironmentObject private var preferences: Preferences
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("试试拼音，也试试 English。").font(.system(size: 22, weight: .semibold))
            Text("长按空格移动光标，上滑删除键清空，下滑撤回。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TypingLab(settings: preferences.settings).clipShape(RoundedRectangle(cornerRadius: 22))
        }.padding(22).background(AppPalette.canvas).navigationTitle("试打")
            .navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}

struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("三步，开始输入。").font(.system(size: 30, weight: .bold)).padding(.top, 24)
                    AppCard {
                        setupStep("01", title: "打开系统键盘设置", detail: "设置 → 通用 → 键盘 → 键盘")
                        Divider()
                        setupStep("02", title: "添加澈", detail: "添加新键盘 → 澈")
                        Divider()
                        setupStep("03", title: "长按地球键", detail: "在输入框中切换到澈")
                    }
                    Button("打开系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                        .buttonStyle(PrimaryAppButton(bodyColor: .teal))
                    Text("同步 App 设置和自动收录剪贴板需要开启键盘的「允许完全访问」。普通离线输入无需开启。")
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5)
                }.padding(22)
            }.background(AppPalette.canvas).navigationTitle("启用澈").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
    private func setupStep(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number).font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(.teal).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
    }
}
