import AppKit

@MainActor
final class VideoGridViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("VideoCollectionViewItem")
    private static let gridItemWidthDefaultsKey = "VideoGridItemWidth"
    static let defaultGridItemWidth = 180.0
    static let minimumGridItemWidth = 150.0
    static let maximumGridItemWidth = 280.0
    private static let thumbnailHeightRatio = 0.55
    private static let gridItemChromeHeight = 64.0

    private let collectionView = VideoCollectionView()
    private let scrollView = NSScrollView()
    private let onOpenVideo: (VideoRecord) -> Void
    private let onRevealVideo: (VideoRecord) -> Void
    private let onCopyPath: (VideoRecord) -> Void
    private let onPreviewVideos: ([VideoRecord]) -> Void
    var onSelectionChanged: ([VideoRecord]) -> Void
    private let thumbnailURL: (VideoRecord) -> URL?
    private let onAssignTagID: (String, [String]) -> Void
    private let onCancelImport: () -> Void
    private let onImportDroppedVideos: ([URL]) -> Void
    private let importStatusView = ImportStatusView()
    private var importStatusHeightConstraint: NSLayoutConstraint?
    private var importState: LibraryImportState = .idle
    private var videos: [VideoRecord] = []
    private var selectionAnchorVideoID: String?

    private let emptyState = NSStackView()
    private let emptyTitleLabel = NSTextField(labelWithString: "从菜单栏导入视频")
    private let emptyDetailLabel = NSTextField(wrappingLabelWithString: "选择“文件 > 导入视频…”或使用 ⇧⌘I，可继续从任意文件夹添加视频。")
    init(
        onOpenVideo: @escaping (VideoRecord) -> Void,
        onRevealVideo: @escaping (VideoRecord) -> Void,
        onCopyPath: @escaping (VideoRecord) -> Void,
        onPreviewVideos: @escaping ([VideoRecord]) -> Void,
        onSelectionChanged: @escaping ([VideoRecord]) -> Void,
        thumbnailURL: @escaping (VideoRecord) -> URL?,
        onAssignTagID: @escaping (String, [String]) -> Void,
        onCancelImport: @escaping () -> Void,
        onImportDroppedVideos: @escaping ([URL]) -> Void
    ) {
        self.onOpenVideo = onOpenVideo
        self.onRevealVideo = onRevealVideo
        self.onCopyPath = onCopyPath
        self.onPreviewVideos = onPreviewVideos
        self.onSelectionChanged = onSelectionChanged
        self.thumbnailURL = thumbnailURL
        self.onAssignTagID = onAssignTagID
        self.onCancelImport = onCancelImport
        self.onImportDroppedVideos = onImportDroppedVideos
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = VideoImportDropView()
        container.onImportDroppedVideos = { [weak self] urls in
            self?.onImportDroppedVideos(urls)
        }
        container.onRejectedDrop = { [weak self] in
            guard let self, case .importing = self.importState else {
                self?.setImportState(.failed(
                    message: "没有可导入的视频。请拖入 MOV、MP4、M4V、AVI、MKV 或 WebM 文件。"
                ))
                return
            }
        }

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = gridItemSize(for: Self.persistedGridItemWidth())
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 20
        layout.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(VideoCollectionViewItem.self, forItemWithIdentifier: Self.itemIdentifier)
        collectionView.registerForDraggedTypes([SidebarViewController.tagPasteboardType])
        collectionView.onDoubleClickItem = { [weak self] indexPath in
            self?.openVideo(at: indexPath)
        }
        collectionView.onContextMenuItem = { [weak self] indexPath in
            self?.contextMenu(for: indexPath)
        }
        collectionView.onPreviewSelection = { [weak self] in
            self?.previewSelection()
        }
        collectionView.onSelectionGesture = { [weak self] indexPath, modifiers in
            self?.handleSelectionGesture(at: indexPath, modifiers: modifiers) ?? false
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
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

        importStatusView.translatesAutoresizingMaskIntoConstraints = false
        importStatusView.onCancel = { [weak self] in self?.onCancelImport() }
        importStatusView.onDismiss = { [weak self] in self?.setImportState(.idle) }
        container.addSubview(scrollView)
        container.addSubview(emptyState)
        container.addSubview(importStatusView)
        let importStatusHeightConstraint = importStatusView.heightAnchor.constraint(equalToConstant: 0)
        self.importStatusHeightConstraint = importStatusHeightConstraint
        NSLayoutConstraint.activate([
            importStatusView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            importStatusView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            importStatusView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            importStatusHeightConstraint,
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: importStatusView.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -24),
            emptyState.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
        importStatusView.isHidden = true
        container.installDropOverlay()
        view = container
        updateEmptyState()
    }

    func setImportState(_ state: LibraryImportState) {
        loadViewIfNeeded()
        importState = state
        switch state {
        case .idle:
            importStatusView.isHidden = true
            importStatusHeightConstraint?.constant = 0
        case let .importing(title, detail):
            importStatusView.configureImporting(title: title, detail: detail)
            showImportStatus()
        case let .completed(addedCount, existingCount, failedCount):
            importStatusView.configureFinished(
                title: "已完成视频导入",
                detail: "新增 \(addedCount) 个 · 已存在 \(existingCount) 个 · 失败 \(failedCount) 个"
            )
            showImportStatus()
        case .cancelled:
            importStatusView.configureFinished(
                title: "已取消视频导入",
                detail: "已经完整加入的视频会保留。"
            )
            showImportStatus()
        case let .failed(message):
            importStatusView.configureFinished(title: "视频导入未完成", detail: message)
            showImportStatus()
        }
    }

    func clearFinishedImportState() {
        guard case .importing = importState else {
            setImportState(.idle)
            return
        }
    }

    private func showImportStatus() {
        importStatusView.isHidden = false
        importStatusHeightConstraint?.constant = 52
    }

    func setVideos(_ videos: [VideoRecord]) {
        loadViewIfNeeded()
        let selectedVideoIDs = Set(
            collectionView.selectionIndexPaths.compactMap { indexPath in
                self.videos.indices.contains(indexPath.item) ? self.videos[indexPath.item].id : nil
            }
        )
        self.videos = videos
        if let selectionAnchorVideoID,
           videos.contains(where: { $0.id == selectionAnchorVideoID }) == false {
            self.selectionAnchorVideoID = nil
        }
        collectionView.reloadData()
        collectionView.selectionIndexPaths = Set(
            videos.indices.compactMap { index in
                selectedVideoIDs.contains(videos[index].id) ? IndexPath(item: index, section: 0) : nil
            }
        )
        scrollView.hasVerticalScroller = videos.isEmpty == false
        updateEmptyState()
        notifySelectionChanged()
    }

    func updateVideo(_ video: VideoRecord) {
        guard let index = videos.firstIndex(where: { $0.id == video.id }) else { return }
        videos[index] = video
        collectionView.reloadItems(at: [IndexPath(item: index, section: 0)])
        notifySelectionChanged()
    }

    func selectedVideos() -> [VideoRecord] {
        collectionView.selectionIndexPaths
            .sorted()
            .compactMap { indexPath in videos.indices.contains(indexPath.item) ? videos[indexPath.item] : nil }
    }

    func setSelectedVideoIDs(_ videoIDs: [String], notify: Bool = true) {
        loadViewIfNeeded()
        let identifiers = Set(videoIDs)
        collectionView.selectionIndexPaths = Set(
            videos.indices.compactMap { index in
                identifiers.contains(videos[index].id) ? IndexPath(item: index, section: 0) : nil
            }
        )
        if notify { notifySelectionChanged() }
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
        let video = videos[indexPath.item]
        item.configure(with: video, thumbnailURL: thumbnailURL(video))
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        notifySelectionChanged()
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didDeselectItemsAt indexPaths: Set<IndexPath>
    ) {
        notifySelectionChanged()
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        let selectedIDs = collectionView.selectionIndexPaths.contains(indexPath)
            ? collectionView.selectionIndexPaths.sorted().map { videos[$0.item].id }
            : [videos[indexPath.item].id]
        let item = NSPasteboardItem()
        item.setString(selectedIDs.joined(separator: "\n"), forType: SidebarViewController.videoPasteboardType)
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        draggingInfo.draggingPasteboard.string(forType: SidebarViewController.tagPasteboardType) == nil ? [] : .copy
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard let tagID = draggingInfo.draggingPasteboard.string(forType: SidebarViewController.tagPasteboardType),
              videos.indices.contains(indexPath.item) else { return false }
        let videoIDs = collectionView.selectionIndexPaths.contains(indexPath)
            ? collectionView.selectionIndexPaths.sorted().map { videos[$0.item].id }
            : [videos[indexPath.item].id]
        onAssignTagID(tagID, videoIDs)
        return true
    }

    private func updateEmptyState() {
        emptyState.isHidden = videos.isEmpty == false
        emptyTitleLabel.stringValue = "从菜单栏导入视频"
        emptyDetailLabel.stringValue = "选择“文件 > 导入视频…”、使用 ⇧⌘I，或直接将视频拖到这里。"
    }

    private func openVideo(at indexPath: IndexPath) {
        guard videos.indices.contains(indexPath.item) else { return }
        onOpenVideo(videos[indexPath.item])
    }

    private func previewSelection() {
        let selectedVideos: [VideoRecord] = collectionView.selectionIndexPaths
            .sorted()
            .compactMap { indexPath -> VideoRecord? in
                guard videos.indices.contains(indexPath.item) else { return nil }
                let video = videos[indexPath.item]
                return video.availability == .available ? video : nil
            }
        guard selectedVideos.isEmpty == false else { return }
        onPreviewVideos(selectedVideos)
    }

    private func contextMenu(for indexPath: IndexPath) -> NSMenu? {
        guard videos.indices.contains(indexPath.item) else { return nil }
        selectionAnchorVideoID = videos[indexPath.item].id
        if collectionView.selectionIndexPaths.contains(indexPath) == false {
            collectionView.selectionIndexPaths = [indexPath]
            notifySelectionChanged()
        }

        let video = videos[indexPath.item]
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(makeContextMenuItem(
            title: "使用默认播放器打开",
            action: #selector(openVideoFromContextMenu(_:)),
            video: video
        ))
        menu.addItem(makeContextMenuItem(
            title: "在 Finder 中显示",
            action: #selector(revealVideoFromContextMenu(_:)),
            video: video
        ))
        menu.addItem(makeContextMenuItem(
            title: "复制完整路径",
            action: #selector(copyPathFromContextMenu(_:)),
            video: video
        ))
        return menu
    }

    private func handleSelectionGesture(
        at indexPath: IndexPath?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        guard let indexPath, videos.indices.contains(indexPath.item) else {
            if modifiers.contains(.shift) == false {
                selectionAnchorVideoID = nil
            }
            return false
        }

        guard modifiers.contains(.shift) else {
            selectionAnchorVideoID = videos[indexPath.item].id
            return false
        }

        let anchorIndex = selectionAnchorVideoID.flatMap { anchorID in
            videos.firstIndex(where: { $0.id == anchorID })
        } ?? indexPath.item
        selectionAnchorVideoID = videos[anchorIndex].id

        let lowerBound = min(anchorIndex, indexPath.item)
        let upperBound = max(anchorIndex, indexPath.item)
        let rangeSelection = Set(
            (lowerBound...upperBound).map { IndexPath(item: $0, section: 0) }
        )
        if modifiers.contains(.command) {
            collectionView.selectionIndexPaths.formUnion(rangeSelection)
        } else {
            collectionView.selectionIndexPaths = rangeSelection
        }
        notifySelectionChanged()
        return true
    }

    private func makeContextMenuItem(title: String, action: Selector, video: VideoRecord) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = video.id
        item.isEnabled = video.availability == .available
        return item
    }

    private func video(from menuItem: NSMenuItem) -> VideoRecord? {
        guard let videoID = menuItem.representedObject as? String else { return nil }
        return videos.first { $0.id == videoID }
    }

    @objc private func openVideoFromContextMenu(_ sender: NSMenuItem) {
        if let video = video(from: sender) { onOpenVideo(video) }
    }

    @objc private func revealVideoFromContextMenu(_ sender: NSMenuItem) {
        if let video = video(from: sender) { onRevealVideo(video) }
    }

    @objc private func copyPathFromContextMenu(_ sender: NSMenuItem) {
        if let video = video(from: sender) { onCopyPath(video) }
    }

    func setGridItemWidth(_ width: Double) {
        guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let clampedWidth = min(Self.maximumGridItemWidth, max(Self.minimumGridItemWidth, width))
        layout.itemSize = gridItemSize(for: clampedWidth)
        layout.invalidateLayout()
        UserDefaults.standard.set(clampedWidth, forKey: Self.gridItemWidthDefaultsKey)
    }

    static func persistedGridItemWidth(defaults: UserDefaults = .standard) -> Double {
        guard let storedWidth = defaults.object(forKey: gridItemWidthDefaultsKey) as? NSNumber else {
            return defaultGridItemWidth
        }
        return min(maximumGridItemWidth, max(minimumGridItemWidth, storedWidth.doubleValue))
    }

    private func gridItemSize(for width: Double) -> NSSize {
        NSSize(
            width: width,
            height: ceil(width * Self.thumbnailHeightRatio + Self.gridItemChromeHeight)
        )
    }

    private func notifySelectionChanged() {
        let selected = collectionView.selectionIndexPaths
            .sorted()
            .compactMap { indexPath in videos.indices.contains(indexPath.item) ? videos[indexPath.item] : nil }
        onSelectionChanged(selected)
    }
}

