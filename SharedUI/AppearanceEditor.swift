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
    var body: some View {
        ScrollView {
            VStack(spacing: compact ? 14 : 24) {
                KeyboardPreview(settings: value).frame(maxWidth: .infinity)
                    .frame(height: compact ? 166 : nil)
                    .accessibilityLabel("键盘效果预览")
                    .accessibilityValue(KeyboardAppearancePreview.accessibilityDescription(of: value))
                    .accessibilityIdentifier("preview." + item.rawValue)
                VStack(alignment: .leading, spacing: 18) {
                    if item == .keyGlass {
                        GlassValueSlider(title: "通透强度", value: strength, range: 0...1, defaultValue: 0.55, identifier: "appearance.strength." + item.rawValue, percent: true)
                    } else if item == .candidateSize {
                        Picker("候选词大小", selection: Binding(get: { value.resolvedCandidateTextSize }, set: { settings.candidateTextSize = $0 })) {
                            ForEach(CandidateTextSize.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("custom.candidateTextSize")
                        Text("候选词动画").font(.subheadline.weight(.medium))
                        Picker("候选词动画", selection: Binding(get: { value.resolvedCandidateAnimation }, set: { settings.candidateAnimation = $0 })) {
                            ForEach(CandidateAnimation.allCases) { Text($0.shortTitle).tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("custom.candidateAnimation")
                        Text(value.resolvedCandidateAnimation.title).font(.caption).foregroundStyle(.secondary)
                    } else {
                        if !compact { ColorPicker("自定义颜色", selection: color, supportsOpacity: false).accessibilityIdentifier("appearance.color." + item.rawValue) }
                        GeometryReader { geometry in
                            let side = min(compact ? 36.0 : 44.0, max(0, geometry.size.width / 6))
                            HStack(spacing: 0) {
                                ForEach(["#F2F3F8", "#292C39", "#7573F5", "#558DF2", "#D799BC", "#E3AC72"], id: \.self) { value in
                                    swatch(value, side: side)
                                    if value != "#E3AC72" { Spacer(minLength: 0) }
                                }
                            }
                        }.frame(height: compact ? 36 : 44)
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
                            HStack(spacing: 10) {
                                TextField("#RRGGBB", text: hexText).font(.system(size: 17, weight: .medium, design: .monospaced))
                                    .textInputAutocapitalization(.characters).autocorrectionDisabled().submitLabel(.done)
                                    .keyboardType(.asciiCapable).focused($editingHex).onSubmit { applyHex() }
                                    .padding(.horizontal, 14).frame(minHeight: 48)
                                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
                                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(invalidHex ? Color.red : editingHex ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.14), lineWidth: 1))
                                    .accessibilityLabel("HEX 颜色")
                                    .accessibilityIdentifier("appearance.hex")
                                Button { applyHex() } label: {
                                    Text("应用").font(.system(size: 15, weight: .semibold))
                                        .frame(width: 72, height: 48)
                                        .foregroundStyle(hasPendingHexChange ? Color.white : Color.secondary)
                                        .background(hasPendingHexChange ? Color.accentColor : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
                                }.buttonStyle(.plain).disabled(!hasPendingHexChange).accessibilityIdentifier("appearance.applyHex")
                            }
                            if invalidHex { Text("请输入 #RGB 或 #RRGGBB").font(.caption).foregroundStyle(.red) }
                        }
                    }
                    Button { reset() } label: {
                        HStack(spacing: 10) {
                            ToolIcon(symbol: "arrow.counterclockwise").frame(width: 24, height: 24)
                            Text("恢复默认")
                            Spacer(minLength: 8)
                            if usesDefault { Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)) }
                        }.font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
                            .padding(.horizontal, 14).frame(minHeight: compact ? 38 : 44)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
                    }.buttonStyle(.plain).accessibilityIdentifier("appearance.reset." + item.rawValue)
                        .accessibilityAddTraits(usesDefault ? .isSelected : [])
                }.padding(compact ? 14 : 20).modifier(LiquidCard(radius: 24))
            }.padding(compact ? 12 : 20).padding(.bottom, 18)
        }.scrollDismissesKeyboard(.interactively)
    }
}
