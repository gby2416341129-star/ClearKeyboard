import SwiftUI
import UIKit

enum AppearanceItem: String, CaseIterable, Identifiable {
    case backgroundGlass, keyGlass, backgroundColor, keyColor, candidateColor, candidateSize
    var id: String { rawValue }
    var title: String {
        switch self {
        case .backgroundGlass: return "背景玻璃"
        case .keyGlass: return "按键玻璃"
        case .backgroundColor: return "背景颜色"
        case .keyColor: return "按键颜色"
        case .candidateColor: return "候选文字颜色"
        case .candidateSize: return "候选文字大小"
        }
    }
    var symbol: String {
        switch self {
        case .backgroundGlass: return "square.on.square"
        case .keyGlass: return "keyboard"
        case .backgroundColor: return "rectangle.inset.filled"
        case .keyColor: return "square.fill"
        case .candidateColor: return "a.circle"
        case .candidateSize: return "textformat.size"
        }
    }
    var colorPath: WritableKeyPath<KeyboardSettings, String?>? {
        switch self {
        case .backgroundColor: return \.backgroundColorHex
        case .keyColor: return \.keyColorHex
        case .candidateColor: return \.candidateColorHex
        default: return nil
        }
    }
}

struct KeyboardPreview: UIViewRepresentable {
    let settings: KeyboardSettings
    func makeUIView(context: Context) -> KeyboardAppearancePreview { KeyboardAppearancePreview() }
    func updateUIView(_ view: KeyboardAppearancePreview, context: Context) { view.apply(settings) }
}

