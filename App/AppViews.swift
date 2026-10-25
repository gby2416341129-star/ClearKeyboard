import SwiftUI
import UIKit

@MainActor private final class AppearanceSaveLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save keyboard appearance") { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
    }
    func finish() {
        guard identifier != .invalid else { return }
        let value = identifier; identifier = .invalid
        UIApplication.shared.endBackgroundTask(value)
    }
}

@MainActor final class Preferences: ObservableObject {
    private var store: SettingsStore
    private let suppliedStore: SettingsStore?
    private let appearanceLink: AppearanceSettingsLink?
    private(set) var appearanceSyncStatus = AppearanceSettingsLink.Status.saved
    private(set) var appearanceSyncDiagnostics = AppearanceSyncDiagnostics()
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
            let clipboardChanged = clean.capturesClipboard != storedSettings.capturesClipboard ||
                clean.clipboardLifetimeHours != storedSettings.clipboardLifetimeHours
            let appearanceChanged = AppearanceSnapshot(settings: clean) != AppearanceSnapshot(settings: storedSettings)
            storedSettings = clean
            store.save(clean)
            if appearanceChanged { appearanceLink?.publish(clean) }
            if active && clipboardChanged { clipboardCapture.activate(settings: clean, allowed: true) }
        }
    }
    init(store: SettingsStore? = nil, clipboardCapture: ClipboardCapture? = nil, appearanceLink: AppearanceSettingsLink? = nil) {
        let activeStore = store ?? SettingsStore(defaults: SharedStorage.defaults(allowShared: true))
        suppliedStore = store
        self.store = activeStore; self.clipboardCapture = clipboardCapture ?? ClipboardCapture()
        self.appearanceLink = appearanceLink ?? (store == nil ? .production(role: .app) : nil)
        storedSettings = activeStore.load()
        self.appearanceLink?.currentSettings = { [weak self] in self?.settings ?? KeyboardSettings() }
        self.appearanceLink?.onReceive = { [weak self] snapshot in
            guard let self else { return }
            let value = snapshot.applying(to: self.storedSettings)
            if value != self.storedSettings {
                self.storedSettings = value
                self.store.save(snapshot.applying(to: self.store.load()))
            }
        }
        self.appearanceLink?.onStatus = { [weak self] status in
            if self?.appearanceSyncStatus != status { self?.appearanceSyncStatus = status }
        }
        self.appearanceLink?.onDiagnostics = { [weak self] diagnostics in
            if self?.appearanceSyncDiagnostics != diagnostics { self?.appearanceSyncDiagnostics = diagnostics }
        }
    }
    func reload() {
        if suppliedStore == nil { store = SettingsStore(defaults: SharedStorage.defaults(allowShared: true)) }
        let saved = store.load()
        // A reload is an observation, not an edit. Never echo a stale read back
        // into the shared domain while the other process is saving a new value.
        if saved != storedSettings { storedSettings = saved }
        if active { appearanceLink?.refresh() }
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
        appearanceLink?.activate()
        clipboardCapture.activate(settings: settings, allowed: true, retryPermission: retry)
    }
    func deactivate() {
        active = false
        // Protect only the final queued save. Each completion owns its own
        // short lease; a prior callback can never end a later save's lease.
        let lease = appearanceLink?.hasPendingWrite == true ? AppearanceSaveLease() : nil
        appearanceLink?.deactivate { lease?.finish() }
        clipboardCapture.stop()
    }
    func openClipboardSettings() {
        returningFromClipboardSettings = true
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

enum AppTab: String, CaseIterable {
    case home, custom, input
    var title: String { switch self { case .home: return "首页"; case .custom: return "定制"; case .input: return "输入" } }
    var symbol: String { switch self { case .home: return "house"; case .custom: return "slider.horizontal.3"; case .input: return "keyboard" } }
}

struct RootView: View {
    @EnvironmentObject private var preferences: Preferences
    @State private var tab: AppTab = .home
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { HomeView(selectedTab: $tab) }.tag(AppTab.home)
            NavigationStack { CustomizationView() }.tag(AppTab.custom)
            NavigationStack { InputSettingsView() }.tag(AppTab.input)
        }.toolbar(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(AppTab.allCases, id: \.self) { item in
                        Button { tab = item } label: {
                            VStack(spacing: 5) {
                                ToolIcon(symbol: item.symbol).frame(width: 28, height: 28)
                                Text(item.title).font(.system(size: 10, weight: tab == item ? .semibold : .medium))
                            }.foregroundStyle(tab == item ? AppPalette.accent : AppPalette.secondaryInk)
                                .frame(maxWidth: .infinity).frame(height: 58).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(item.title)
                            .accessibilityAddTraits(tab == item ? .isSelected : [])
                    }
                }.padding(.horizontal, 24).padding(.top, 3)
                    .background(AppPalette.canvas.ignoresSafeArea(edges: .bottom))
                    .overlay(alignment: .top) { Rectangle().fill(AppPalette.line).frame(height: 0.5) }
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
        AppPage(title: "澈键盘", subtitle: "让每一次表达，都顺手。", root: true) {
            HStack(spacing: 15) {
                Image(uiImage: ClearBrand.image(60)).renderingMode(.original).frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 6) {
                    Text("中文与 English").font(.system(size: 17, weight: .semibold))
                    Text("离线输入 · 自然表达").font(.system(size: 12)).foregroundStyle(AppPalette.secondaryInk)
                }
                Spacer(minLength: 4)
                Button { showSetup = true } label: {
                    HStack(spacing: 5) { ToolIcon(symbol: "setup").frame(width: 21, height: 21); Text("启用") }
                        .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 10)
                        .background(AppPalette.accent.opacity(0.12), in: Capsule())
                }.buttonStyle(.plain).foregroundStyle(AppPalette.accent).accessibilityIdentifier("home.setup")
            }.padding(.vertical, 18)
            HStack(spacing: 12) {
                shortcut(title: "外观与手感", detail: "调成喜欢的样子", symbol: "slider.horizontal.3", tab: .custom)
                shortcut(title: "输入偏好", detail: "选词、语言与预测", symbol: "keyboard", tab: .input)
                    .accessibilityIdentifier("home.inputPreferences")
            }
            AppSectionTitle(title: "更多")
            AppCard {
                NavigationLink { ClipboardSettingsView() } label: { AppRow(title: "剪贴板", detail: "复制记录", symbol: "doc.on.clipboard") }
                Divider().padding(.leading, 38)
                NavigationLink { InputAboutView() } label: { AppRow(title: "隐私与关于", detail: "本机存储", symbol: "lock.shield") }
            }.buttonStyle(.plain)
            HStack {
                Text("为专注输入而设计"); Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }.font(.system(size: 11)).foregroundStyle(AppPalette.secondaryInk).padding(.horizontal, 3).padding(.top, 6)
                .accessibilityElement(children: .combine).accessibilityIdentifier("home.footer")
        }.accessibilityIdentifier("home.page")
            .sheet(isPresented: $showSetup) { SetupView() }.onAppear { preferences.reload() }
    }
    private func shortcut(title: String, detail: String, symbol: String, tab: AppTab) -> some View {
        Button { selectedTab = tab } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack { ToolIcon(symbol: symbol).frame(width: 32, height: 32); Spacer(); ToolIcon(symbol: "arrow.up.right").frame(width: 18, height: 18) }
                Text(title).font(.system(size: 16, weight: .semibold)).padding(.top, 19)
                Text(detail).font(.system(size: 11)).foregroundStyle(AppPalette.secondaryInk).padding(.top, 6)
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.primary)
                .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }.buttonStyle(.plain)
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