@MainActor
private final class ImportStatusView: NSView {
    private enum ActionMode {
        case cancel
        case dismiss
    }

    var onCancel: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let actionButton = NSButton()
    private var actionMode: ActionMode = .dismiss

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let copyStack = NSStackView(views: [titleLabel, detailLabel])
        copyStack.translatesAutoresizingMaskIntoConstraints = false
        copyStack.orientation = .vertical
        copyStack.alignment = .leading
        copyStack.spacing = 1

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.controlSize = .small
        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(performAction)

        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        addSubview(copyStack)
        addSubview(progressIndicator)
        addSubview(actionButton)
        addSubview(separator)
        NSLayoutConstraint.activate([
            copyStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            copyStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressIndicator.leadingAnchor.constraint(greaterThanOrEqualTo: copyStack.trailingAnchor, constant: 14),
            progressIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 150),
            actionButton.leadingAnchor.constraint(equalTo: progressIndicator.trailingAnchor, constant: 12),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 58),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    func configureImporting(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        actionButton.title = "取消"
        actionMode = .cancel
    }

    func configureFinished(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        actionButton.title = "完成"
        actionMode = .dismiss
    }

    @objc private func performAction() {
        switch actionMode {
        case .cancel: onCancel?()
        case .dismiss: onDismiss?()
        }
    }
}

