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
        onAssignTagID: @escaping (String, [String]) -> Void
    ) {
        self.onOpenVideo = onOpenVideo
        self.onRevealVideo = onRevealVideo
        self.onCopyPath = onCopyPath
        self.onPreviewVideos = onPreviewVideos
        self.onSelectionChanged = onSelectionChanged
        self.thumbnailURL = thumbnailURL
        self.onAssignTagID = onAssignTagID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()

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

        container.addSubview(scrollView)
        container.addSubview(emptyState)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -24),
            emptyState.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
        view = container
        updateEmptyState()
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
        emptyDetailLabel.stringValue = "选择“文件 > 导入视频…”或使用 ⇧⌘I，可继续从任意文件夹添加视频。"
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
