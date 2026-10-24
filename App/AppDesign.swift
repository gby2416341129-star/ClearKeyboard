import SwiftUI
import UIKit

enum AppPalette {
    static let accent = Color(red: 0.43, green: 0.40, blue: 0.91)
    static let canvas = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.062, green: 0.063, blue: 0.082, alpha: 1) : UIColor(red: 0.960, green: 0.961, blue: 0.978, alpha: 1) })
    static let card = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.112, green: 0.114, blue: 0.145, alpha: 1) : .white })
    static let line = Color.primary.opacity(0.06)
}

struct AppPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 28)
        }.background {
            AppPalette.canvas.ignoresSafeArea()
                .overlay(alignment: .topTrailing) {
                    Ellipse().fill(AppPalette.accent.opacity(0.10)).frame(width: 320, height: 400)
                        .blur(radius: 90).offset(x: 130, y: -180).allowsHitTesting(false)
                }
        }
            .navigationTitle(title).navigationBarTitleDisplayMode(.large)
            .scrollDismissesKeyboard(.interactively)
    }
}

struct AppCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(LiquidCard(radius: 24))
    }
}

struct AppSectionTitle: View {
    let title: String
    var caption: String = ""
    var body: some View { Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary) }
}

struct PreferenceToggle: View {
    let title: String
    var subtitle: String = ""
    @Binding var isOn: Bool
    var body: some View {
        Toggle(title, isOn: $isOn).font(.system(size: 16)).tint(AppPalette.accent)
    }
}

struct AppRow: View {
    let title: String
    let detail: String
    let symbol: String
    var color: UIColor? = nil
    var body: some View {
        HStack(spacing: 13) {
            ToolIcon(symbol: symbol)
                .frame(width: 32, height: 34)
            Text(title).font(.system(size: 16)).foregroundStyle(.primary)
            Spacer(minLength: 6)
            if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
            if let color {
                RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: color)).frame(width: 28, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .accessibilityLabel("当前颜色")
            }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
        }.padding(.vertical, 4).contentShape(Rectangle())
    }
}

struct PrimaryAppButton: ButtonStyle {
    var bodyColor: Color = AppPalette.accent
    var ink: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .foregroundStyle(bodyColor).modifier(LiquidCard(radius: 18, interactive: true))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
