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
    private let onImportDroppedItems: ([URL]) -> Void
    private let onRemoveVideos: ([String], @escaping (Bool) -> Void) -> Void
    private let onUndoLastMutation: () -> Void
    private let onDismissNotification: () -> Void
    var onViewRecentImports: (() -> Void)?
    private let importStatusView = ImportStatusView()
    private var importStatusHeightConstraint: NSLayoutConstraint?
    private var importState: LibraryImportState = .idle
    private var browsingContextRevision = 0
    private var videos: [VideoRecord] = []
    private var selectionAnchorVideoID: String?

    private let emptyState = NSStackView()
    private let emptyTitleLabel = NSTextField(labelWithString: String(localized: .importEmptyTitle))
    private let emptyDetailLabel = NSTextField(wrappingLabelWithString: String(localized: .importEmptyDetail))
    init(
        onOpenVideo: @escaping (VideoRecord) -> Void,
        onRevealVideo: @escaping (VideoRecord) -> Void,
        onCopyPath: @escaping (VideoRecord) -> Void,
        onPreviewVideos: @escaping ([VideoRecord]) -> Void,
        onSelectionChanged: @escaping ([VideoRecord]) -> Void,
        thumbnailURL: @escaping (VideoRecord) -> URL?,
        onAssignTagID: @escaping (String, [String]) -> Void,
        onCancelImport: @escaping () -> Void,
        onImportDroppedItems: @escaping ([URL]) -> Void,
        onRemoveVideos: @escaping ([String], @escaping (Bool) -> Void) -> Void,
        onUndoLastMutation: @escaping () -> Void,
        onDismissNotification: @escaping () -> Void
    ) {
        self.onOpenVideo = onOpenVideo
        self.onRevealVideo = onRevealVideo
        self.onCopyPath = onCopyPath
        self.onPreviewVideos = onPreviewVideos
        self.onSelectionChanged = onSelectionChanged
        self.thumbnailURL = thumbnailURL
        self.onAssignTagID = onAssignTagID
        self.onCancelImport = onCancelImport
        self.onImportDroppedItems = onImportDroppedItems
        self.onRemoveVideos = onRemoveVideos
        self.onUndoLastMutation = onUndoLastMutation
        self.onDismissNotification = onDismissNotification
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = VideoImportDropView()
        container.onImportDroppedItems = { [weak self] urls in
            self?.onImportDroppedItems(urls)
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
        collectionView.onRemoveSelection = { [weak self] in
            self?.requestRemoveSelectedVideos()
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
            image: NSImage(
                systemSymbolName: "film.stack",
                accessibilityDescription: String(localized: .accessibilityVideo)
            ) ?? NSImage()
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
        importStatusView.onDismiss = { [weak self] in self?.dismissNotification() }
        importStatusView.onView = { [weak self] in self?.onViewRecentImports?() }
        importStatusView.onUndo = { [weak self] in
            self?.onUndoLastMutation()
        }
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
        case let .importing(title, detail, progress):
            importStatusView.configureImporting(title: title, detail: detail, progress: progress)
            showImportStatus()
        case let .completed(summary):
            let foundNoVideos = hasViewableImportResult(summary) == false
            if foundNoVideos {
                let checkedDescription = summary.checkedFolderCount == summary.checkedInputCount
                    ? String(localized: .importCheckedFolderCount(summary.checkedInputCount))
                    : String(localized: .importCheckedItemCount(summary.checkedInputCount))
                importStatusView.configureFinished(
                    title: String(localized: .importNoVideosTitle),
                    detail: checkedDescription
                )
            } else {
                var resultParts = [
                    String(localized: .importResultAdded(summary.addedCount)),
                    String(localized: .importResultExisting(summary.existingCount)),
                ]
                if summary.createdFolderTagCount > 0 {
                    resultParts.append(
                        String(localized: .importResultFolderTagsCreated(summary.createdFolderTagCount))
                    )
                }
                if summary.failedVideoCount > 0 {
                    resultParts.append(String(localized: .importResultFailedVideo(summary.failedVideoCount)))
                }
                if summary.failedInputCount > 0 {
                    resultParts.append(String(localized: .importResultFailedInput(summary.failedInputCount)))
                }
                importStatusView.configureCompleted(
                    title: summary.title,
                    detail: AppLocalization.list(resultParts)
                )
            }
            showImportStatus()
        case .cancelled:
            importStatusView.configureFinished(
                title: String(localized: .importCancelledTitle),
                detail: String(localized: .importCancelledDetail)
            )
            showImportStatus()
        case let .failed(message):
            importStatusView.configureFinished(
                title: String(localized: .importFailedTitle),
                detail: message
            )
            showImportStatus()
        }
    }

    private func clearFinishedImportState() {
        guard case .importing = importState else {
            setImportState(.idle)
            return
        }
    }

    func endBrowsingContextNotificationLifecycle() {
        browsingContextRevision &+= 1
        clearFinishedImportState()
    }

    private func dismissNotification() {
        setImportState(.idle)
        onDismissNotification()
    }

    func offerVideoRemovalUndoForCurrentStatus() {
        importStatusView.configureUndoActionOnly()
    }

    func removeVideoRemovalUndoOffer() {
        switch importState {
        case .importing:
            importStatusView.configureCancelActionOnly()
        case let .completed(summary) where hasViewableImportResult(summary):
            importStatusView.configureViewActionOnly()
        case .idle, .completed, .cancelled, .failed:
            importStatusView.configureDismissActionOnly()
        }
    }

    private func hasViewableImportResult(_ summary: LibraryImportSummary) -> Bool {
        summary.addedCount > 0
            || summary.existingCount > 0
            || summary.failedVideoCount > 0
            || summary.failedInputCount > 0
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

    func showRestoredVideos(_ videoIDs: [String]) {
        setSelectedVideoIDs(videoIDs)
        importStatusView.configureFinished(
            title: String(localized: .importResultRestored(videoIDs.count)),
            detail: String(localized: .importResultRestoredDetail(videoIDs.count))
        )
        showImportStatus()
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
        emptyTitleLabel.stringValue = String(localized: .importEmptyTitle)
        emptyDetailLabel.stringValue = String(localized: .importEmptyDetail)
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
            title: String(localized: .videoActionOpen),
            action: #selector(openVideoFromContextMenu(_:)),
            video: video
        ))
        menu.addItem(makeContextMenuItem(
            title: String(localized: .videoActionReveal),
            action: #selector(revealVideoFromContextMenu(_:)),
            video: video
        ))
        menu.addItem(makeContextMenuItem(
            title: String(localized: .videoActionCopyPath),
            action: #selector(copyPathFromContextMenu(_:)),
            video: video
        ))
        menu.addItem(.separator())
        let selectedCount = collectionView.selectionIndexPaths.count
        let removeItem = NSMenuItem(
            title: selectedCount > 1
                ? String(localized: .videoRemoveMenuMultiple(selectedCount))
                : String(localized: .videoRemoveMenuSingle),
            action: #selector(removeVideosFromContextMenu(_:)),
            keyEquivalent: "\u{8}"
        )
        removeItem.keyEquivalentModifierMask = [.command]
        removeItem.target = self
        removeItem.isEnabled = selectedCount > 0
        menu.addItem(removeItem)
        return menu
    }

    private func requestRemoveSelectedVideos() {
        let selected = selectedVideos()
        guard selected.isEmpty == false, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = selected.count > 1
            ? String(localized: .videoRemoveTitleMultiple(selected.count))
            : String(localized: .videoRemoveTitleSingle)
        alert.informativeText = selected.count > 1
            ? String(localized: .videoRemoveDetailMultiple)
            : String(localized: .videoRemoveDetailSingle)
        alert.addButton(withTitle: String(localized: .actionRemove))
        alert.addButton(withTitle: String(localized: .actionCancel))
        alert.buttons.first?.hasDestructiveAction = true
        let videoIDs = selected.map(\.id)
        let removalContextRevision = browsingContextRevision
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.onRemoveVideos(videoIDs) { [weak self] succeeded in
                guard let self, succeeded else { return }
                guard browsingContextRevision == removalContextRevision else {
                    onDismissNotification()
                    return
                }
                self.importStatusView.configureUndo(
                    title: String(localized: .videoResultRemoved(videoIDs.count)),
                    detail: String(localized: .importResultOriginalRemains(videoIDs.count))
                )
                self.showImportStatus()
            }
        }
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

    @objc private func removeVideosFromContextMenu(_ sender: NSMenuItem) {
        requestRemoveSelectedVideos()
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
        case view
        case undo
    }

    var onCancel: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onView: (() -> Void)?
    var onUndo: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let actionButton = NSButton()
    private let closeButton = NSButton()
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

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: String(localized: .notificationDismiss)
        )
        closeButton.title = ""
        closeButton.imagePosition = .imageOnly
        closeButton.bezelStyle = .inline
        closeButton.controlSize = .small
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(dismissNotification)
        closeButton.toolTip = String(localized: .notificationDismiss)
        closeButton.setAccessibilityLabel(String(localized: .notificationDismiss))

        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        addSubview(copyStack)
        addSubview(progressIndicator)
        addSubview(actionButton)
        addSubview(closeButton)
        addSubview(separator)
        NSLayoutConstraint.activate([
            copyStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            copyStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressIndicator.leadingAnchor.constraint(greaterThanOrEqualTo: copyStack.trailingAnchor, constant: 14),
            progressIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 150),
            actionButton.leadingAnchor.constraint(equalTo: progressIndicator.trailingAnchor, constant: 12),
            actionButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 58),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
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

    func configureImporting(title: String, detail: String, progress: Double?) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        progressIndicator.isHidden = false
        if let progress {
            progressIndicator.stopAnimation(nil)
            progressIndicator.isIndeterminate = false
            progressIndicator.minValue = 0
            progressIndicator.maxValue = 1
            progressIndicator.doubleValue = min(1, max(0, progress))
        } else {
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
        }
        actionButton.title = String(localized: .actionCancel)
        actionMode = .cancel
        closeButton.isHidden = true
    }

    func configureFinished(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        actionButton.title = String(localized: .actionDone)
        actionMode = .dismiss
        closeButton.isHidden = false
    }

    func configureCompleted(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        actionButton.title = String(localized: .actionView)
        actionMode = .view
        closeButton.isHidden = false
    }

    func configureUndo(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        actionButton.title = String(localized: .actionUndo)
        actionMode = .undo
        closeButton.isHidden = false
    }

    func configureUndoActionOnly() {
        actionButton.title = String(localized: .actionUndoRemoval)
        actionMode = .undo
    }

    func configureCancelActionOnly() {
        actionButton.title = String(localized: .actionCancel)
        actionMode = .cancel
        closeButton.isHidden = true
    }

    func configureDismissActionOnly() {
        actionButton.title = String(localized: .actionDone)
        actionMode = .dismiss
    }

    func configureViewActionOnly() {
        actionButton.title = String(localized: .actionView)
        actionMode = .view
    }

    @objc private func performAction() {
        switch actionMode {
        case .cancel: onCancel?()
        case .dismiss: onDismiss?()
        case .view: onView?()
        case .undo: onUndo?()
        }
    }

    @objc private func dismissNotification() {
        onDismiss?()
    }
}

