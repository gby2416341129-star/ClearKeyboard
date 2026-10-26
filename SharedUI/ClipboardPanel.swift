import UIKit
import ImageIO

/// Content occupies all available space. Permissions and collection controls live
/// in the overflow menu rather than displacing copied items with instructions.
@MainActor final class ClipboardPanel: UIView, UITableViewDataSource, UITableViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
    private let model: KeyboardModel
    private let url: URL
    private let phrasesURL: URL
    private var store: ClipboardStore
    private var phrases: ClipboardStore
    private var items: [Clip] { tabs.selectedSegmentIndex == 1 ? phrases.clips : store.clips }
    private let tabs = UISegmentedControl(items: ["剪贴板", "常用语"])
    private let more = UIButton(type: .system)
    private let send = UIButton(type: .system)
    private let empty = UILabel()
    private var manualReadFailed = false
    private let table = UITableView(frame: .zero, style: .plain)
    private let words = UICollectionView(frame: .zero, collectionViewLayout: ClipboardTokenLayout())
    private var selectionSource: String?
    private var tokens: [ClipboardSelection.Token] = []
    private var selectedTokens = Set<Int>()
    private var selectionSession: ClipboardTextSession?
    private var dragBaseline = Set<Int>()
    private var dragStart: Int?
    private var dragAdds = true
    private var dragVisited = Set<Int>()
    private var selectionUpdates: UIUpdateLink?
    private var selectionPoint: CGPoint?
    private var selectionTimestamp: CFTimeInterval = 0
    private var pendingHostSelection: Set<Int>?
    private var selectionRetry: DispatchWorkItem?
    private var selectionRetries = 0
    var onClose: (() -> Void)?
    var onSelectionStateChanged: (() -> Void)?
    var isChoosing: Bool { selectionSource != nil }
    var canFinishSelection: Bool { !selectedTokens.isEmpty }
    private let completionInToolbar: Bool
    init(model: KeyboardModel, showPhrases: Bool = false, completionInToolbar: Bool = false) {
        self.model = model
        self.completionInToolbar = completionInToolbar
        url = SharedStorage.clipboardURL(allowShared: true)
        phrasesURL = url.deletingLastPathComponent().appendingPathComponent("common-phrases.json")
        store = ClipboardStore(url: url); phrases = ClipboardStore(url: phrasesURL)
        super.init(frame: .zero)
        accessibilityIdentifier = "clipboard.panel"
        [tabs, more, table, words, empty].forEach(addSubview)
        if !completionInToolbar { addSubview(send) }
        tabs.accessibilityIdentifier = "clipboard.tabs"
        tabs.selectedSegmentIndex = showPhrases ? 1 : 0
        tabs.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
        more.setImage(ToolArtwork.image(symbol: "ellipsis", size: 24), for: .normal); more.accessibilityLabel = "剪贴板选项"
        more.showsMenuAsPrimaryAction = true
        send.setTitle("完成", for: .normal); send.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        send.accessibilityIdentifier = "clipboard.insertSelection"
        send.addAction(UIAction { [weak self] _ in
            self?.finishSelection()
        }, for: .touchUpInside)
        more.backgroundColor = .tertiarySystemFill; more.layer.cornerRadius = 17
        table.prepareForKeyboardPanel(); table.separatorStyle = .none
        table.dataSource = self; table.delegate = self; table.estimatedRowHeight = 66; table.rowHeight = UITableView.automaticDimension
        table.register(ClipboardCardCell.self, forCellReuseIdentifier: "clip")
        table.showsVerticalScrollIndicator = false; table.delaysContentTouches = false
        empty.textAlignment = .center; empty.textColor = .tertiaryLabel; empty.font = .systemFont(ofSize: 13)
        words.accessibilityIdentifier = "clipboard.selection.words"
        words.prepareForKeyboardPanel(); words.dataSource = self; words.delegate = self
        words.register(ClipboardTokenCell.self, forCellWithReuseIdentifier: "token")
        words.allowsSelection = false
        words.delaysContentTouches = false
        if let layout = words.collectionViewLayout as? ClipboardTokenLayout {
            layout.widthForToken = { [weak self] index in
                guard let self, self.tokens.indices.contains(index) else { return 28 }
                return (self.tokens[index].text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 18)]).width + 12
            }
        }
        let drag = UIPanGestureRecognizer(target: self, action: #selector(selectWords(_:))); drag.delegate = self; drag.cancelsTouchesInView = false
        words.addGestureRecognizer(drag); words.panGestureRecognizer.require(toFail: drag)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapWord(_:)))
        tap.require(toFail: drag); tap.cancelsTouchesInView = false; tap.delaysTouchesBegan = false; tap.delaysTouchesEnded = false; words.addGestureRecognizer(tap)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        more.frame = CGRect(x: bounds.width - 34, y: 5, width: 34, height: 34)
        let tabWidth = min(184, max(0, bounds.width - 88))
        tabs.frame = CGRect(x: (bounds.width - tabWidth) / 2, y: 7, width: tabWidth, height: 31)
        send.frame = CGRect(x: bounds.width - 56, y: 5, width: 56, height: 34)
        let top: CGFloat = isChoosing && completionInToolbar ? 4 : 51
        let content = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        let recoveryFooter = false
        table.frame = CGRect(x: content.minX, y: content.minY, width: content.width, height: max(0, content.height - (recoveryFooter ? 82 : 0)))
        words.frame = content
        let recoveryY = recoveryFooter ? content.maxY - 82 : content.midY - 44
        empty.frame = CGRect(x: 8, y: recoveryY, width: max(0, bounds.width - 16), height: 34)
    }
    func reloadFromDisk(clearRecovery: Bool = true) {
        if clearRecovery { manualReadFailed = false }
        store = ClipboardStore(url: url); phrases = ClipboardStore(url: phrasesURL)
        if !isChoosing { reload() }
    }
    private func reload() {
        store.prune(lifetime: model.settings.clipboardLifetimeHours * 3_600)
        let choosing = selectionSource != nil
        tabs.isHidden = choosing; more.isHidden = choosing; send.isHidden = !choosing || completionInToolbar
        send.isEnabled = !selectedTokens.isEmpty; words.isHidden = !choosing; table.isHidden = choosing
        empty.isHidden = choosing || !items.isEmpty
        empty.text = tabs.selectedSegmentIndex == 1 ? "暂无常用语" : model.document?.fullAccess != true ? "请先开启键盘完全访问" : "暂无复制内容"
        more.menu = overflowMenu()
        table.reloadData(); words.reloadData(); setNeedsLayout(); onSelectionStateChanged?()
    }
    private func overflowMenu() -> UIMenu {
        let lifetime = UIMenu(title: "保留时间", children: [("1 天", 24.0), ("7 天", 168.0), ("30 天", 720.0), ("永久", 0.0)].map { title, hours in
            UIAction(title: title, state: model.settings.clipboardLifetimeHours == hours ? .on : .off) { [weak self] _ in
                self?.model.settings.clipboardLifetimeHours = hours; self?.reload()
            }
        })
        return UIMenu(children: [
            UIAction(title: "自动收录", image: ToolArtwork.image(symbol: "doc.on.clipboard", size: 24), state: model.settings.capturesClipboard ? .on : .off) { [weak self] _ in
                guard let self else { return }; self.model.settings.automaticClipboard = !self.model.settings.capturesClipboard; self.reload()
            },
            UIAction(title: "收录当前复制内容", image: ToolArtwork.image(symbol: "plus", size: 24), attributes: model.document?.fullAccess == true ? [] : .disabled) { [weak self] _ in
                guard let self else { return }
                self.manualReadFailed = !self.model.clipboardCapture.captureManually()
                self.reloadFromDisk(clearRecovery: false)
            }, lifetime,
            UIAction(title: tabs.selectedSegmentIndex == 1 ? "清空常用语" : "清空剪贴板", image: ToolArtwork.image(symbol: "trash", size: 24), attributes: .destructive) { [weak self] _ in
                guard let self else { return }
                if self.tabs.selectedSegmentIndex == 1 { self.phrases.clear() } else { self.store.clear() }; self.reload()
            }
        ])
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "clip", for: indexPath) as! ClipboardCardCell
        let clip = items[indexPath.row]
        cell.configure(clip, menu: menu(for: clip))
        cell.onToken = { [weak self] token in self?.model.insertLiteral(token); self?.onClose?() }
        if clip.attachment != nil, let data = (tabs.selectedSegmentIndex == 1 ? phrases : store).attachmentData(for: clip),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 112] as CFDictionary) {
            cell.preview.image = UIImage(cgImage: image)
        }
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let clip = items[indexPath.row], activeStore = tabs.selectedSegmentIndex == 1 ? phrases : store
        if let attachment = clip.attachment, let data = activeStore.attachmentData(for: clip) {
            UIPasteboard.general.setItems([[attachment.typeIdentifier: data]], options: [.localOnly: true])
            UIAccessibility.post(notification: .announcement, argument: "已复制，请在输入框粘贴")
        } else { model.insertLiteral(clip.text) }
        onClose?()
    }
    private func menu(for clip: Clip) -> UIMenu {
        var actions: [UIAction] = [UIAction(title: "复制", image: ToolArtwork.image(symbol: "doc.on.doc", size: 24)) { [weak self] _ in
            guard let self else { return }
            if let attachment = clip.attachment,
               let data = (self.tabs.selectedSegmentIndex == 1 ? self.phrases : self.store).attachmentData(for: clip) {
                UIPasteboard.general.setItems([[attachment.typeIdentifier: data]], options: [.localOnly: true])
            } else { UIPasteboard.general.string = clip.text }
            UIAccessibility.post(notification: .announcement, argument: "已复制")
        }]
        if clip.attachment == nil {
            if tabs.selectedSegmentIndex == 0 {
                actions.append(UIAction(title: "加入常用语", image: ToolArtwork.image(symbol: "plus.bubble", size: 24)) { [weak self] _ in self?.phrases.add(clip.text); self?.reload() })
            }
            actions.append(UIAction(title: "滑动选词", image: ToolArtwork.image(symbol: "selection.pin.in.out", size: 24)) { [weak self] _ in self?.selectText(clip.text) })
        }
        actions.append(UIAction(title: "删除", image: ToolArtwork.image(symbol: "trash", size: 24), attributes: .destructive) { [weak self] _ in self?.remove(clip) })
        return UIMenu(children: actions)
    }
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let clip = items[indexPath.row]
        var actions = [UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in self?.remove(clip); done(true) }]
        if clip.attachment == nil {
            let choose = UIContextualAction(style: .normal, title: "选词") { [weak self] _, _, done in self?.selectText(clip.text); done(true) }; choose.backgroundColor = .systemTeal; actions.append(choose)
            if tabs.selectedSegmentIndex == 0 {
                let add = UIContextualAction(style: .normal, title: "+ 常用语") { [weak self] _, _, done in self?.phrases.add(clip.text); done(true) }; add.backgroundColor = .systemBlue; actions.append(add)
            }
        }
        let config = UISwipeActionsConfiguration(actions: actions); config.performsFirstActionWithFullSwipe = false; return config
    }
    private func remove(_ clip: Clip) {
        if tabs.selectedSegmentIndex == 1 { phrases.delete(clip.id) } else { store.delete(clip.id) }; reload()
    }
    func selectText(_ text: String) {
        selectionSource = text; tokens = ClipboardSelection.tokens(text); selectedTokens = []
        selectionSession = model.beginClipboardSelection(); reload()
        words.setContentOffset(.zero, animated: false)
    }
    func finishSelection() {
        endSelection(); onClose?()
    }
    func endSelection() {
        flushHostSelection(); selectionRetry?.cancel(); selectionRetry = nil; stopSelectionUpdates()
        selectionSession?.finish(); selectionSession = nil
        model.refreshCandidates()
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { tokens.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "token", for: indexPath) as! ClipboardTokenCell
        configure(cell, at: indexPath.item); return cell
    }
    private func configure(_ cell: ClipboardTokenCell, at index: Int) {
        let selected = selectedTokens.contains(index)
        cell.label.text = tokens[index].text
        cell.backgroundColor = selected ? tintColor.withAlphaComponent(0.28) : .tertiarySystemFill
        cell.label.textColor = selected ? tintColor : .label
        cell.accessibilityTraits = selected ? [.button, .selected] : .button
    }
    private func index(at point: CGPoint) -> Int? {
        if let index = words.indexPathForItem(at: point)?.item { return index }
        return words.collectionViewLayout.layoutAttributesForElements(in: CGRect(x: point.x - 24, y: point.y - 20, width: 48, height: 40))?
            .min(by: { hypot($0.center.x - point.x, $0.center.y - point.y) < hypot($1.center.x - point.x, $1.center.y - point.y) })?.indexPath.item
    }
    @discardableResult func setSelection(_ indices: Set<Int>) -> Bool {
        guard selectionSource != nil, indices != selectedTokens else { return true }
        let changed = selectedTokens.symmetricDifference(indices)
        let wasEmpty = selectedTokens.isEmpty
        selectionRetry?.cancel(); selectionRetries = 0
        selectedTokens = indices; pendingHostSelection = indices
        for case let cell as ClipboardTokenCell in words.visibleCells {
            if let index = words.indexPath(for: cell)?.item, changed.contains(index) { configure(cell, at: index) }
        }
        send.isEnabled = !selectedTokens.isEmpty
        if wasEmpty != selectedTokens.isEmpty { onSelectionStateChanged?() }
        if dragStart == nil { return flushHostSelection() }
        return true
    }
    @discardableResult private func flushHostSelection() -> Bool {
        guard let indices = pendingHostSelection, let source = selectionSource, let session = selectionSession else { return true }
        let text = ClipboardSelection.text(source, tokens: tokens, selected: indices)
        guard model.updateClipboardSelection(session, text: text) else {
            if selectionRetries < 3 {
                selectionRetries += 1; selectionRetry?.cancel()
                let retry = DispatchWorkItem { [weak self, weak session] in
                    guard let self, self.selectionSession === session else { return }
                    self.flushHostSelection()
                }
                selectionRetry = retry; DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(selectionRetries), execute: retry)
            }
            return false
        }
        pendingHostSelection = nil; selectionRetry?.cancel(); selectionRetry = nil; selectionRetries = 0
        return true
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        var next = selectedTokens
        if next.contains(indexPath.item) { next.remove(indexPath.item) } else { next.insert(indexPath.item) }
        _ = setSelection(next)
    }
    @objc private func tapWord(_ gesture: UITapGestureRecognizer) {
        guard let index = index(at: gesture.location(in: words)) else { return }
        collectionView(words, didSelectItemAt: IndexPath(item: index, section: 0))
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIPanGestureRecognizer else { return true }
        return index(at: gestureRecognizer.location(in: words)) != nil
    }
    private func stopSelectionUpdates() {
        selectionUpdates?.requiresContinuousUpdates = false; selectionUpdates?.isEnabled = false
        selectionUpdates = nil; selectionPoint = nil; dragStart = nil
    }
    @objc private func selectWords(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: words)
        if gesture.state == .began {
            let translation = gesture.translation(in: words)
            let origin = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            guard let start = index(at: origin) else { return }
            dragStart = start; dragBaseline = selectedTokens; dragVisited = []
            dragAdds = !selectedTokens.contains(start)
            selectionTimestamp = CACurrentMediaTime()
            let updates = UIUpdateLink(view: words)
            updates.addAction(to: .beforeCATransactionCommit) { [weak self] _, _ in self?.selectionTick() }
            let maximum = Float(window?.screen.maximumFramesPerSecond ?? 60)
            updates.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
            updates.requiresContinuousUpdates = true; updates.isEnabled = true; selectionUpdates = updates
        }
        selectionPoint = CGPoint(x: point.x, y: point.y - words.contentOffset.y)
        if gesture.state == .began || gesture.state == .changed || gesture.state == .ended { updateDrag(at: point) }
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            flushHostSelection(); stopSelectionUpdates()
        }
    }
    private func updateDrag(at point: CGPoint) {
        guard let start = dragStart, let index = index(at: point) else { return }
        let range = Set(min(start, index)...max(start, index))
        dragVisited.formUnion(range)
        let next = dragAdds ? dragBaseline.union(range).subtracting(dragVisited.subtracting(range))
            : dragBaseline.subtracting(dragVisited)
        _ = setSelection(next)
    }
    private func selectionTick() {
        guard let point = selectionPoint, dragStart != nil else { return }
        let now = CACurrentMediaTime(), dt = min(1.0 / 30, max(0, now - selectionTimestamp))
        selectionTimestamp = now
        let edge: CGFloat = 28
        let direction = point.y < edge ? -min(1, (edge - point.y) / edge)
            : point.y > words.bounds.height - edge ? min(1, (point.y - words.bounds.height + edge) / edge) : 0
        let maximum = max(0, words.contentSize.height - words.bounds.height)
        let offset = min(maximum, max(0, words.contentOffset.y + direction * 180 * CGFloat(dt)))
        if offset != words.contentOffset.y { words.contentOffset.y = offset }
        updateDrag(at: CGPoint(x: min(max(2, point.x), words.bounds.width - 2),
                               y: min(max(2, point.y), words.bounds.height - 2) + words.contentOffset.y))
        flushHostSelection()
    }

}

