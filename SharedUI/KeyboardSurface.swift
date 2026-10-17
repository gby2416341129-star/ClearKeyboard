import UIKit

@MainActor final class KeyboardSurface: UIView {
    let model: KeyboardModel
    var onHeightChange: ((CGFloat) -> Void)?
    var configureGlobe: ((UIButton) -> Void)? { didSet { layoutSignature = ""; render() } }
    private let backdrop = GlassBackdrop()
    private let toolbar = UIStackView()
    private let toolbarGlass = UIVisualEffectView()
    private let spelling = UILabel()
    private let clearSpelling = UIButton(type: .system)
    private let candidateScroll = UIScrollView()
    private let candidateStack = UIStackView()
    private let hint = UILabel()
    private let keyGlassGroup = UIVisualEffectView()
    private var keysContainer: UIView { keyGlassGroup.contentView }
    private var movingCursor = false
    private let restore = UIButton(type: .system)
    private let status = UILabel()
    private var statusWork: DispatchWorkItem?
    private var keys: [(KeyButton, Int, Double, Double)] = []
    private var layoutSignature = ""
    private var appearanceSignature = ""
    private var candidateSnapshot: [Candidate] = []
    private var panel: UIView?
    private var clipboard: ClipboardStore?
    private var observerTokens: [NSObjectProtocol] = []
    private var panelKind: ToolbarTool?
    var desiredHeight: CGFloat { 80 + CGFloat(model.settings.keyHeight + 6) * 4 + 8 }

