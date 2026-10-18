import SwiftUI
import UIKit

enum AppPalette {
    static let canvas = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.055, green: 0.067, blue: 0.082, alpha: 1) : UIColor(red: 0.955, green: 0.962, blue: 0.960, alpha: 1) })
    static let card = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.100, green: 0.118, blue: 0.137, alpha: 1) : .white })
    static let line = Color.primary.opacity(0.07)
}

struct AppPage<Content: View>: View {
    let title: String
    let eyebrow: String
    let subtitle: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(eyebrow).font(.system(size: 10, weight: .semibold)).tracking(2.4).foregroundStyle(.secondary)
                    Text(title).font(.system(size: 34, weight: .bold)).tracking(-1)
                    Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(4)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 20)
                content
            }.padding(.horizontal, 22).padding(.bottom, 26)
        }
        .background(AppPalette.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .scrollDismissesKeyboard(.interactively)
    }
}

struct AppCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) { content }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(AppPalette.line, lineWidth: 0.5))
    }
}

struct AppSectionTitle: View {
    let title: String
    var caption: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 16, weight: .semibold))
            Spacer()
            if !caption.isEmpty { Text(caption).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
}

struct PreferenceToggle: View {
    let title: String
    var subtitle: String = ""
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .medium))
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }.toggleStyle(.switch)
    }
}

struct AppRow: View {
    let title: String
    let detail: String
    let symbol: String
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 28).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(.primary)
                if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
        }.padding(.vertical, 2).contentShape(Rectangle())
    }
}

struct PrimaryAppButton: ButtonStyle {
    var bodyColor: Color
    var ink: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 17)
            .foregroundStyle(ink).background(bodyColor, in: RoundedRectangle(cornerRadius: 17))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// An abstract material sample, deliberately independent of the keyboard layout.
struct MaterialStudy: View {
    let settings: KeyboardSettings
    private var tint: Color { Color(settings.accentColor) }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20).fill(tint.opacity(0.13))
            Circle().fill(tint.opacity(0.75)).frame(width: 110, height: 110).blur(radius: 16).offset(x: -70, y: 24)
            Circle().fill(Color.blue.opacity(0.5)).frame(width: 85, height: 85).blur(radius: 18).offset(x: 80, y: -28)
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("CLEAR").font(.system(size: 10, weight: .semibold)).tracking(3).foregroundStyle(.secondary)
                    Text(settings.glass.title).font(.system(size: 28, weight: .medium)).tracking(-1)
                    Text(settings.accent.title + " / " + String(Int(settings.glassOpacity * 100)) + "%")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(tint.opacity(0.45)).frame(width: 70, height: 85).rotationEffect(.degrees(-16)).offset(x: -12, y: -5)
                    RoundedRectangle(cornerRadius: 18)
                        .fill(settings.glass == .solid ? AppPalette.card : Color.white.opacity(settings.glass == .mist ? 0.36 : 0.10 + settings.glassOpacity * 0.14))
                        .background(settings.glass == .solid ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.ultraThinMaterial), in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.45), lineWidth: 0.7))
                        .frame(width: 70, height: 85).rotationEffect(.degrees(12)).offset(x: 9, y: 8)
                }.frame(width: 100, height: 106)
            }.padding(24)
        }.frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 24)).accessibilityIdentifier("custom.materialPreview")
    }
}
