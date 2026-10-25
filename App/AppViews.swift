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
            let appearanceChanged = AppearanceSnapshot(settings: clean, includeInputPreferences: true) != AppearanceSnapshot(settings: storedSettings, includeInputPreferences: true)
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
                let clipboardChanged = value.capturesClipboard != self.storedSettings.capturesClipboard ||
                    value.clipboardLifetimeHours != self.storedSettings.clipboardLifetimeHours
                self.storedSettings = value
                self.store.save(snapshot.applying(to: self.store.load()))
                if self.active && clipboardChanged {
                    self.clipboardCapture.activate(settings: value, allowed: true)
                }
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
    var title: String { switch self { case .home: return "澈"; case .custom: return "定制"; case .input: return "输入" } }
    var symbol: String { switch self { case .home: return "house"; case .custom: return "slider.horizontal.3"; case .input: return "keyboard" } }
}

struct RootView: View {
    @EnvironmentObject private var preferences: Preferences
    @Environment(\.colorScheme) private var colorScheme
    @State private var tab: AppTab = .home
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { HomeView(selectedTab: $tab) }
                .tabItem { Label { Text("首页") } icon: { Image(uiImage: ToolArtwork.image(symbol: "house")).renderingMode(.original) } }.tag(AppTab.home)
            NavigationStack { CustomizationView() }
                .tabItem { Label { Text("定制") } icon: { Image(uiImage: ToolArtwork.image(symbol: "slider.horizontal.3",style: colorScheme == .dark ? .dark : .light)).renderingMode(.original) } }.tag(AppTab.custom)
            NavigationStack { InputSettingsView() }
                .tabItem { Label { Text("输入") } icon: { Image(uiImage: ToolArtwork.image(symbol: AppTab.input.symbol,style: colorScheme == .dark ? .dark : .light)).renderingMode(.original) } }.tag(AppTab.input)
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
                    HStack { ToolIcon(symbol: "setup").frame(width: 28, height: 28); Text("启用键盘"); Spacer(); ToolIcon(symbol: "arrow.up.right").frame(width: 24, height: 24) }.padding(.horizontal, 16)
                }.buttonStyle(PrimaryAppButton()).accessibilityIdentifier("home.setup")
            }.padding(22).modifier(LiquidCard(radius: 28))
            AppCard {
                Button { selectedTab = .custom } label: { AppRow(title: "外观与手感", detail: "按你的喜好", symbol: "slider.horizontal.3") }
                Divider()
                Button { selectedTab = .input } label: { AppRow(title: "输入偏好", detail: "选词与纠错", symbol: AppTab.input.symbol) }
                    .accessibilityIdentifier("home.inputPreferences")
            }.buttonStyle(.plain)
            AppCard {
                NavigationLink { ClipboardSettingsView() } label: { AppRow(title: "剪贴板", detail: "复制记录", symbol: "doc.on.clipboard") }
                Divider()
                NavigationLink { InputAboutView() } label: { AppRow(title: "隐私与关于", detail: "本机存储", symbol: "lock.shield") }
            }.buttonStyle(.plain)
            HStack {
                Text("离线输入"); Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }.font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 4)
                .accessibilityElement(children: .combine).accessibilityIdentifier("home.footer")
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
