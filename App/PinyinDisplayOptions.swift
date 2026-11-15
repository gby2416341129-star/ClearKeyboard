import SwiftUI

/// Uses the existing shared composition preference so the App, toolbar shortcut
/// and keyboard extension always select the same transport.
struct PinyinDisplayOptions: View {
    @EnvironmentObject private var preferences: Preferences
    private var local: Bool { preferences.settings.localPinyinComposition == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppSectionTitle(title: "拼音显示")
            AppCard {
                HStack(alignment: .top, spacing: 12) {
                    option("显示在输入框", local: false)
                    option("显示在候选栏", local: true)
                }
            }
        }.accessibilityIdentifier("custom.pinyinDisplay")
    }

    private func option(_ title: String, local value: Bool) -> some View {
        let selected = local == value
        return Button {
            preferences.settings.localPinyinComposition = value
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(value ? " " : "wei xin shu ru fa")
                        .font(.system(size: 12)).foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .padding(.horizontal, 6)
                        .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    Text(value ? "wei'xin'shu'ru'fa" : " ")
                        .font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(AppPalette.secondaryInk)
                    Text("微信输入法  微信")
                        .font(.system(size: 11)).foregroundStyle(AppPalette.secondaryInk)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? AppPalette.accent : Color.primary.opacity(0.10), lineWidth: selected ? 2 : 1))
                HStack(spacing: 6) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AppPalette.accent : AppPalette.secondaryInk)
                    Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? AppPalette.accent : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).accessibilityValue(selected ? "已选中" : "未选中")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(value ? "custom.pinyinDisplay.candidates" : "custom.pinyinDisplay.input")
    }
}
