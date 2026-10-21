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
        store.defaults.removeObject(forKey: "clear.numbers.v1")
    }
    func clearClipboard() { ClipboardStore(url: SharedStorage.clipboardURL(allowShared: true)).clear() }
    func activate() {
        let retry = returningFromClipboardSettings
        returningFromClipboardSettings = false
        active = true
        clipboardCapture.activate(settings: settings, allowed: true, retryPermission: retry)
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
        TabView(selection: $tab) {
            NavigationStack { HomeView(selectedTab: $tab) }
                .tabItem { Label("澈", systemImage: "square.stack.3d.up") }.tag(AppTab.home)
            NavigationStack { CustomizationView() }
                .tabItem { Label("定制", systemImage: "slider.horizontal.3") }.tag(AppTab.custom)
            NavigationStack { InputSettingsView() }
                .tabItem { Label("输入", systemImage: "textformat.abc") }.tag(AppTab.input)
        }.tint(AppPalette.accent)
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
        AppPage(title: "澈") {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    Image(uiImage: ClearBrand.image(44)).renderingMode(.original).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("澈键盘").font(.system(size: 22, weight: .semibold))
                        Text("中文 · English").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "sparkle").font(.system(size: 23)).foregroundStyle(AppPalette.accent)
                }
                Button { showSetup = true } label: {
                    HStack { Image(systemName: "keyboard"); Text("启用键盘"); Spacer(); Image(systemName: "arrow.up.right") }.padding(.horizontal, 16)
                }.buttonStyle(PrimaryAppButton()).accessibilityIdentifier("home.setup")
            }.padding(22).background {
                RoundedRectangle(cornerRadius: 24).fill(AppPalette.card)
                    .overlay(RoundedRectangle(cornerRadius: 24).fill(LinearGradient(colors: [AppPalette.accent.opacity(0.12), Color.blue.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
            AppCard {
                Button { selectedTab = .custom } label: { AppRow(title: "外观与手感", detail: "按你的喜好", symbol: "slider.horizontal.3") }
                Divider()
                Button { selectedTab = .input } label: { AppRow(title: "输入偏好", detail: "选词与纠错", symbol: "textformat.abc") }
            }.buttonStyle(.plain)
            AppCard {
                NavigationLink { ClipboardSettingsView() } label: { AppRow(title: "剪贴板", detail: "复制记录", symbol: "doc.on.clipboard") }
                Divider()
                NavigationLink { InputAboutView() } label: { AppRow(title: "隐私与关于", detail: "本机存储", symbol: "lock.shield") }
            }.buttonStyle(.plain)
            HStack {
                Text("离线输入"); Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }.font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 4).accessibilityIdentifier("home.footer")
        }.accessibilityIdentifier("home.page")
            .sheet(isPresented: $showSetup) { SetupView() }
            .onAppear { preferences.reload() }
    }
}

struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            AppPage(title: "启用键盘") {
                AppCard {
                    setupStep("1", title: "打开键盘设置", detail: "通用 → 键盘 → 键盘")
                    Divider()
                    setupStep("2", title: "添加澈", detail: "添加新键盘 → 澈")
                    Divider()
                    setupStep("3", title: "切换键盘", detail: "输入时长按地球键，选择澈")
                }
                Button("打开系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    .buttonStyle(PrimaryAppButton())
                Text("完全访问用于同步设置与剪贴板，离线输入无需开启。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }.toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(AppPalette.accent)
    }
    private func setupStep(_ number: String, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Text(number).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppPalette.accent)
                .frame(width: 32, height: 32).background(AppPalette.accent.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}