@MainActor
private final class VideoImportDropView: NSView {
    var onImportDroppedItems: (([URL]) -> Void)?
    private var cachedDraggingSequenceNumber: Int?
    private var cachedImportPlan: VideoImportPlan?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: importPlan(from: sender))
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: importPlan(from: sender))
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearCachedImportPlan()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let plan = importPlan(from: sender)
        clearCachedImportPlan()
        guard plan.acceptedRoots.isEmpty == false else { return false }
        onImportDroppedItems?(plan.acceptedRoots.map(\.url))
        return true
    }

    private func dragOperation(for plan: VideoImportPlan) -> NSDragOperation {
        plan.acceptedRoots.isEmpty ? [] : .copy
    }

    private func importPlan(from sender: NSDraggingInfo) -> VideoImportPlan {
        let sequenceNumber = sender.draggingSequenceNumber
        if cachedDraggingSequenceNumber == sequenceNumber, let cachedImportPlan {
            return cachedImportPlan
        }
        let plan = VideoFileDiscovery.importPlan(for: droppedURLs(from: sender))
        cachedDraggingSequenceNumber = sequenceNumber
        cachedImportPlan = plan
        return plan
    }

    private func clearCachedImportPlan() {
        cachedDraggingSequenceNumber = nil
        cachedImportPlan = nil
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
    var onRemoveSelection: (() -> Void)?

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
        let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let modifiers = event.modifierFlags.intersection(relevantModifiers)
        if event.keyCode == 51, modifiers == [.command] {
            onRemoveSelection?()
            return
        }
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
        thumbnailView.isOffline = video.availability == .offline
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
    private let offlineOverlayView = NSView()
    private let offlineBadgeView = NSView()
    private let offlineBadgeLabel = NSTextField(labelWithString: String(localized: .videoOfflineBadge))

    var image: NSImage? {
        didSet {
            placeholderView.isHidden = image != nil
            updateImageLayer()
        }
    }

    var isOffline = false {
        didSet {
            offlineOverlayView.isHidden = isOffline == false
            offlineBadgeView.isHidden = isOffline == false
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill

        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.image = NSImage(
            systemSymbolName: "film",
            accessibilityDescription: String(localized: .accessibilityVideo)
        )
        placeholderView.symbolConfiguration = .init(pointSize: 34, weight: .light)
        placeholderView.contentTintColor = .secondaryLabelColor
        placeholderView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(placeholderView)

        offlineOverlayView.translatesAutoresizingMaskIntoConstraints = false
        offlineOverlayView.wantsLayer = true
        offlineOverlayView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.50).cgColor
        offlineOverlayView.isHidden = true
        addSubview(offlineOverlayView)

        offlineBadgeView.translatesAutoresizingMaskIntoConstraints = false
        offlineBadgeView.wantsLayer = true
        offlineBadgeView.layer?.cornerRadius = 5
        offlineBadgeView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        offlineBadgeView.layer?.borderColor = NSColor.white.withAlphaComponent(0.42).cgColor
        offlineBadgeView.layer?.borderWidth = 1
        offlineBadgeView.isHidden = true
        offlineBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        offlineBadgeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        offlineBadgeLabel.textColor = .white
        offlineBadgeView.addSubview(offlineBadgeLabel)
        addSubview(offlineBadgeView)

        NSLayoutConstraint.activate([
            placeholderView.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderView.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholderView.widthAnchor.constraint(equalToConstant: 42),
            placeholderView.heightAnchor.constraint(equalToConstant: 42),
            offlineOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            offlineOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            offlineOverlayView.topAnchor.constraint(equalTo: topAnchor),
            offlineOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
            offlineBadgeView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            offlineBadgeView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            offlineBadgeLabel.leadingAnchor.constraint(equalTo: offlineBadgeView.leadingAnchor, constant: 6),
            offlineBadgeLabel.trailingAnchor.constraint(equalTo: offlineBadgeView.trailingAnchor, constant: -6),
            offlineBadgeLabel.topAnchor.constraint(equalTo: offlineBadgeView.topAnchor, constant: 2),
            offlineBadgeLabel.bottomAnchor.constraint(equalTo: offlineBadgeView.bottomAnchor, constant: -2),
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
