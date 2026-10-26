import SwiftUI
import UIKit

enum AppearanceItem: String, CaseIterable, Identifiable {
    case keyGlass, keyColor, candidateColor, candidateSize
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keyGlass: return "按键玻璃"
        case .keyColor: return "按键颜色"
        case .candidateColor: return "候选文字颜色"
        case .candidateSize: return "候选文字大小"
        }
    }
    var symbol: String {
        switch self {
        case .keyGlass: return "key.glass"
        case .keyColor: return "key.color"
        case .candidateColor: return "candidate.color"
        case .candidateSize: return "candidate.size"
        }
    }
    var colorPath: WritableKeyPath<KeyboardSettings, String?>? {
        switch self {
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
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: KeyboardAppearancePreview, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let natural = uiView.fittingSize(forWidth: width)
        return CGSize(width: width, height: min(proposal.height ?? natural.height, natural.height))
    }
}

struct AppearanceDetailContent: View {
    let item: AppearanceItem
    @Binding var settings: KeyboardSettings
    // The App owner observes Preferences. Pass its current value
    // as well as a write binding so a stable NavigationStack destination redraws.
    let value: KeyboardSettings
    var compact = false
    @Environment(\.colorScheme) private var scheme
    @State private var hexDraft: String?
    @State private var invalidHex = false
    @FocusState private var editingHex: Bool
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
        Binding(get: { value.resolvedKeyGlassStrength },
            set: {
                settings.keyGlassStrength = $0
            })
    }
    private var hexText: Binding<String> {
        Binding(get: { hexDraft ?? rgb.hex }, set: { text in
            // Ending editing can replay the just-committed field value. It is
            // no longer a draft, and must not re-enable Apply or survive as an
            // old draft when the observed settings next refresh.
            hexDraft = !editingHex && isCurrentExplicitColor(text) ? nil : text
            invalidHex = false
        })
    }
    private func isCurrentExplicitColor(_ text: String) -> Bool {
        guard let path = item.colorPath, let proposed = RGBColor(hex: text),
              let current = settings[keyPath: path].flatMap(RGBColor.init(hex:)) else { return false }
        return proposed == current
    }
    private var hasPendingHexChange: Bool {
        guard let draft = hexDraft else { return false }
        return !isCurrentExplicitColor(draft)
    }
    private var usesDefault: Bool {
        if let path = item.colorPath { return value[keyPath: path] == nil }
        if item == .keyGlass { return value.keyGlassStrength == nil }
        return value.candidateTextSize == nil && value.candidateAnimation == nil
    }
    private func setColor(_ value: RGBColor) {
        guard let path = item.colorPath else { return }
        settings[keyPath: path] = value.hex
        hexDraft = nil; invalidHex = false; editingHex = false
    }
    private func applyHex() {
        guard let draft = hexDraft else { return }
        guard let value = RGBColor(hex: draft) else { invalidHex = true; return }
        if isCurrentExplicitColor(draft) {
            hexDraft = nil; invalidHex = false; editingHex = false
            return
        }
        setColor(value)
    }
    private func reset() {
        if let path = item.colorPath { settings[keyPath: path] = nil }
        else if item == .keyGlass { settings.keyGlassStrength = nil }
        else { settings.candidateTextSize = nil; settings.candidateAnimation = nil }
        hexDraft = nil; invalidHex = false; editingHex = false
    }
    private func swatch(_ hex: String, side: CGFloat) -> some View {
        let value = RGBColor(hex: hex)!, selected = rgb.hex == hex
        let light = value.red * 0.2126 + value.green * 0.7152 + value.blue * 0.0722 > 0.62
        return Button { setColor(value) } label: {
            Circle().fill(Color(red: value.red, green: value.green, blue: value.blue))
                .overlay {
                    if selected { Image(systemName: "checkmark").font(.system(size: compact ? 11 : 14, weight: .bold)).foregroundStyle(light ? Color.black : Color.white) }
                }.padding(4)
                .overlay { Circle().strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: selected ? 2 : 1) }
                .frame(width: side, height: side)
        }.buttonStyle(.plain).accessibilityLabel(hex)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, minHeight: 30)
                .background(selected ? Color.accentColor.opacity(0.20) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var presets: some View {
        VStack(spacing: 6) {
            if item.colorPath != nil {
                ForEach(["#F2F3F8", "#292C39", "#7573F5", "#558DF2", "#D799BC", "#E3AC72"], id: \.self) { swatch($0, side: 28) }
            } else if item == .keyGlass {
                option("清透", selected: value.resolvedKeyGlassStrength > 0.8) { settings.keyGlassStrength = 0.9 }
                option("均衡", selected: abs(value.resolvedKeyGlassStrength - 0.55) < 0.01) { settings.keyGlassStrength = 0.55 }
                option("质感", selected: value.resolvedKeyGlassStrength < 0.2) { settings.keyGlassStrength = 0.15 }
            } else {
                ForEach(CandidateTextSize.allCases) { size in
                    option(size.title, selected: value.resolvedCandidateTextSize == size) { settings.candidateTextSize = size }
                }
            }
        }.frame(width: compact ? 44 : 50)
    }
    private var adjustments: some View {
        VStack(alignment: .leading, spacing: 12) {
            if item.colorPath != nil {
                ForEach(0..<3, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(["R", "G", "B"][index]).font(.caption.monospaced())
                        Slider(value: Binding(get: { [rgb.red, rgb.green, rgb.blue][index] }, set: { value in
                            var next = rgb
                            if index == 0 { next.red = value } else if index == 1 { next.green = value } else { next.blue = value }
                            setColor(next)
                        }), in: 0...1).accessibilityLabel("自定义颜色 " + ["R", "G", "B"][index])
                    }
                }
            } else if item == .keyGlass {
                GlassValueSlider(title: "通透", value: strength, range: 0...1, defaultValue: 0.55, identifier: "appearance.strength." + item.rawValue, percent: true)
            } else {
                Text("候选动画").font(.caption.weight(.medium))
                ForEach(CandidateAnimation.allCases) { animation in
                    option(animation.shortTitle, selected: value.resolvedCandidateAnimation == animation) { settings.candidateAnimation = animation }
                }
            }
        }.frame(width: compact ? 88 : 96)
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack(spacing: 10) {
                    presets
                    KeyboardPreview(settings: value).frame(maxWidth: .infinity).frame(height: compact ? 150 : 190)
                        .accessibilityLabel("键盘效果预览")
                        .accessibilityValue(KeyboardAppearancePreview.accessibilityDescription(of: value))
                        .accessibilityIdentifier("preview." + item.rawValue)
                    adjustments
                }.padding(compact ? 10 : 14).modifier(LiquidCard(radius: 20))
                if item.colorPath != nil, !compact {
                    VStack(spacing: 14) {
                        ColorPicker("自定义颜色", selection: color, supportsOpacity: false)
                            .accessibilityIdentifier("appearance.color." + item.rawValue)
                        HStack(spacing: 10) {
                            TextField("#RRGGBB", text: hexText).font(.system(size: 16, design: .monospaced))
                                .textInputAutocapitalization(.characters).autocorrectionDisabled().submitLabel(.done)
                                .keyboardType(.asciiCapable).focused($editingHex).onSubmit { applyHex() }
                                .padding(12).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityIdentifier("appearance.hex")
                            Button("应用") { applyHex() }.disabled(!hasPendingHexChange).accessibilityIdentifier("appearance.applyHex")
                        }
                        if invalidHex { Text("请输入 #RGB 或 #RRGGBB").font(.caption).foregroundStyle(.red) }
                    }.padding(16).modifier(LiquidCard(radius: 18))
                }
                Button { reset() } label: {
                    HStack {
                        ToolIcon(symbol: "arrow.counterclockwise").frame(width: 24, height: 24)
                        Text("恢复默认"); Spacer()
                        if usesDefault { Image(systemName: "checkmark") }
                    }.font(.system(size: 14, weight: .medium)).padding(14)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
                }.buttonStyle(.plain).accessibilityIdentifier("appearance.reset." + item.rawValue)
            }.padding(compact ? 10 : 16).padding(.bottom, 18)
        }.scrollDismissesKeyboard(.interactively)
    }
}