@MainActor
private final class VideoImportDropView: NSView {
    var onImportDroppedVideos: (([URL]) -> Void)?
    var onRejectedDrop: (() -> Void)?

    private let overlay = NSView()
    private let borderLayer = CAShapeLayer()
    private let symbolLabel = NSTextField(labelWithString: "⇩")
    private let titleLabel = NSTextField(labelWithString: "松开以导入视频")
    private let detailLabel = NSTextField(wrappingLabelWithString: "视频将加入当前资料库，并在首次导入时迁移 Finder 标签。")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func installDropOverlay() {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 12
        overlay.layer?.addSublayer(borderLayer)
        overlay.isHidden = true

        symbolLabel.font = .systemFont(ofSize: 32, weight: .light)
        symbolLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.alignment = .center
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [symbolLabel, titleLabel, detailLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        overlay.addSubview(stack)
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            overlay.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 14),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
    }

    override func layout() {
        super.layout()
        borderLayer.frame = overlay.bounds
        borderLayer.path = CGPath(
            roundedRect: overlay.bounds.insetBy(dx: 1, dy: 1),
            cornerWidth: 12,
            cornerHeight: 12,
            transform: nil
        )
        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.lineWidth = 2
        borderLayer.lineDashPattern = [7, 5]
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateOverlay(for: droppedURLs(from: sender))
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateOverlay(for: droppedURLs(from: sender))
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        overlay.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let videoURLs = supportedVideoURLs(from: droppedURLs(from: sender))
        overlay.isHidden = true
        guard videoURLs.isEmpty == false else {
            onRejectedDrop?()
            return true
        }
        onImportDroppedVideos?(videoURLs)
        return true
    }

