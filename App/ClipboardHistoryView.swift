import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor private final class ClipboardHistoryModel: ObservableObject {
    @Published var clips: [Clip] = []
    private let queue = DispatchQueue(label: "clear.app.clipboard.history", qos: .userInitiated)
    private var revision = 0
    func reload() {
        revision += 1; let request = revision
        let url = SharedStorage.clipboardURL(allowShared: true)
        queue.async { [weak self] in
            let values = ClipboardStore(url: url).clips
            DispatchQueue.main.async {
                guard let self, self.revision == request else { return }; self.clips = values
            }
        }
    }
}

private struct ClipboardDay: Identifiable {
    let id: Date
    let clips: [Clip]
}

struct ClipboardHistoryView: View {
    @StateObject private var model = ClipboardHistoryModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppSectionTitle(title: "复制记录", caption: "")
            if model.clips.isEmpty {
                Text("暂无复制记录").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
            } else {
                AppCard {
                    AppNavigationLink { ClipboardHistoryTimeline(model: model) } label: {
                        AppRow(title: "全部复制记录", detail: "\(model.clips.count) 条 · 按日期", symbol: "doc.on.clipboard")
                    }
                }.buttonStyle(.plain)
            }
        }.onAppear { model.reload() }
            .onReceive(NotificationCenter.default.publisher(for: ClipboardStore.changed)) { _ in model.reload() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in model.reload() }
            .accessibilityIdentifier("clipboard.history")
    }
}

private struct ClipboardHistoryTimeline: View {
    @ObservedObject var model: ClipboardHistoryModel
    @State private var selected: Clip?
    private static let date: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy年M月d日"; return f }()
    private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    private var days: [ClipboardDay] {
        let grouped = Dictionary(grouping: model.clips) { Calendar.current.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted(by: >).map { ClipboardDay(id: $0, clips: grouped[$0, default: []].sorted { $0.createdAt > $1.createdAt }) }
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                    ForEach(days) { day in
                        Section {
                            ForEach(day.clips) { clip in
                                Button { selected = clip } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text(clip.attachment == nil ? "文字" : "图片与附件")
                                            Spacer()
                                            if clip.pinned { Image(systemName: "pin.fill") }
                                            Text(Self.time.string(from: clip.createdAt)).monospacedDigit()
                                        }.font(.caption).foregroundStyle(.secondary)
                                        Text(clip.text.isEmpty ? "查看附件" : String(clip.text.prefix(180)))
                                            .font(.system(size: 15)).foregroundStyle(.primary).lineLimit(4)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.padding(16).modifier(LiquidCard(radius: 18))
                                }.buttonStyle(AppRowButtonStyle()).accessibilityIdentifier("clipboard.history." + clip.id.uuidString)
                            }
                        } header: {
                            Text(Self.date.string(from: day.id)).font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                                .background(AppPalette.canvas)
                        }.id(day.id)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 110)
            }.background(AppPalette.canvas)
                .navigationTitle("复制记录").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            ForEach(days) { day in
                                Button(Self.date.string(from: day.id)) {
                                    withAnimation(.easeInOut(duration: 0.24)) { proxy.scrollTo(day.id, anchor: .top) }
                                }
                            }
                        } label: { Image(systemName: "calendar") }.accessibilityLabel("按日期定位复制记录")
                    }
                }
        }.sheet(item: $selected) { ClipboardHistoryDetail(clip: $0) }.onAppear { model.reload() }
    }
}

private struct ClipboardHistoryDetail: View {
    let clip: Clip
    @Environment(\.dismiss) private var dismiss
    @State private var attachmentData: Data?
    var body: some View {
        NavigationStack {
            Group {
                if clip.attachment == nil { ClipboardArticleView(text: clip.text) }
                else {
                    ScrollView {
                        VStack(spacing: 20) {
                            if let data = attachmentData, let image = UIImage(data: data) {
                                Image(uiImage: image).resizable().scaledToFit()
                            }
                            Text(clip.text).textSelection(.enabled)
                        }.padding(20)
                    }
                }
            }.background(AppPalette.canvas).navigationTitle("复制内容").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("复制") {
                            if let attachment = clip.attachment, let data = attachmentData {
                                UIPasteboard.general.setItems([[attachment.typeIdentifier: data]], options: [.localOnly: true])
                            } else if clip.attachment == nil { UIPasteboard.general.string = clip.text }
                            AppFunctionalFeedback.pulse()
                        }.disabled(clip.attachment != nil && attachmentData == nil)
                    }
                }
        }.onAppear {
            guard clip.attachment != nil else { return }
            let value = clip, url = SharedStorage.clipboardURL(allowShared: true)
            DispatchQueue.global(qos: .userInitiated).async {
                let data = ClipboardStore(url: url).attachmentData(for: value)
                DispatchQueue.main.async { attachmentData = data }
            }
        }
    }
}

private struct ClipboardArticleView: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.isEditable = false; view.isSelectable = true
        view.backgroundColor = .clear; view.font = .systemFont(ofSize: 17)
        view.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 24, right: 16)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) { if view.text != text { view.text = text } }
}
