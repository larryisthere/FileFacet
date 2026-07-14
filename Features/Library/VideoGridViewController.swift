import AppKit

@MainActor
final class VideoGridViewController: NSViewController {
    private let collectionView = NSCollectionView()
    private let onChooseLibrary: () -> Void
    private let titleLabel = NSTextField(labelWithString: "尚未选择视频资料库")
    private let detailLabel = NSTextField(wrappingLabelWithString: "选择一个本地目录，应用将建立只读索引。")
    private lazy var chooseLibraryButton = NSButton(
        title: "选择资料库…",
        target: self,
        action: #selector(chooseLibrary)
    )

    init(onChooseLibrary: @escaping () -> Void) {
        self.onChooseLibrary = onChooseLibrary
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 180, height: 150)
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 20
        layout.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = collectionView

        let emptyState = NSStackView()
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 10

        let icon = NSImageView(image: NSImage(systemSymbolName: "film.stack", accessibilityDescription: "视频") ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 32, weight: .light)
        icon.contentTintColor = .secondaryLabelColor

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center

        emptyState.addArrangedSubview(icon)
        emptyState.addArrangedSubview(titleLabel)
        emptyState.addArrangedSubview(detailLabel)
        emptyState.addArrangedSubview(chooseLibraryButton)

        container.addSubview(scrollView)
        container.addSubview(emptyState)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        view = container
    }

    func setLibrary(_ summary: LibrarySummary) {
        loadViewIfNeeded()
        titleLabel.stringValue = summary.name
        detailLabel.stringValue = "资料库访问权限已保存，下一步将扫描其中的视频。"
        chooseLibraryButton.title = "更换资料库…"
    }

    func setError(_ message: String) {
        loadViewIfNeeded()
        titleLabel.stringValue = "资料库需要处理"
        detailLabel.stringValue = message
        chooseLibraryButton.title = "重新选择…"
    }

    @objc private func chooseLibrary() {
        onChooseLibrary()
    }
}
