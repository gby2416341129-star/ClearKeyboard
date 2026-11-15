import UIKit

/// Decodes the unchanged, licensed source PNG once. Individual regions are
/// cropped on demand; absent official artwork stays a text code, never a fake icon.
@MainActor enum EmoticonImageProvider {
    private static let cache = NSCache<NSString, UIImage>()
    private static var sheet: UIImage?
    private static var attempted = false
    static func image(for entry: EmoticonEntry) -> UIImage? {
        guard let region = entry.sprite else { return nil }
        let key = entry.id as NSString
        if let image = cache.object(forKey: key) { return image }
        if !attempted {
            attempted = true
            if let url = EmoticonCatalog.shared.spriteURL() { sheet = UIImage(contentsOfFile: url.path) }
            cache.countLimit = 160
        }
        guard let cg = sheet?.cgImage,
              region.x + region.width <= cg.width, region.y + region.height <= cg.height,
              let crop = cg.cropping(to: CGRect(x: CGFloat(region.x), y: CGFloat(region.y), width: CGFloat(region.width), height: CGFloat(region.height))) else { return nil }
        let image = UIImage(cgImage: crop, scale: CGFloat(max(region.width, region.height)) / 28, orientation: .up)
        cache.setObject(image, forKey: key)
        return image
    }
}

/// A finite grouped/pageable catalog. Selection returns exact insertion text to
/// the owner; UIKit cannot inject an app-private WeChat sticker/message object.
@MainActor final class EmoticonPanel: UIView {
    var onSelect: ((EmoticonEntry) -> Void)?
    private let catalog: EmoticonCatalog
    private let groupScroll = UIScrollView()
    private let groupStack = UIStackView()
    private let grid = UIStackView()
    private let navigation = UIStackView()
    private let previous = UIButton(type: .system)
    private let nextPageButton = UIButton(type: .system)
    private let pageLabel = UILabel()
    private let hint = UILabel()
    private var groupID: String
    private var query = ""
    private var page = 0
    private let pageSize = 21
    private var groupButtons: [String: UIButton] = [:]