    init(model: KeyboardModel) {
        self.model = model; super.init(frame: .zero)
        clipsToBounds = true; addSubview(backdrop)
        toolbar.axis = .horizontal; toolbar.distribution = .equalSpacing
        addSubview(toolbarGlass); toolbarGlass.isUserInteractionEnabled = false
        toolbarGlass.layer.cornerRadius = 19
        addSubview(toolbar); addSubview(spelling); addSubview(clearSpelling)
        spelling.font = .monospacedSystemFont(ofSize: 16, weight: .medium); spelling.textColor = .label
        spelling.lineBreakMode = .byTruncatingHead
        clearSpelling.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        clearSpelling.accessibilityLabel = "清除拼音"
        clearSpelling.addAction(UIAction { [weak model] _ in model?.clearComposition() }, for: .touchUpInside)
        addSubview(candidateScroll); candidateScroll.addSubview(candidateStack)
        candidateScroll.showsHorizontalScrollIndicator = false
        candidateStack.axis = .horizontal; candidateStack.spacing = 22; candidateStack.alignment = .center
        addSubview(hint); hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabel
        hint.textAlignment = .center; hint.isUserInteractionEnabled = false
        addSubview(keyGlassGroup); addSubview(restore)
        addSubview(status); status.isHidden = true; status.textAlignment = .center
        status.font = .systemFont(ofSize: 12); status.backgroundColor = .secondarySystemBackground
        status.layer.cornerRadius = 10; status.clipsToBounds = true
        restore.setImage(UIImage(systemName: "arrow.left.and.right"), for: .normal)
        restore.accessibilityLabel = "恢复标准键盘"
        restore.addAction(UIAction { [weak model] _ in model?.settings.hand = .full }, for: .touchUpInside)
        model.onChange = { [weak self] in self?.render() }
        for name in [UIAccessibility.reduceTransparencyStatusDidChangeNotification, UIAccessibility.reduceMotionStatusDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observerTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.appearanceSignature = ""; self?.render()
            })
        }
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit { observerTokens.forEach { NotificationCenter.default.removeObserver($0) } }

    override func layoutSubviews() {
        super.layoutSubviews(); backdrop.frame = bounds
        let settings = model.settings
        let left = safeAreaInsets.left, right = safeAreaInsets.right
        let available = bounds.width - left - right
        let width = settings.hand == .full ? available : available * 0.82
        let origin = settings.hand == .right ? bounds.width - right - width : left
        toolbar.frame = CGRect(x: left + 14, y: 0, width: available - 28, height: 38)
        toolbarGlass.frame = toolbar.frame.insetBy(dx: 0, dy: 1)
        spelling.frame = CGRect(x: left + 16, y: 0, width: available - 70, height: 38)
        clearSpelling.frame = CGRect(x: bounds.width - right - 48, y: 0, width: 44, height: 38)
        candidateScroll.frame = CGRect(x: left + 14, y: 38, width: available - 28, height: 42)
        candidateStack.sizeToFit(); candidateStack.frame.origin = CGPoint(x: 2, y: 0)
        candidateStack.frame.size.height = 42
        candidateScroll.contentSize = CGSize(width: candidateStack.frame.width + 12, height: 42)
        hint.frame = candidateScroll.frame
        status.frame = candidateScroll.frame
        keyGlassGroup.frame = CGRect(x: origin, y: 80, width: width, height: desiredHeight - 80)
        let unit = width / 10, rowHeight = CGFloat(settings.keyHeight + 6)
        for (button, row, start, units) in keys {
            button.frame = CGRect(x: CGFloat(start) * unit, y: CGFloat(row) * rowHeight,
                                  width: CGFloat(units) * unit, height: rowHeight)
        }
        restore.isHidden = settings.hand == .full
        restore.frame = CGRect(x: settings.hand == .right ? left : origin + width, y: 80,
                               width: available - width, height: rowHeight * 4)
        panel?.frame = CGRect(x: left + 8, y: 80, width: available - 16, height: desiredHeight - 88)
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        appearanceSignature = ""; render()
    }
    func render() {
        let settings = model.settings
        let signature = "\(model.page)-\(model.shifted)-\(model.capsLocked)-\(model.document?.needsGlobe ?? true)-\(settings.toolbar)-\(settings.language)"
        if signature != layoutSignature && !movingCursor {
            layoutSignature = signature
            keys.forEach { $0.0.removeFromSuperview() }; keys = []
            for (rowIndex, row) in KeyboardLayout.rows(page: model.page, uppercase: model.shifted, globe: model.document?.needsGlobe ?? true).enumerated() {
                var start = row.insetUnits
                for key in row.keys {
                    let button = KeyButton(key: key)
                    if key.action == .globe, let configureGlobe { configureGlobe(button) }
                    else { button.onAction = { [weak model] action in model?.handle(action) } }
                    button.onCursor = { [weak model] offset in model?.moveCursor(offset) }
                    button.onCursorBegan = { [weak self] in self?.setCursorMode(true); self?.model.beginCursorMovement() }
                    button.onCursorEnded = { [weak self] in self?.setCursorMode(false) }
                    keysContainer.addSubview(button); keys.append((button, rowIndex, start, key.units)); start += key.units
                }
            }
            rebuildToolbar()
            appearanceSignature = ""
        }
        let style = "\(settings.glass)-\(settings.accent)-\(settings.customAccentHex ?? "")-\(settings.glassOpacity)-\(settings.haptics)-\(traitCollection.userInterfaceStyle.rawValue)"
        let appearanceChanged = style != appearanceSignature
        if appearanceChanged {
            appearanceSignature = style; backdrop.apply(settings)
            tintColor = settings.accentInkColor
            let reduced = settings.glass == .solid || UIAccessibility.isReduceTransparencyEnabled || ProcessInfo.processInfo.isLowPowerModeEnabled
            if #available(iOS 26.0, *), !reduced {
                let group = UIGlassContainerEffect(); group.spacing = 0; keyGlassGroup.effect = group
                let glass = UIGlassEffect(style: settings.glass == .clear ? .clear : .regular)
                glass.tintColor = settings.accentColor.withAlphaComponent(0.06)
                toolbarGlass.cornerConfiguration = .corners(radius: .fixed(19)); toolbarGlass.effect = glass
            } else {
                keyGlassGroup.effect = nil
                toolbarGlass.effect = reduced ? nil : UIBlurEffect(style: .systemThinMaterial)
            }
        }
        for (button, _, _, _) in keys {
            var title: String? = nil
            if button.key.action == .space { title = settings.language == .chinese ? "空格" : "space" }
            if button.key.action == .enter { title = model.composition.isEmpty ? (model.document?.enterTitle ?? "换行") : "确认" }
            if appearanceChanged { button.apply(settings, title: title, active: button.key.action == .shift && model.shifted, capsLocked: model.capsLocked) }
            else if let title { button.updateTitle(title) }
        }
        spelling.text = model.composition.raw
        toolbar.isHidden = !model.composition.raw.isEmpty
        toolbarGlass.isHidden = toolbar.isHidden
        spelling.isHidden = model.composition.raw.isEmpty; clearSpelling.isHidden = spelling.isHidden
        if candidateSnapshot != model.candidates {
            candidateSnapshot = model.candidates
            candidateStack.arrangedSubviews.forEach { candidateStack.removeArrangedSubview($0); $0.removeFromSuperview() }
            for (index, candidate) in model.candidates.enumerated() {
                let button = UIButton(type: .system)
                button.setTitle(candidate.text, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 19, weight: index == 0 ? .medium : .regular)
                button.setTitleColor(index == 0 ? settings.accentInkColor : .label, for: .normal)
                button.accessibilityLabel = "候选：" + candidate.text
                button.addAction(UIAction { [weak model] _ in model?.choose(candidate) }, for: .touchUpInside)
                candidateStack.addArrangedSubview(button)
            }
            candidateScroll.setContentOffset(.zero, animated: false)
        }
        for (index, view) in candidateStack.arrangedSubviews.enumerated() {
            guard let button = view as? UIButton else { continue }
            if button.isEnabled != model.candidatesAreCurrent { button.isEnabled = model.candidatesAreCurrent }
            if appearanceChanged { button.setTitleColor(index == 0 ? settings.accentInkColor : .label, for: .normal) }
        }
        hint.isHidden = !model.candidates.isEmpty
        hint.text = model.composition.isEmpty ? (settings.language == .chinese ? "\(model.engineState)  ·  中文拼音" : "\(model.engineState)  ·  English") : "正在匹配 \(model.composition.raw)"
        if movingCursor { candidateScroll.isHidden = true; hint.isHidden = false; hint.text = "左右滑动，移动光标" }
        else { candidateScroll.isHidden = false }
        onHeightChange?(desiredHeight); setNeedsLayout()
    }
    private func rebuildToolbar() {
        toolbar.arrangedSubviews.forEach { toolbar.removeArrangedSubview($0); $0.removeFromSuperview() }
        for item in model.settings.toolbar {
            let button = UIButton(type: .system)
            if item == .language {
                button.setTitle(model.settings.language == .chinese ? "中 / EN" : "EN / 中", for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
            } else { button.setImage(UIImage(systemName: item.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)), for: .normal) }
            button.accessibilityLabel = item.title
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                if item == .language { self.closePanel(); self.model.toggleLanguage() }
                else { self.showPanel(item) }
            }, for: .touchUpInside)
            toolbar.addArrangedSubview(button)
        }
    }
    private func setCursorMode(_ active: Bool) {
        movingCursor = active; toolbar.isUserInteractionEnabled = !active; restore.isUserInteractionEnabled = !active
        keys.forEach { $0.0.setCursorMode(active) }; render()
    }
    func closePanel() { panel?.removeFromSuperview(); panel = nil; panelKind = nil; keyGlassGroup.isHidden = false; setNeedsLayout() }
    func stopInteractions() { keys.forEach { $0.0.stopTracking() }; setCursorMode(false); statusWork?.cancel(); status.isHidden = true; closePanel() }
    private func showStatus(_ text: String) {
        statusWork?.cancel(); status.text = text; status.textColor = model.settings.accentColor
        status.isHidden = false; bringSubviewToFront(status)
        UIAccessibility.post(notification: .announcement, argument: text)
        let hide = DispatchWorkItem { [weak self] in self?.status.isHidden = true }
        statusWork = hide; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: hide)
    }
    private func showPanel(_ kind: ToolbarTool) {
        if panelKind == kind { closePanel(); return }
        closePanel(); panelKind = kind; keyGlassGroup.isHidden = true
        let container = UIView(); container.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.96)
        container.layer.cornerRadius = 18; addSubview(container); panel = container
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor), scroll.topAnchor.constraint(equalTo: container.topAnchor), scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8), stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -24)])
        let header = UIStackView(); header.axis = .horizontal
        let title = UILabel(); title.text = kind.title; title.font = .systemFont(ofSize: 16, weight: .semibold)
        header.addArrangedSubview(title)
        let done = actionButton("完成", symbol: "chevron.down") { [weak self] in self?.closePanel() }
        header.addArrangedSubview(done); stack.addArrangedSubview(header)
        switch kind {
        case .clipboard: buildClipboard(stack)
        case .emoji: buildEmoji(stack)
        case .oneHand:
            let segment = UISegmentedControl(items: HandMode.allCases.map(\.title))
            segment.selectedSegmentIndex = HandMode.allCases.firstIndex(of: model.settings.hand) ?? 0
            segment.addAction(UIAction { [weak self, weak segment] _ in
                guard let self, let segment else { return }; self.model.settings.hand = HandMode.allCases[segment.selectedSegmentIndex]
                self.closePanel()
            }, for: .valueChanged)
            stack.addArrangedSubview(segment); stack.addArrangedSubview(note("缩窄键盘，保留系统按键顺序。长按空格拖动光标。"))
        case .appearance:
            let segment = UISegmentedControl(items: GlassPreset.allCases.map(\.title))
            segment.selectedSegmentIndex = GlassPreset.allCases.firstIndex(of: model.settings.glass) ?? 0
            segment.addAction(UIAction { [weak self, weak segment] _ in guard let segment else { return }; self?.model.settings.glass = GlassPreset.allCases[segment.selectedSegmentIndex] }, for: .valueChanged)
            stack.addArrangedSubview(segment)
            let slider = UISlider(); slider.minimumValue = 0.15; slider.maximumValue = 1; slider.value = Float(model.settings.glassOpacity)
            slider.accessibilityLabel = "玻璃遮罩浓度"
            slider.addAction(UIAction { [weak self, weak slider] _ in if let slider { self?.model.settings.glassOpacity = Double(slider.value) } }, for: .valueChanged)
            stack.addArrangedSubview(slider)
            let colors = UIStackView(); colors.axis = .horizontal; colors.distribution = .fillEqually
            for color in Accent.allCases { colors.addArrangedSubview(actionButton(color.title) { [weak self] in self?.model.settings.accent = color; self?.model.settings.customAccentHex = nil }) }
            stack.addArrangedSubview(colors)
            for (channel, name) in ["R", "G", "B"].enumerated() {
                let row = UIStackView(); row.axis = .horizontal; row.spacing = 8
                let label = note(name); label.widthAnchor.constraint(equalToConstant: 15).isActive = true; row.addArrangedSubview(label)
                let rgb = model.settings.accentRGB
                let slider = UISlider(); slider.minimumValue = 0; slider.maximumValue = 255; slider.tag = channel
                slider.value = Float([rgb.red, rgb.green, rgb.blue][channel] * 255); slider.accessibilityLabel = "自定义颜色 " + name
                slider.addAction(UIAction { [weak self, weak slider] _ in
                    guard let self, let slider else { return }
                    var color = self.model.settings.accentRGB
                    let value = Double(slider.value) / 255
                    if slider.tag == 0 { color.red = value } else if slider.tag == 1 { color.green = value } else { color.blue = value }
                    self.model.settings.customAccentHex = color.hex
                }, for: .valueChanged)
                row.addArrangedSubview(slider); stack.addArrangedSubview(row)
            }
            stack.addArrangedSubview(note("RGB 可选任意颜色；低电量或减少透明度时，自动切换轻量材质。"))
        case .language: break
        }
        setNeedsLayout()
    }
    private func actionButton(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system); button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        if let symbol { button.setImage(UIImage(systemName: symbol), for: .normal) }
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside); return button
    }
    private func note(_ text: String) -> UILabel {
        let label = UILabel(); label.text = text; label.numberOfLines = 0
        label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabel; return label
    }
    private func buildClipboard(_ stack: UIStackView) {
        guard model.document?.fullAccess == true else {
            stack.addArrangedSubview(note("在系统设置中为「澈」开启完全访问后，可手动读取剪贴板。输入和离线词库无需此权限。")); return
        }
        let store = ClipboardStore(url: SharedStorage.clipboardURL(allowShared: true)); clipboard = store
        store.prune(lifetime: model.settings.clipboardLifetimeHours * 3600)
        let commands = UIStackView(); commands.axis = .horizontal; commands.distribution = .fillEqually
        commands.addArrangedSubview(actionButton("读取系统剪贴板", symbol: "plus") { [weak self] in
            guard let self else { return }
            let text = UIPasteboard.general.string
            if let text { store.add(text) }
            self.panelKind = nil; self.showPanel(.clipboard)
            if text == nil { self.showStatus("剪贴板中没有可读取的文字") }
        })
        commands.addArrangedSubview(actionButton("清空") { [weak self] in store.clear(); self?.panelKind = nil; self?.showPanel(.clipboard) })
        stack.addArrangedSubview(commands)
        if store.clips.isEmpty { stack.addArrangedSubview(note("只保存你主动读取的内容；未固定项目按设置自动过期。")); return }
        let scroll = UIScrollView(); scroll.heightAnchor.constraint(equalToConstant: 126).isActive = true
        let list = UIStackView(); list.axis = .vertical; list.spacing = 4; list.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(list); stack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([list.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), list.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor), list.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), list.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor), list.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)])
        for clip in store.clips {
            let row = UIStackView(); row.axis = .horizontal; row.spacing = 6
            let paste = actionButton(String(clip.text.prefix(40))) { [weak self] in self?.model.insertLiteral(clip.text); self?.closePanel() }
            paste.contentHorizontalAlignment = .leading; paste.titleLabel?.lineBreakMode = .byTruncatingTail
            row.addArrangedSubview(paste)
            let pin = actionButton(clip.pinned ? "已固定" : "固定") { [weak self] in store.togglePin(clip.id); self?.panelKind = nil; self?.showPanel(.clipboard) }
            pin.widthAnchor.constraint(equalToConstant: 48).isActive = true; row.addArrangedSubview(pin)
            let delete = actionButton("", symbol: "trash") { [weak self] in store.delete(clip.id); self?.panelKind = nil; self?.showPanel(.clipboard) }
            delete.accessibilityLabel = "删除剪贴板项目"; delete.widthAnchor.constraint(equalToConstant: 34).isActive = true
            row.addArrangedSubview(delete); list.addArrangedSubview(row)
        }
    }
    private func buildEmoji(_ stack: UIStackView) {
        let groups = [["😀", "🥹", "🥰", "😎", "🥳", "😭", "🤔", "🫶"], ["👍", "🙏", "❤️", "✨", "🎉", "🌙", "☕️", "🌸"], ["(๑•̀ㅂ•́)و✧", "٩(ˊᗜˋ*)و", "(｡･ω･｡)", "晚安 🌙"]]
        for group in groups {
            let row = UIStackView(); row.axis = .horizontal; row.distribution = .fillEqually
            for emoji in group {
                let button = actionButton(emoji) { [weak self] in self?.model.insertLiteral(emoji) }
                button.titleLabel?.font = .systemFont(ofSize: emoji.count == 1 ? 26 : 11)
                row.addArrangedSubview(button)
            }
            stack.addArrangedSubview(row)
        }
        let stickers = UIStackView(); stickers.axis = .horizontal; stickers.distribution = .fillEqually
        for (title, emoji) in [("收到啦", "🫡"), ("好耶", "🎉"), ("谢谢", "🫶"), ("晚安", "🌙")] {
            stickers.addArrangedSubview(actionButton(title) { [weak self] in self?.copySticker(title, emoji: emoji) })
        }
        stack.addArrangedSubview(stickers)
        stack.addArrangedSubview(note("文字表情直接输入；文字贴纸点按复制，再到消息框粘贴。"))
    }
    private func copySticker(_ title: String, emoji: String) {
        guard model.document?.fullAccess == true else {
            showStatus("图片贴纸需要完全访问；文字表情可直接输入。")
            return
        }
        let color = model.settings.accentColor
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).image { context in
            let rect = CGRect(x: 8, y: 8, width: 284, height: 284)
            color.withAlphaComponent(0.16).setFill(); UIBezierPath(roundedRect: rect, cornerRadius: 64).fill()
            (emoji as NSString).draw(in: CGRect(x: 70, y: 30, width: 180, height: 160), withAttributes: [.font: UIFont.systemFont(ofSize: 120)])
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            (title as NSString).draw(in: CGRect(x: 20, y: 208, width: 260, height: 68), withAttributes: [.font: UIFont.systemFont(ofSize: 42, weight: .semibold), .foregroundColor: model.settings.accentInkColor, .paragraphStyle: paragraph])
            _ = context
        }
        if let data = image.pngData() { UIPasteboard.general.setItems([["public.png": data]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)]) }
        showStatus("贴纸已复制，请在消息框粘贴")
    }
}
