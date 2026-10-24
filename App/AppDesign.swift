import SwiftUI
import UIKit

enum AppPalette {
    static let accent = Color(red: 0.0, green: 0.40, blue: 0.78)
    static let canvas = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1) : UIColor(red: 0.94, green: 0.96, blue: 0.98, alpha: 1) })
    static let card = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 1) : .white })
    static let line = Color.primary.opacity(0.06)
    static let secondaryInk = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.76,green: 0.78,blue: 0.84,alpha: 1)
        : UIColor(red: 0.35,green: 0.37,blue: 0.43,alpha: 1) })
}

struct AppPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 24)
        }.background(AppPalette.canvas.ignoresSafeArea())
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
    }
}

struct AppCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(LiquidCard(radius: 24))
    }
}

struct AppSectionTitle: View {
    let title: String
    var caption: String = ""
    var body: some View { Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(AppPalette.secondaryInk) }
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
        HStack(spacing: 12) {
            ToolIcon(symbol: symbol)
                .frame(width: 24, height: 24)
                .frame(width: 28, height: 30)
            Text(title).font(.system(size: 16)).foregroundStyle(.primary)
            Spacer(minLength: 6)
            if !detail.isEmpty { Text(detail).font(.system(size: 13)).foregroundStyle(AppPalette.secondaryInk).lineLimit(1) }
            if let color {
                RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: color)).frame(width: 28, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .accessibilityLabel("当前颜色")
            }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
        }.padding(.vertical, 7).contentShape(Rectangle())
    }
}

struct PrimaryAppButton: ButtonStyle {
    var bodyColor: Color = AppPalette.accent
    var ink: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .foregroundStyle(ink)
            .background(bodyColor.opacity(configuration.isPressed ? 0.82 : 1),in: RoundedRectangle(cornerRadius: 10))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