    init(catalog: EmoticonCatalog = .shared, onSelect: @escaping (EmoticonEntry) -> Void) {
        self.catalog = catalog
        self.onSelect = onSelect
        groupID = catalog.groups.first?.id ?? "wechat-face"
        super.init(frame: .zero)
        accessibilityIdentifier = "emoticons.panel"
        groupScroll.showsHorizontalScrollIndicator = false
        groupStack.axis = .horizontal; groupStack.spacing = 6
        groupScroll.addSubview(groupStack)
        groupStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            groupStack.leadingAnchor.constraint(equalTo: groupScroll.contentLayoutGuide.leadingAnchor),
            groupStack.trailingAnchor.constraint(equalTo: groupScroll.contentLayoutGuide.trailingAnchor),
            groupStack.topAnchor.constraint(equalTo: groupScroll.contentLayoutGuide.topAnchor),
            groupStack.bottomAnchor.constraint(equalTo: groupScroll.contentLayoutGuide.bottomAnchor),
            groupStack.heightAnchor.constraint(equalTo: groupScroll.frameLayoutGuide.heightAnchor)
        ])
        for group in catalog.groups {
            let button = UIButton(type: .system)
            button.setTitle(group.title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
            button.contentEdgeInsets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
            button.layer.cornerRadius = 10
            button.accessibilityIdentifier = "emoticons.group.\(group.id)"
            button.addAction(UIAction { [weak self] _ in self?.selectGroup(group.id) }, for: .touchUpInside)
            groupButtons[group.id] = button
            groupStack.addArrangedSubview(button)
        }
        grid.axis = .vertical; grid.distribution = .fillEqually; grid.spacing = 3
        navigation.axis = .horizontal; navigation.spacing = 6
        previous.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        nextPageButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        previous.accessibilityLabel = "上一页表情"; nextPageButton.accessibilityLabel = "下一页表情"
        previous.accessibilityIdentifier = "emoticons.previous"; nextPageButton.accessibilityIdentifier = "emoticons.next"
        previous.addAction(UIAction { [weak self] _ in self?.changePage(-1) }, for: .touchUpInside)
        nextPageButton.addAction(UIAction { [weak self] _ in self?.changePage(1) }, for: .touchUpInside)
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        pageLabel.textAlignment = .center; pageLabel.textColor = .secondaryLabel
        navigation.addArrangedSubview(previous); navigation.addArrangedSubview(pageLabel); navigation.addArrangedSubview(nextPageButton)
        previous.widthAnchor.constraint(equalToConstant: 44).isActive = true
        nextPageButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabel
        hint.numberOfLines = 2; hint.textAlignment = .center
        let vertical = UIStackView(arrangedSubviews: [groupScroll, grid, navigation, hint])
        vertical.axis = .vertical; vertical.spacing = 4
        addSubview(vertical); vertical.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vertical.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            vertical.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            vertical.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            vertical.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            groupScroll.heightAnchor.constraint(equalToConstant: 32),
            navigation.heightAnchor.constraint(equalToConstant: 28),
            hint.heightAnchor.constraint(equalToConstant: 24)
        ])
        let left = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:))); left.direction = .left
        let right = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:))); right.direction = .right
        grid.addGestureRecognizer(left); grid.addGestureRecognizer(right)
        renderPage()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 220) }

    /// The owner may pass existing composition text; this panel does not focus a
    /// nested text field or request another keyboard inside the keyboard extension.
    func setQuery(_ query: String) {
        guard self.query != query else { return }
        self.query = query; page = 0; renderPage()
    }
    private func selectGroup(_ id: String) { groupID = id; page = 0; query = ""; renderPage() }
    private func changePage(_ offset: Int) {
        let count = visibleEntries.count
        let pages = max(1, (count + pageSize - 1) / pageSize)
        page = min(max(0, page + offset), pages - 1)
        renderPage()
    }
    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) { changePage(gesture.direction == .left ? 1 : -1) }
    private var visibleEntries: [EmoticonEntry] {
        query.isEmpty ? catalog.entries(in: groupID) : catalog.search(query)
    }
    private func renderPage() {
        let items = visibleEntries
        let pages = max(1, (items.count + pageSize - 1) / pageSize)
        page = min(page, pages - 1)
        for (id, button) in groupButtons {
            let selected = query.isEmpty && id == groupID
            button.backgroundColor = selected ? UIColor.label.withAlphaComponent(0.09) : .clear
            button.setTitleColor(selected ? .label : .secondaryLabel, for: .normal)
            button.accessibilityTraits = selected ? [.button, .selected] : [.button]
        }
        for view in grid.arrangedSubviews { grid.removeArrangedSubview(view); view.removeFromSuperview() }
        for rowIndex in 0..<3 {
            let row = UIStackView(); row.axis = .horizontal; row.distribution = .fillEqually; row.spacing = 3
            for column in 0..<7 {
                let index = page * pageSize + rowIndex * 7 + column
                if index < items.count { row.addArrangedSubview(makeButton(items[index])) }
                else { row.addArrangedSubview(UIView()) }
            }
            grid.addArrangedSubview(row)
        }
        pageLabel.text = items.isEmpty ? "没有匹配的表情" : "\(page + 1) / \(pages) · \(items.count)"
        previous.isEnabled = page > 0; nextPageButton.isEnabled = page + 1 < pages
        hint.text = items.contains(where: { $0.kind == .wechat })
            ? "点选插入微信表情代码，其他 App 可能显示文字。"
            : "点选输入 Emoji 或颜文字。"
    }
    private func makeButton(_ entry: EmoticonEntry) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 1, bottom: 2, trailing: 1)
        if let image = EmoticonImageProvider.image(for: entry) {
            configuration.image = image.withRenderingMode(.alwaysOriginal)
            configuration.imagePlacement = .top
        } else {
            configuration.title = entry.kind == .wechat ? entry.name : entry.code
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes
                result.font = .systemFont(ofSize: entry.kind == .emoji ? 24 : entry.kind == .kaomoji ? 9 : 11)
                return result
            }
        }
        button.configuration = configuration
        button.imageView?.contentMode = .scaleAspectFit
        button.titleLabel?.numberOfLines = entry.kind == .kaomoji ? 3 : 2
        button.titleLabel?.lineBreakMode = .byCharWrapping
        button.accessibilityLabel = entry.name
        button.accessibilityHint = entry.kind == .wechat ? "输入\(entry.code)" : "输入表情"
        button.accessibilityIdentifier = "emoticons.entry.\(entry.id)"
        button.addAction(UIAction { [weak self] _ in self?.onSelect?(entry) }, for: .touchUpInside)
        return button
    }
}