struct AppearanceDetailContent: View {
    let item: AppearanceItem
    @Binding var settings: KeyboardSettings
    // The owner observes Preferences/AppearanceBridge. Pass its current value
    // as well as a write binding so a stable NavigationStack destination redraws.
    let value: KeyboardSettings
    var compact = false
    @Environment(\.colorScheme) private var scheme
    @State private var hex = ""
    @State private var invalidHex = false
    private var rgb: RGBColor {
        let fallback = item == .candidateColor ? (scheme == .dark ? "#F4F4F8" : "#20212A")
            : item == .keyColor ? (scheme == .dark ? "#BFC4D6" : "#FFFFFF")
            : (scheme == .dark ? "#272A37" : "#ECEEF8")
        return RGBColor(hex: item.colorPath.flatMap { value[keyPath: $0] } ?? fallback)!
    }
    private var color: Binding<Color> {
        Binding(get: { Color(red: rgb.red, green: rgb.green, blue: rgb.blue) }, set: { value in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(value).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            setColor(RGBColor(red: Double(r), green: Double(g), blue: Double(b)))
        })
    }
    private var strength: Binding<Double> {
        Binding(get: { item == .backgroundGlass ? value.resolvedBackgroundGlassStrength : value.resolvedKeyGlassStrength },
            set: {
                if settings.glass == .solid { settings.glass = .clear }
                if item == .backgroundGlass { settings.backgroundGlassStrength = $0 } else { settings.keyGlassStrength = $0 }
            })
    }
    private func setColor(_ value: RGBColor) {
        guard let path = item.colorPath else { return }
        settings[keyPath: path] = value.hex; hex = value.hex; invalidHex = false
    }
    var body: some View {
        ScrollView {
            VStack(spacing: compact ? 14 : 24) {
                KeyboardPreview(settings: value).frame(height: compact ? 166 : 250)
                    .accessibilityLabel("键盘效果预览")
                    .accessibilityValue(KeyboardAppearancePreview.accessibilityDescription(of: value))
                    .accessibilityIdentifier("preview." + item.rawValue)
                VStack(alignment: .leading, spacing: 18) {
                    if item == .backgroundGlass || item == .keyGlass {
                        HStack { Text("强度"); Spacer(); Text(strength.wrappedValue, format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.secondary) }
                        Slider(value: strength, in: 0...1).accessibilityIdentifier("appearance.strength." + item.rawValue)
                    } else if item == .candidateSize {
                        Picker("候选词大小", selection: Binding(get: { value.resolvedCandidateTextSize }, set: { settings.candidateTextSize = $0 })) {
                            ForEach(CandidateTextSize.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("custom.candidateTextSize")
                    } else {
                        if !compact { ColorPicker("自定义颜色", selection: color, supportsOpacity: false).accessibilityIdentifier("appearance.color." + item.rawValue) }
                        HStack(spacing: 0) {
                            ForEach(["#F2F3F8", "#292C39", "#7573F5", "#558DF2", "#D799BC", "#E3AC72"], id: \.self) { value in
                                Button { setColor(RGBColor(hex: value)!) } label: {
                                    Circle().fill(Color(uiColor: KeyboardSettings.color(hex: value)!)).frame(width: compact ? 24 : 32, height: compact ? 24 : 32)
                                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                                }.buttonStyle(.plain).accessibilityLabel(value)
                                if value != "#E3AC72" { Spacer(minLength: 0) }
                            }
                        }
                        if compact {
                            ForEach(0..<3, id: \.self) { index in
                                HStack {
                                    Text(["R", "G", "B"][index]).font(.caption.monospaced()).frame(width: 14)
                                    Slider(value: Binding(get: { [rgb.red, rgb.green, rgb.blue][index] }, set: { value in
                                        var next = rgb
                                        if index == 0 { next.red = value } else if index == 1 { next.green = value } else { next.blue = value }
                                        setColor(next)
                                    }), in: 0...1).accessibilityLabel("自定义颜色 " + ["R", "G", "B"][index])
                                }
                            }
                        } else {
                            HStack {
                                Text("HEX").font(.caption).foregroundStyle(.secondary)
                                TextField("#RRGGBB", text: $hex).font(.system(.body, design: .monospaced)).multilineTextAlignment(.trailing)
                                    .textInputAutocapitalization(.characters).autocorrectionDisabled().submitLabel(.done)
                                    .accessibilityIdentifier("appearance.hex")
                                Button("应用") {
                                    if let value = RGBColor(hex: hex) { setColor(value) } else { invalidHex = true }
                                }.accessibilityIdentifier("appearance.applyHex")
                            }
                            if invalidHex { Text("请输入 #RGB 或 #RRGGBB").font(.caption).foregroundStyle(.red) }
                        }
                    }
                    Button("恢复默认") {
                        if let path = item.colorPath { settings[keyPath: path] = nil }
                        else if item == .backgroundGlass { settings.backgroundGlassStrength = nil }
                        else if item == .keyGlass { settings.keyGlassStrength = nil }
                        else { settings.candidateTextSize = nil }
                    }.font(.subheadline).accessibilityIdentifier("appearance.reset." + item.rawValue)
                }.padding(compact ? 14 : 20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }.padding(compact ? 12 : 20).padding(.bottom, 18)
        }.scrollDismissesKeyboard(.interactively)
            .onAppear { hex = rgb.hex }
            .onChange(of: value) { _ in if item.colorPath != nil { hex = rgb.hex } }
    }
}

struct KeyboardAppearancePanel: View {
    @ObservedObject var bridge: AppearanceBridge
    @State private var selected: AppearanceItem?
    var body: some View {
        Group {
            if let item = selected {
                VStack(spacing: 0) {
                    HStack {
                        Button { selected = nil } label: { Label("外观", systemImage: "chevron.left") }
                        Spacer(); Text(item.title).font(.subheadline.weight(.semibold)); Spacer()
                    }.font(.caption).padding(.horizontal, 12).padding(.vertical, 5)
                    AppearanceDetailContent(item: item, settings: bridge.binding, value: bridge.settings, compact: true)
                }
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(AppearanceItem.allCases) { item in
                            Button { selected = item } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: item.symbol).frame(width: 24)
                                    Text(item.title); Spacer(); Image(systemName: "chevron.right").font(.caption)
                                }.font(.subheadline).foregroundStyle(.primary).padding(13)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
                            }.buttonStyle(.plain)
                        }
                    }.padding(10)
                }
            }
        }.tint(Color(red: 0.40, green: 0.39, blue: 0.92))
    }
}

@MainActor final class AppearanceBridge: ObservableObject {
    @Published var settings: KeyboardSettings
    private let save: (KeyboardSettings) -> Void
    init(settings: KeyboardSettings, save: @escaping (KeyboardSettings) -> Void) { self.settings = settings; self.save = save }
    var binding: Binding<KeyboardSettings> { Binding(get: { self.settings }, set: { self.settings = $0; self.save($0) }) }
}
