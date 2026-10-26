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

struct ClipboardHistoryView: View {
    @StateObject private var model = ClipboardHistoryModel()
    @State private var selected: Clip?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppSectionTitle(title: "复制记录", caption: "")
            if model.clips.isEmpty {
                Text("暂无复制记录").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(model.clips) { clip in
                        Button { selected = clip } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(clip.attachment == nil ? "文字" : "图片与附件").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if clip.pinned { Image(systemName: "pin.fill").font(.caption) }
                                    Text(clip.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(clip.text.isEmpty ? "查看附件" : clip.text).font(.system(size: 15))
                                    .foregroundStyle(.primary).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(16).modifier(LiquidCard(radius: 18))
                        }.buttonStyle(AppRowButtonStyle()).accessibilityIdentifier("clipboard.history." + clip.id.uuidString)
                    }
                }
            }
        }.onAppear { model.reload() }
            .onReceive(NotificationCenter.default.publisher(for: ClipboardStore.changed)) { _ in model.reload() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in model.reload() }
            .sheet(item: $selected) { ClipboardHistoryDetail(clip: $0) }
            .accessibilityIdentifier("clipboard.history")
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
