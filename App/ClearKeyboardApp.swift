import SwiftUI
import UIKit

@main struct ClearKeyboardApp: App {
    @StateObject private var preferences = Preferences()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(preferences).tint(Color(preferences.settings.accentInkColor))
        }
    }
}

@MainActor final class Preferences: ObservableObject {
    private let store: SettingsStore
    @Published var settings: KeyboardSettings { didSet { settings.sanitize(); store.save(settings) } }
    init() {
        let activeStore = SettingsStore(defaults: SharedStorage.defaults(allowShared: true))
        store = activeStore; settings = activeStore.load()
    }
    func clearLearning() {
        store.defaults.set(UUID().uuidString, forKey: "clear.learned.epoch")
        store.defaults.removeObject(forKey: "clear.learned.v1")
    }
    func clearClipboard() { ClipboardStore(url: SharedStorage.clipboardURL(allowShared: true)).clear() }
}

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }.tabItem { Label("澈", systemImage: "drop") }
            NavigationStack { CustomizationView() }.tabItem { Label("定制", systemImage: "slider.horizontal.3") }
            NavigationStack { InputSettingsView() }.tabItem { Label("输入", systemImage: "keyboard") }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var preferences: Preferences
    @State private var showSetup = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "drop.fill").font(.system(size: 22)).foregroundStyle(Color(preferences.settings.accentInkColor))
                        Text("澈").font(.system(size: 25, weight: .semibold))
                        Text("CLEAR").font(.system(size: 11, weight: .medium, design: .rounded)).tracking(3).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("离线 · 自在").font(.system(size: 11, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 7).background(.thinMaterial, in: Capsule())
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("把灵感，\n轻轻打出来。").font(.system(size: 35, weight: .semibold)).tracking(-1)
                    Text("熟悉的布局，清透的新手感。")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }.padding(.top, 8)
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("试着输入").font(.system(size: 13, weight: .medium)); Spacer(); Text("真实离线引擎").font(.system(size: 11)).foregroundStyle(.secondary) }
                    TypingLab(settings: preferences.settings)
                        .frame(height: 416 + CGFloat(preferences.settings.keyHeight - 50) * 4)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.primary.opacity(0.06), lineWidth: 0.5))
                }
                Button { showSetup = true } label: {
                    HStack { Text("启用澈输入法").fontWeight(.medium); Spacer(); Image(systemName: "arrow.up.right") }
                        .padding(18).foregroundStyle(Color(preferences.settings.onAccentColor)).background(Color(preferences.settings.accentColor), in: RoundedRectangle(cornerRadius: 18))
                }
                HStack(alignment: .top, spacing: 16) {
                    FeatureNote(symbol: "wifi.slash", title: "离线输入", subtitle: "内置中英文词库")
                    FeatureNote(symbol: "hand.draw", title: "顺手如常", subtitle: "沿用系统按键位置")
                    FeatureNote(symbol: "leaf", title: "克制运行", subtitle: "按需计算 · 无轮询")
                }
                Text("内置词库不联网。完全访问只用于设置同步、手动剪贴板和图片贴纸。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(22)
        }
        .background(LinearGradient(colors: [Color(preferences.settings.accentColor).opacity(0.08), Color(uiColor: .systemBackground)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSetup) { SetupView() }
    }
}

private struct FeatureNote: View {
    var symbol: String; var title: String; var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(.tint)
            Text(title).font(.system(size: 13, weight: .medium))
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
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