    private func updateOverlay(for urls: [URL]) -> NSDragOperation {
        let videoURLs = supportedVideoURLs(from: urls)
        let accepted = videoURLs.isEmpty == false
        overlay.isHidden = false
        symbolLabel.stringValue = accepted ? "⇩" : "⊘"
        titleLabel.stringValue = accepted
            ? "松开以导入 \(videoURLs.count) 个视频"
            : "没有可导入的视频"
        detailLabel.stringValue = accepted
            ? "视频将加入当前资料库，并在首次导入时迁移 Finder 标签。"
            : "请拖入 MOV、MP4、M4V、AVI、MKV 或 WebM 文件。"
        let color = accepted ? NSColor.controlAccentColor : NSColor.systemRed
        symbolLabel.textColor = color
        borderLayer.strokeColor = color.cgColor
        overlay.layer?.backgroundColor = color.withAlphaComponent(0.10).cgColor
        return accepted ? .copy : []
    }

    private func supportedVideoURLs(from urls: [URL]) -> [URL] {
        urls.filter { $0.hasDirectoryPath == false && VideoFileDiscovery.isSupportedVideoURL($0) }
    }

    private func droppedURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [NSURL]
        return objects?.map { $0 as URL } ?? []
    }
}

@MainActor
private final class VideoCollectionView: NSCollectionView {
    var onDoubleClickItem: ((IndexPath) -> Void)?
    var onContextMenuItem: ((IndexPath) -> NSMenu?)?
    var onPreviewSelection: (() -> Void)?
    var onSelectionGesture: ((IndexPath?, NSEvent.ModifierFlags) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: point)
        if onSelectionGesture?(indexPath, event.modifierFlags) == true {
            window?.makeFirstResponder(self)
            return
        }
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        guard let indexPath else { return }
        onDoubleClickItem?(indexPath)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        return onContextMenuItem?(indexPath)
    }

    override func keyDown(with event: NSEvent) {
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        if event.charactersIgnoringModifiers == " ",
           event.modifierFlags.intersection(disallowedModifiers).isEmpty {
            onPreviewSelection?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class VideoCollectionViewItem: NSCollectionViewItem {
    private let thumbnailView = VideoThumbnailView()
    private let filenameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var isHovered = false

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    override func loadView() {
        let container = VideoCollectionItemView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.onHoverChanged = { [weak self] isHovered in
            guard let self else { return }
            self.isHovered = isHovered
            self.updateSelectionAppearance()
        }

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        filenameLabel.translatesAutoresizingMaskIntoConstraints = false
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        filenameLabel.alignment = .center
        filenameLabel.font = .systemFont(ofSize: 12, weight: .medium)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.font = .systemFont(ofSize: 11)

        container.addSubview(thumbnailView)
        container.addSubview(filenameLabel)
        container.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            thumbnailView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            thumbnailView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            thumbnailView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            thumbnailView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            thumbnailView.heightAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.55),
            filenameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            filenameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            filenameLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 14),
            detailLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            detailLabel.topAnchor.constraint(equalTo: filenameLabel.bottomAnchor, constant: 4),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -8),
        ])
        view = container
        updateSelectionAppearance()
    }

    func configure(with video: VideoRecord, thumbnailURL: URL?) {
        loadViewIfNeeded()
        thumbnailView.image = thumbnailURL.flatMap(NSImage.init(contentsOf:))
        filenameLabel.stringValue = video.filename
        let duration = video.duration.map { formattedDuration($0) } ?? video.fileExtension.uppercased()
        detailLabel.stringValue = duration
        view.toolTip = video.filename
    }

    private func formattedDuration(_ duration: Double) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func updateSelectionAppearance() {
        let backgroundColor: NSColor
        if isSelected {
            backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18)
        } else if isHovered {
            backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
        } else {
            backgroundColor = .clear
        }
        view.layer?.backgroundColor = backgroundColor.cgColor
    }
}

@MainActor
private final class VideoThumbnailView: NSView {
    private let placeholderView = NSImageView()

    var image: NSImage? {
        didSet {
            placeholderView.isHidden = image != nil
            updateImageLayer()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill

        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.image = NSImage(systemSymbolName: "film", accessibilityDescription: "视频")
        placeholderView.symbolConfiguration = .init(pointSize: 34, weight: .light)
        placeholderView.contentTintColor = .secondaryLabelColor
        placeholderView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(placeholderView)
        NSLayoutConstraint.activate([
            placeholderView.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderView.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholderView.widthAnchor.constraint(equalToConstant: 42),
            placeholderView.heightAnchor.constraint(equalToConstant: 42),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func updateImageLayer() {
        guard let image else {
            layer?.contents = nil
            return
        }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        layer?.contents = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }
}

@MainActor
private final class VideoCollectionItemView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            onHoverChanged?(false)
        }
    }
}
