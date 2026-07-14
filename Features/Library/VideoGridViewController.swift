import AppKit

@MainActor
final class VideoGridViewController: NSViewController, NSCollectionViewDataSource {
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("VideoCollectionViewItem")

    private let collectionView = NSCollectionView()
    private let onChooseLibrary: () -> Void
    private let onRescan: () -> Void
    private var videos: [VideoRecord] = []
    private var hasLibrary = false

    private let libraryTitleLabel = NSTextField(labelWithString: "视频资料库")
    private let statusLabel = NSTextField(labelWithString: "尚未选择资料库")
    private let emptyState = NSStackView()
    private let emptyTitleLabel = NSTextField(labelWithString: "尚未选择视频资料库")
    private let emptyDetailLabel = NSTextField(wrappingLabelWithString: "选择一个本地目录，应用将建立只读索引。")
    private lazy var chooseLibraryButton = NSButton(
        title: "选择资料库…",
        target: self,
        action: #selector(chooseLibrary)
    )
    private lazy var headerChooseButton = NSButton(
        title: "更换资料库…",
        target: self,
        action: #selector(chooseLibrary)
    )
    private lazy var rescanButton = NSButton(
        title: "重新扫描",
        target: self,
        action: #selector(rescan)
    )

    init(onChooseLibrary: @escaping () -> Void, onRescan: @escaping () -> Void) {
        self.onChooseLibrary = onChooseLibrary
        self.onRescan = onRescan
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()

        libraryTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        rescanButton.isEnabled = false
        headerChooseButton.isHidden = true

        let titleStack = NSStackView(views: [libraryTitleLabel, statusLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        let header = NSStackView(views: [titleStack, NSView(), rescanButton, headerChooseButton])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 180, height: 150)
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 20
        layout.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(VideoCollectionViewItem.self, forItemWithIdentifier: Self.itemIdentifier)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = collectionView

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 10

        let icon = NSImageView(
            image: NSImage(systemSymbolName: "film.stack", accessibilityDescription: "视频") ?? NSImage()
        )
        icon.symbolConfiguration = .init(pointSize: 32, weight: .light)
        icon.contentTintColor = .secondaryLabelColor

        emptyTitleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        emptyDetailLabel.textColor = .secondaryLabelColor
        emptyDetailLabel.alignment = .center

        emptyState.addArrangedSubview(icon)
        emptyState.addArrangedSubview(emptyTitleLabel)
        emptyState.addArrangedSubview(emptyDetailLabel)
        emptyState.addArrangedSubview(chooseLibraryButton)

        container.addSubview(header)
        container.addSubview(scrollView)
        container.addSubview(emptyState)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
        view = container
        updateEmptyState()
    }

    func setLibrary(_ summary: LibrarySummary) {
        loadViewIfNeeded()
        hasLibrary = true
        libraryTitleLabel.stringValue = summary.name
        statusLabel.stringValue = "正在读取已有索引…"
        chooseLibraryButton.title = "更换资料库…"
        headerChooseButton.isHidden = false
        rescanButton.isEnabled = true
        updateEmptyState()
    }

    func setVideos(_ videos: [VideoRecord]) {
        loadViewIfNeeded()
        self.videos = videos
        collectionView.reloadData()
        updateEmptyState()
    }

    func setScanState(_ state: LibraryScanState) {
        loadViewIfNeeded()
        switch state {
        case .idle:
            statusLabel.stringValue = hasLibrary ? "等待扫描" : "尚未选择资料库"
            rescanButton.isEnabled = hasLibrary
        case .scanning:
            statusLabel.stringValue = videos.isEmpty ? "正在扫描视频…" : "正在后台更新索引…"
            rescanButton.isEnabled = false
        case let .completed(videoCount):
            statusLabel.stringValue = "共 \(videoCount) 个视频"
            rescanButton.isEnabled = true
        case let .failed(message):
            statusLabel.stringValue = message
            rescanButton.isEnabled = true
        }
        updateEmptyState()
    }

    func setError(_ message: String) {
        loadViewIfNeeded()
        hasLibrary = false
        videos = []
        collectionView.reloadData()
        libraryTitleLabel.stringValue = "资料库需要处理"
        statusLabel.stringValue = message
        emptyTitleLabel.stringValue = "无法访问视频资料库"
        emptyDetailLabel.stringValue = message
        chooseLibraryButton.title = "重新选择…"
        headerChooseButton.isHidden = true
        rescanButton.isEnabled = false
        updateEmptyState()
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        videos.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        guard let item = collectionView.makeItem(
            withIdentifier: Self.itemIdentifier,
            for: indexPath
        ) as? VideoCollectionViewItem else {
            return NSCollectionViewItem()
        }
        item.configure(with: videos[indexPath.item])
        return item
    }

    private func updateEmptyState() {
        emptyState.isHidden = videos.isEmpty == false
        if hasLibrary, videos.isEmpty {
            emptyTitleLabel.stringValue = "资料库中暂无视频"
            emptyDetailLabel.stringValue = "扫描会识别常见的本地视频格式。你可以随时重新扫描。"
        }
    }

    @objc private func chooseLibrary() {
        onChooseLibrary()
    }

    @objc private func rescan() {
        onRescan()
    }
}

@MainActor
private final class VideoCollectionViewItem: NSCollectionViewItem {
    private let iconView = NSImageView()
    private let filenameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8

        iconView.image = NSImage(systemSymbolName: "film", accessibilityDescription: "视频")
        iconView.symbolConfiguration = .init(pointSize: 34, weight: .light)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        filenameLabel.translatesAutoresizingMaskIntoConstraints = false
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        filenameLabel.alignment = .center
        filenameLabel.font = .systemFont(ofSize: 12, weight: .medium)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.font = .systemFont(ofSize: 11)

        container.addSubview(iconView)
        container.addSubview(filenameLabel)
        container.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),
            filenameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            filenameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            filenameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 14),
            detailLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            detailLabel.topAnchor.constraint(equalTo: filenameLabel.bottomAnchor, constant: 4),
        ])
        view = container
        updateSelectionAppearance()
    }

    func configure(with video: VideoRecord) {
        loadViewIfNeeded()
        filenameLabel.stringValue = video.filename
        detailLabel.stringValue = video.fileExtension.uppercased()
        view.toolTip = video.filename
    }

    private func updateSelectionAppearance() {
        view.layer?.backgroundColor = isSelected
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).cgColor
            : NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
    }
}
