import SwiftUI
import UIKit

enum AppPalette {
    static let accent = Color(red: 0.43, green: 0.40, blue: 0.91)
    static let canvas = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.062, green: 0.063, blue: 0.082, alpha: 1) : UIColor(red: 0.960, green: 0.961, blue: 0.978, alpha: 1) })
    static let card = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.112, green: 0.114, blue: 0.145, alpha: 1) : .white })
    static let line = Color.primary.opacity(0.06)
    static let secondaryInk = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.76,green: 0.78,blue: 0.84,alpha: 1)
        : UIColor(red: 0.35,green: 0.37,blue: 0.43,alpha: 1) })
}

enum AppMotion {
    static let control = Animation.easeOut(duration: 0.18)
    static let content = Animation.easeInOut(duration: 0.26)
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
                    Ellipse().fill(AppPalette.accent.opacity(0.14)).frame(width: 320, height: 500)
                        .blur(radius: 90).offset(x: 130, y: -180).allowsHitTesting(false)
                }
                .overlay(alignment: .bottomLeading) {
                    Ellipse().fill(Color(red: 0.24,green: 0.49,blue: 0.92).opacity(0.07))
                        .frame(width: 300,height: 480).blur(radius: 100)
                        .offset(x: -150,y: 120).allowsHitTesting(false)
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
    var body: some View { Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(AppPalette.secondaryInk) }
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
        HStack(spacing: 13) {
            ToolIcon(symbol: symbol)
                .frame(width: 28, height: 28)
                .frame(width: 32, height: 34)
            Text(title).font(.system(size: 16)).foregroundStyle(.primary)
            Spacer(minLength: 6)
            if !detail.isEmpty { Text(detail).font(.system(size: 13)).foregroundStyle(AppPalette.secondaryInk).lineLimit(1) }
            if let color {
                RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: color)).frame(width: 28, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .accessibilityLabel("当前颜色")
            }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, minHeight: 48).padding(.vertical, 4).contentShape(Rectangle())
    }
}

struct PrimaryAppButton: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var bodyColor: Color = AppPalette.accent
    var ink: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .foregroundStyle(bodyColor).modifier(LiquidCard(radius: 18, interactive: true))
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(configuration.isPressed ? 0.10 : 0)).allowsHitTesting(false))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(AppMotion.control, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, down in if down { AppFunctionalFeedback.pulse() } }
    }
}

@MainActor enum AppFunctionalFeedback {
    private static let generator = UIImpactFeedbackGenerator(style: .heavy)
    static func pulse() { generator.impactOccurred(intensity: 1); generator.prepare() }
}

struct AppRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(configuration.isPressed ? 0.09 : 0)))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(AppMotion.control, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, down in if down { AppFunctionalFeedback.pulse() } }
    }
}

/// All full pages use the navigation stack's forward/backward transition.
/// A chevron always pops that stack, including interactive swipe-back.
struct AppNavigationLink<Destination: View, Label: View>: View {
    @ViewBuilder var destination: Destination
    @ViewBuilder var label: Label
    var body: some View {
        NavigationLink { destination.navigationTransition(.automatic) } label: { label }
            .buttonStyle(AppRowButtonStyle())
    }
}
