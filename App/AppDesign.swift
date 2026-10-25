import SwiftUI
import UIKit

enum AppPalette {
    static let accent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.48, green: 0.66, blue: 1, alpha: 1)
        : UIColor(red: 0.22, green: 0.36, blue: 0.88, alpha: 1) })
    static let canvas = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.043, green: 0.051, blue: 0.071, alpha: 1)
        : UIColor(red: 0.965, green: 0.973, blue: 0.988, alpha: 1) })
    static let card = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.075, green: 0.090, blue: 0.125, alpha: 1) : .white })
    static let line = Color.primary.opacity(0.065)
    static let secondaryInk = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.60, green: 0.65, blue: 0.75, alpha: 1)
        : UIColor(red: 0.43, green: 0.47, blue: 0.55, alpha: 1) })
}

struct AppPage<Content: View>: View {
    let title: String
    var subtitle: String = ""
    var root = false
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if root {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(title).font(.system(size: 30, weight: .bold)).tracking(-0.7)
                        if !subtitle.isEmpty { Text(subtitle).font(.system(size: 13)).foregroundStyle(AppPalette.secondaryInk) }
                    }.padding(.top, 10).padding(.bottom, 12)
                }
                content
            }.padding(.horizontal, 20).padding(.top, root ? 4 : 16).padding(.bottom, 28)
        }.background(AppPalette.canvas.ignoresSafeArea())
            .navigationTitle(root ? "" : title).navigationBarTitleDisplayMode(.inline)
            .toolbar(root ? .hidden : .visible, for: .navigationBar)
            .scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
    }
}

struct AppCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 16).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct AppSectionTitle: View {
    let title: String
    var caption: String = ""
    var body: some View {
        Text(title).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppPalette.secondaryInk).padding(.leading, 3).padding(.top, 8).padding(.bottom, -7)
    }
}

struct PreferenceToggle: View {
    let title: String
    var symbol: String? = nil
    var subtitle: String = ""
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                if let symbol { ToolIcon(symbol: symbol).frame(width: 24, height: 24) }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .medium))
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(AppPalette.secondaryInk) }
            }
        } }.tint(AppPalette.accent).frame(minHeight: 54)
    }
}

struct AppRow: View {
    let title: String
    let detail: String
    let symbol: String
    var color: UIColor? = nil
    var body: some View {
        HStack(spacing: 12) {
            ToolIcon(symbol: symbol).frame(width: 26, height: 26)
            Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(.primary)
            Spacer(minLength: 8)
            if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(AppPalette.secondaryInk).lineLimit(1) }
            if let color {
                RoundedRectangle(cornerRadius: 7).fill(Color(uiColor: color)).frame(width: 23, height: 23)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .accessibilityLabel("当前颜色")
            }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(AppPalette.secondaryInk.opacity(0.65))
        }.frame(minHeight: 56).contentShape(Rectangle())
    }
}

struct PrimaryAppButton: ButtonStyle {
    var bodyColor: Color = AppPalette.accent
    var ink: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity).frame(minHeight: 48)
            .foregroundStyle(ink)
            .background(bodyColor.opacity(configuration.isPressed ? 0.80 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}