@MainActor private final class ClipboardCardCell: UITableViewCell {
    private let card = UIView()
    private let glass = LiquidGlassView(radius: 16)
    private let label = UILabel()
    let preview = UIImageView()
    private let more = UIButton(type: .system)
    private let chips = UIStackView()
    var onToken: ((String) -> Void)?
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear; selectionStyle = .none
        card.backgroundColor = .clear; card.layer.cornerRadius = 16
        glass.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(glass)
        NSLayoutConstraint.activate([glass.leadingAnchor.constraint(equalTo: card.leadingAnchor), glass.trailingAnchor.constraint(equalTo: card.trailingAnchor), glass.topAnchor.constraint(equalTo: card.topAnchor), glass.bottomAnchor.constraint(equalTo: card.bottomAnchor)])
        contentView.addSubview(card); card.translatesAutoresizingMaskIntoConstraints = false
        let content = UIStackView(); content.axis = .vertical; content.spacing = 9
        content.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(content)
        let row = UIStackView(); row.spacing = 10; row.alignment = .top
        preview.contentMode = .scaleAspectFit
        let previewWidth = preview.widthAnchor.constraint(equalToConstant: 42); previewWidth.priority = .defaultHigh; previewWidth.isActive = true
        preview.heightAnchor.constraint(equalToConstant: 42).isActive = true
        label.font = .systemFont(ofSize: 16); label.numberOfLines = 3
        more.setImage(ToolArtwork.image(symbol: "ellipsis", size: 24), for: .normal); more.transform = CGAffineTransform(rotationAngle: .pi / 2)
        more.widthAnchor.constraint(equalToConstant: 26).isActive = true; more.heightAnchor.constraint(equalToConstant: 28).isActive = true
        more.showsMenuAsPrimaryAction = true; more.accessibilityLabel = "项目选项"
        row.addArrangedSubview(preview); row.addArrangedSubview(label); row.addArrangedSubview(more)
        content.addArrangedSubview(row); content.addArrangedSubview(chips)
        chips.axis = .horizontal; chips.spacing = 8; chips.alignment = .leading
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4), card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14), content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 13), content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -13)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func configure(_ clip: Clip, menu: UIMenu) {
        label.text = clip.text; more.menu = menu; preview.image = nil; preview.isHidden = clip.attachment == nil
        chips.arrangedSubviews.forEach { chips.removeArrangedSubview($0); $0.removeFromSuperview() }
        let snippets = ClipboardSelection.tokens(clip.text).map(\.text).filter { $0.count >= 2 && $0.first?.isASCII == true && $0.first?.isLetter == true || $0.count >= 2 && $0.first?.isNumber == true }
        var seen = Set<String>()
        for snippet in snippets.filter({ seen.insert($0).inserted }).prefix(2) where clip.attachment == nil && snippet != clip.text {
            let chip = UIButton(type: .system); chip.setTitle(snippet, for: .normal); chip.titleLabel?.font = .systemFont(ofSize: 12)
            chip.contentEdgeInsets = UIEdgeInsets(top: 4, left: 9, bottom: 4, right: 9); chip.backgroundColor = .tertiarySystemFill; chip.layer.cornerRadius = 7
            chip.addAction(UIAction { [weak self] _ in self?.onToken?(snippet) }, for: .touchUpInside); chips.addArrangedSubview(chip)
        }
        chips.isHidden = chips.arrangedSubviews.isEmpty
        if !chips.isHidden { let spacer = UIView(); chips.addArrangedSubview(spacer); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal) }
    }
}

@MainActor private final class ClipboardTokenCell: UICollectionViewCell {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame); contentView.addSubview(label); label.textAlignment = .center
        label.font = .systemFont(ofSize: 18); layer.cornerRadius = 7
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() { super.layoutSubviews(); label.frame = contentView.bounds; accessibilityLabel = label.text }
}

