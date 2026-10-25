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
    private let back = UIButton(type: .system)
    private let more = UIButton(type: .system)
    private let send = UIButton(type: .system)
    private let empty = UILabel()
    private let pasteControl: ClipboardPasteButton
    private var manualReadFailed = false
    private let table = UITableView(frame: .zero, style: .plain)
    private let words = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    private var selectionSource: String?
    private var tokens: [ClipboardSelection.Token] = []
    private var selection: (Int, Int)?
    var onClose: (() -> Void)?
    init(model: KeyboardModel, showPhrases: Bool = false) {
        self.model = model
        pasteControl = ClipboardPasteButton(capture: model.clipboardCapture)
        url = SharedStorage.clipboardURL(allowShared: true)
        phrasesURL = url.deletingLastPathComponent().appendingPathComponent("common-phrases.json")
        store = ClipboardStore(url: url); phrases = ClipboardStore(url: phrasesURL)
        super.init(frame: .zero)
        accessibilityIdentifier = "clipboard.panel"
        [tabs, back, more, send, table, words, empty, pasteControl].forEach(addSubview)
        pasteControl.isUserInteractionEnabled = model.document?.fullAccess == true
        tabs.accessibilityIdentifier = "clipboard.tabs"
        tabs.selectedSegmentIndex = showPhrases ? 1 : 0
        tabs.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
        back.setImage(ToolArtwork.image(symbol: "chevron.up", size: 24), for: .normal); back.accessibilityLabel = "返回键盘"
        back.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if self.selectionSource != nil { self.selectionSource = nil; self.selection = nil; self.reload() }
            else { self.onClose?() }
        }, for: .touchUpInside)
        more.setImage(ToolArtwork.image(symbol: "ellipsis", size: 24), for: .normal); more.accessibilityLabel = "剪贴板选项"
        more.showsMenuAsPrimaryAction = true
        send.setTitle("输入", for: .normal); send.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        send.accessibilityIdentifier = "clipboard.insertSelection"
        send.addAction(UIAction { [weak self] _ in
            guard let self, let source = self.selectionSource, let (from, to) = self.selection else { return }
            self.model.insertLiteral(ClipboardSelection.text(source, tokens: self.tokens, from: from, through: to)); self.onClose?()
        }, for: .touchUpInside)
        for button in [back, more] {
            button.backgroundColor = .tertiarySystemFill; button.layer.cornerRadius = 17
        }
        table.prepareForKeyboardPanel(); table.separatorStyle = .none
        table.dataSource = self; table.delegate = self; table.estimatedRowHeight = 66; table.rowHeight = UITableView.automaticDimension
        table.register(ClipboardCardCell.self, forCellReuseIdentifier: "clip")
        table.showsVerticalScrollIndicator = false; table.delaysContentTouches = false
        empty.textAlignment = .center; empty.textColor = .tertiaryLabel; empty.font = .systemFont(ofSize: 13)
        words.prepareForKeyboardPanel(); words.dataSource = self; words.delegate = self
        words.register(ClipboardTokenCell.self, forCellWithReuseIdentifier: "token")
        if let flow = words.collectionViewLayout as? UICollectionViewFlowLayout {
            flow.minimumInteritemSpacing = 6; flow.minimumLineSpacing = 7
        }
        let drag = UIPanGestureRecognizer(target: self, action: #selector(selectWords(_:))); drag.delegate = self
        words.addGestureRecognizer(drag)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        back.frame = CGRect(x: 0, y: 5, width: 34, height: 34)
        more.frame = CGRect(x: bounds.width - 34, y: 5, width: 34, height: 34)
        tabs.frame = CGRect(x: max(40, (bounds.width - 164) / 2), y: 7, width: min(164, max(0, bounds.width - 80)), height: 31)
        send.frame = CGRect(x: bounds.width - 56, y: 5, width: 56, height: 34)
        let content = CGRect(x: 0, y: 51, width: bounds.width, height: max(0, bounds.height - 51))
        let recoveryFooter = manualReadFailed && !items.isEmpty && tabs.selectedSegmentIndex == 0 && selectionSource == nil
        table.frame = CGRect(x: content.minX, y: content.minY, width: content.width, height: max(0, content.height - (recoveryFooter ? 82 : 0)))
        words.frame = content
        let recoveryY = recoveryFooter ? content.maxY - 82 : content.midY - 44
        empty.frame = CGRect(x: 8, y: recoveryY, width: max(0, bounds.width - 16), height: 34)
        pasteControl.frame = CGRect(x: (bounds.width - 114) / 2, y: recoveryY + 40, width: 114, height: 38)
    }
    func reloadFromDisk(clearRecovery: Bool = true) {
        if clearRecovery { manualReadFailed = false }
        store = ClipboardStore(url: url); phrases = ClipboardStore(url: phrasesURL); reload()
    }
    private func reload() {
        store.prune(lifetime: model.settings.clipboardLifetimeHours * 3_600)
        let choosing = selectionSource != nil
        tabs.isHidden = choosing; more.isHidden = choosing; send.isHidden = !choosing
        send.isEnabled = selection != nil; words.isHidden = !choosing; table.isHidden = choosing
        empty.isHidden = choosing || (!items.isEmpty && !manualReadFailed)
        empty.text = tabs.selectedSegmentIndex == 1 ? "暂无常用语" : model.document?.fullAccess != true ? "请先开启键盘完全访问" : manualReadFailed ? "本次未读到内容，可点下方粘贴收录" : "暂无复制内容，可粘贴收录"
        pasteControl.isHidden = choosing || tabs.selectedSegmentIndex == 1 || (!items.isEmpty && !manualReadFailed) || model.document?.fullAccess != true
        more.menu = overflowMenu()
        table.reloadData(); words.reloadData(); setNeedsLayout()
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
        selectionSource = text; tokens = ClipboardSelection.tokens(text); selection = nil; reload()
        words.setContentOffset(.zero, animated: false)
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { tokens.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "token", for: indexPath) as! ClipboardTokenCell
        let selected = selection.map { (min($0.0, $0.1)...max($0.0, $0.1)).contains(indexPath.item) } ?? false
        cell.label.text = tokens[indexPath.item].text
        cell.backgroundColor = selected ? tintColor.withAlphaComponent(0.28) : .tertiarySystemFill
        cell.label.textColor = selected ? tintColor : .label
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = (tokens[indexPath.item].text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 18)]).width + 18
        return CGSize(width: min(max(34, width), max(34, words.bounds.width)), height: 36)
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { selection = (indexPath.item, indexPath.item); words.reloadData(); send.isEnabled = true }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: words); return abs(velocity.x) > abs(velocity.y)
    }
    @objc private func selectWords(_ gesture: UIPanGestureRecognizer) {
        guard let index = words.indexPathForItem(at: gesture.location(in: words))?.item else { return }
        if gesture.state == .began { selection = (index, index) }
        else if gesture.state == .changed, let start = selection?.0 { selection = (start, index) }
        words.reloadData(); send.isEnabled = selection != nil
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
