import SwiftUI
import UIKit

@main struct ClearKeyboardApp: App {
    @StateObject private var preferences = Preferences()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(preferences).tint(Color(preferences.settings.accentInkColor)) }
    }
}

@MainActor final class Preferences: ObservableObject {
    private let store: SettingsStore
    @Published var settings: KeyboardSettings { didSet { settings.sanitize(); store.save(settings) } }
    init() {
        let activeStore = SettingsStore(defaults: SharedStorage.defaults(allowShared: true))
        store = activeStore; settings = activeStore.load()
    }
    func reload() {
        let saved = store.load()
        if saved != settings { settings = saved }
    }
    func clearLearning() {
        store.defaults.set(UUID().uuidString, forKey: "clear.learned.epoch")
        store.defaults.removeObject(forKey: "clear.learned.v1")
    }
    func clearClipboard() { ClipboardStore(url: SharedStorage.clipboardURL(allowShared: true)).clear() }
}

struct RootView: View {
    @EnvironmentObject private var preferences: Preferences
    var body: some View {
        TabView {
            NavigationStack { HomeView() }.tabItem { Label { Text("澈") } icon: { Image(uiImage: ClearBrand.image()).renderingMode(.template) } }
            NavigationStack { CustomizationView() }.tabItem { Label("定制", systemImage: "slider.horizontal.3") }
            NavigationStack { InputSettingsView() }.tabItem { Label("输入", systemImage: "keyboard") }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in preferences.reload() }
    }
}

struct HomeView: View {
    @EnvironmentObject private var preferences: Preferences
    @State private var showSetup = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("熟悉的布局，新的手感。").font(.system(size: 24, weight: .semibold)).tracking(-0.5)
                    Text("试试拼音，或切换到 English。").font(.system(size: 14)).foregroundStyle(.secondary)
                }.padding(.top, 8)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("输入体验").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Text("长按空格移动光标").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    TypingLab(settings: preferences.settings)
                        .frame(height: 380 + CGFloat(preferences.settings.keyHeight - 50) * 4)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.primary.opacity(0.07), lineWidth: 0.5))
                }
                Button { showSetup = true } label: {
                    HStack { Text("启用澈输入法").font(.system(size: 16, weight: .medium)); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 15, weight: .medium)) }
                        .padding(.horizontal, 19).frame(height: 54)
                        .foregroundStyle(Color(preferences.settings.onAccentColor))
                        .background(Color(preferences.settings.accentColor), in: RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain)
                HStack(spacing: 12) {
                    NavigationLink { CustomizationView() } label: { quickLink("外观与工具栏", symbol: "slider.horizontal.3") }
                    NavigationLink { InputSettingsView() } label: { quickLink("输入偏好", symbol: "keyboard") }
                }
            }.padding(.horizontal, 22).padding(.bottom, 28)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 12) {
                Image(uiImage: ClearBrand.image(34)).renderingMode(.template).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(LinearGradient(colors: [Color(preferences.settings.accentColor), Color(preferences.settings.accentColor).opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text("澈").font(.system(size: 21, weight: .semibold))
                    Text("CLEAR").font(.system(size: 9, weight: .medium, design: .rounded)).tracking(2.5).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 22).padding(.vertical, 12)
                .background(Color(uiColor: .systemBackground).opacity(0.97).ignoresSafeArea(edges: .top))
        }
        .background(Color(uiColor: .systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSetup) { SetupView() }
        .onAppear { preferences.reload() }
    }
    private func quickLink(_ title: String, symbol: String) -> some View {
        HStack(spacing: 7) { Image(systemName: symbol); Text(title).font(.system(size: 12, weight: .medium)) }
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .foregroundStyle(.primary).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("添加键盘") {
                    Label("打开 设置 → 通用 → 键盘 → 键盘", systemImage: "1.circle")
                    Label("添加新键盘 → 澈", systemImage: "2.circle")
                    Label("输入时，长按地球键切换到澈", systemImage: "3.circle")
                }
                Section("可选：完全访问") {
                    Text("开启后可同步本 App 的设置，并手动读取剪贴板、复制图片贴纸。不开启仍可离线打字，也能在键盘工具栏调节外观和单手模式。")
                    Button("打开系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                }
                Section { Text("密码框、部分电话号码框和禁用第三方键盘的 App 会使用系统键盘。回车行为由当前 App 决定。") }
            }.navigationTitle("让澈成为你的键盘").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
