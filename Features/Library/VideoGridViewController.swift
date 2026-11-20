import AppKit
import ImageIO
import QuartzCore

enum VideoGroupingKey: String, CaseIterable, Sendable {
    case none
    case addedDate
    case createdDate
    case modifiedDate
    case duration
    case fileSize
    case resolution
}

enum VideoGroupingDirection: String, CaseIterable, Sendable {
    case ascending
    case descending
}

struct VideoGroupingPreference: Equatable, Sendable {
    private static let keyDefaultsKey = "VideoGroupingKey"
    private static let directionDefaultsKey = "VideoGroupingDirection"

    var key: VideoGroupingKey
    var direction: VideoGroupingDirection

    static let standard = VideoGroupingPreference(key: .none, direction: .descending)

    static func persisted(defaults: UserDefaults = .standard) -> VideoGroupingPreference {
        let key = defaults.string(forKey: keyDefaultsKey)
            .flatMap(VideoGroupingKey.init(rawValue:)) ?? .none
        let direction = defaults.string(forKey: directionDefaultsKey)
            .flatMap(VideoGroupingDirection.init(rawValue:)) ?? .descending
        return VideoGroupingPreference(key: key, direction: direction)
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(key.rawValue, forKey: Self.keyDefaultsKey)
        defaults.set(direction.rawValue, forKey: Self.directionDefaultsKey)
    }
}

struct VideoRevealRequest: Equatable, Sendable {
    let videoIDs: [String]
    let destination: LibraryFilter

    init(videoIDs: [String], destination: LibraryFilter) {
        var seen = Set<String>()
        self.videoIDs = videoIDs.filter { seen.insert($0).inserted }
        self.destination = destination
    }
}

@MainActor
final class VideoGridViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("VideoCollectionViewItem")
    private static let groupHeaderIdentifier = NSUserInterfaceItemIdentifier("VideoGroupHeaderView")
    private static let gridItemWidthDefaultsKey = "VideoGridItemWidth"
    static let defaultGridItemWidth = 180.0
    static let minimumGridItemWidth = 150.0
    static let maximumGridItemWidth = 280.0
    private static let thumbnailHeightRatio = 0.55
    private static let gridItemChromeHeight = 64.0

    private struct GroupSection {
        let id: String
        let title: String?
        var videos: [VideoRecord]
    }

    private struct GroupBucket {
        let id: String
        let title: String
        let rank: Int
        let isUnknown: Bool
    }

    private enum SelectionGestureMode {
        case replacing
        case extending
    }

    private let collectionView = VideoCollectionView()
    private let scrollView = NSScrollView()
    private let onOpenVideo: (VideoRecord) -> Void
    private let onRevealVideo: (VideoRecord) -> Void
    private let onCopyPath: (VideoRecord) -> Void
    private let onRelinkVideo: (VideoRecord) -> Void
    private let onRetryRelinkVideo: (String) -> Void
    private let onPreviewVideos: ([VideoRecord]) -> Void
    var onSelectionChanged: ([VideoRecord]) -> Void
    private let thumbnailURL: (VideoRecord) -> URL?
    private let onAssignTagID: (String, [String]) -> Void
    private let onCancelImport: () -> Void
    private let onImportDroppedItems: ([URL]) -> Void
    private let onRemoveVideos: ([String], @escaping (Bool) -> Void) -> Void
    private let onUndoLastMutation: () -> Void
    private let onDismissNotification: () -> Void
    var onViewVideos: ((VideoRevealRequest) -> Void)?
    private let importStatusView = ImportStatusView()
    private var importStatusHeightConstraint: NSLayoutConstraint?
    private var importState: LibraryImportState = .idle
    private var operationStatus: LibraryOperationStatus?
    private var relinkingVideoID: String?
    private var relinkBrowsingContextRevision: Int?
    private var browsingContextRevision = 0
    private var videos: [VideoRecord] = []
    private var sections: [GroupSection] = []
    private var grouping = VideoGroupingPreference.standard
    private var collapsedGroupIDs = Set<String>()
    private var selectedVideoIDs = Set<String>()
    private var selectionAnchorVideoID: String?
    private var selectionGestureMode: SelectionGestureMode = .replacing
    private var isSynchronizingSelection = false

    private let emptyState = NSStackView()
    private let emptyTitleLabel = NSTextField(labelWithString: String(localized: .importEmptyTitle))
    private let emptyDetailLabel = NSTextField(wrappingLabelWithString: String(localized: .importEmptyDetail))
    init(
        onOpenVideo: @escaping (VideoRecord) -> Void,
        onRevealVideo: @escaping (VideoRecord) -> Void,
        onCopyPath: @escaping (VideoRecord) -> Void,
        onRelinkVideo: @escaping (VideoRecord) -> Void,
        onRetryRelinkVideo: @escaping (String) -> Void,
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
        self.onRelinkVideo = onRelinkVideo
        self.onRetryRelinkVideo = onRetryRelinkVideo
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
        collectionView.register(
            VideoGroupHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: Self.groupHeaderIdentifier
        )
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
        importStatusView.onView = { [weak self] in self?.viewVideosForCurrentStatus() }
        importStatusView.onUndo = { [weak self] in
            self?.onUndoLastMutation()
        }
        importStatusView.onRetry = { [weak self] in
            guard let self,
                  case let .relinkFailed(videoID, _) = operationStatus else { return }
            onRetryRelinkVideo(videoID)
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
        rebuildSections()
        updateEmptyState()
    }

    func setGrouping(_ preference: VideoGroupingPreference) {
        loadViewIfNeeded()
        guard grouping != preference else { return }
        let wasGrouped = grouping.key != .none
        grouping = preference
        collapsedGroupIDs.removeAll()
        rebuildSections()
        reloadCollectionDataPreservingSelection()

        if preference.key == .none, wasGrouped,
           let selectedID = videos.first(where: { selectedVideoIDs.contains($0.id) })?.id,
           let selectedIndexPath = indexPath(forVideoID: selectedID) {
            collectionView.scrollToItems(at: [selectedIndexPath], scrollPosition: .nearestVerticalEdge)
        } else {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func rebuildSections() {
        guard grouping.key != .none else {
            sections = [GroupSection(id: "all", title: nil, videos: videos)]
            collapsedGroupIDs.removeAll()
            updateCollectionLayoutForGrouping()
            return
        }

        var buckets: [String: (bucket: GroupBucket, videos: [VideoRecord])] = [:]
        for video in videos {
            let bucket = groupBucket(for: video)
            buckets[bucket.id, default: (bucket, [])].videos.append(video)
        }
        sections = buckets.values
            .sorted { left, right in
                if left.bucket.isUnknown != right.bucket.isUnknown {
                    return right.bucket.isUnknown
                }
                if grouping.direction == .descending {
                    return left.bucket.rank > right.bucket.rank
                }
                return left.bucket.rank < right.bucket.rank
            }
            .map { value in
                GroupSection(
                    id: "\(grouping.key.rawValue).\(value.bucket.id)",
                    title: value.bucket.title,
                    videos: value.videos
                )
            }
        collapsedGroupIDs.formIntersection(sections.map(\.id))
        updateCollectionLayoutForGrouping()
    }

    private func groupBucket(for video: VideoRecord) -> GroupBucket {
        switch grouping.key {
        case .none:
            return GroupBucket(id: "all", title: "", rank: 0, isUnknown: false)
        case .addedDate:
            return dateBucket(for: video.firstIndexedAt)
        case .createdDate:
            return dateBucket(for: video.creationDate)
        case .modifiedDate:
            return dateBucket(for: video.modificationDate)
        case .duration:
            guard let duration = video.duration, duration.isFinite, duration > 0 else {
                return unknownBucket(
                    id: "duration-unknown",
                    title: String(localized: "grouping.section.durationUnknown", defaultValue: "Duration Unknown")
                )
            }
            if duration < 60 {
                return GroupBucket(
                    id: "duration-under-1",
                    title: String(localized: "grouping.section.durationUnder1", defaultValue: "Under 1 Minute"),
                    rank: 0,
                    isUnknown: false
                )
            }
            if duration < 180 {
                return GroupBucket(
                    id: "duration-1-3",
                    title: String(localized: "grouping.section.duration1To3", defaultValue: "1–3 Minutes"),
                    rank: 1,
                    isUnknown: false
                )
            }
            return GroupBucket(
                id: "duration-over-3",
                title: String(localized: "grouping.section.durationOver3", defaultValue: "3 Minutes or More"),
                rank: 2,
                isUnknown: false
            )
        case .fileSize:
            guard video.fileSize > 0 else {
                return unknownBucket(
                    id: "size-unknown",
                    title: String(localized: "grouping.section.sizeUnknown", defaultValue: "Size Unknown")
                )
            }
            let gigabyte = Int64(1_000_000_000)
            if video.fileSize < gigabyte {
                return GroupBucket(
                    id: "size-under-1",
                    title: String(localized: "grouping.section.sizeUnder1GB", defaultValue: "Under 1 GB"),
                    rank: 0,
                    isUnknown: false
                )
            }
            if video.fileSize < gigabyte * 2 {
                return GroupBucket(
                    id: "size-1-2",
                    title: String(localized: "grouping.section.size1To2GB", defaultValue: "1–2 GB"),
                    rank: 1,
                    isUnknown: false
                )
            }
            return GroupBucket(
                id: "size-over-2",
                title: String(localized: "grouping.section.sizeOver2GB", defaultValue: "2 GB or More"),
                rank: 2,
                isUnknown: false
            )
        case .resolution:
            guard let width = video.width, width > 0 else {
                return unknownBucket(
                    id: "resolution-unknown",
                    title: String(localized: "grouping.section.resolutionUnknown", defaultValue: "Resolution Unknown")
                )
            }
            if width >= 3840 {
                return GroupBucket(
                    id: "resolution-4k",
                    title: String(localized: "grouping.section.resolution4K", defaultValue: "4K or Higher"),
                    rank: 2,
                    isUnknown: false
                )
            }
            if width >= 1920 {
                return GroupBucket(
                    id: "resolution-full-hd",
                    title: String(localized: "grouping.section.resolutionFullHD", defaultValue: "Full HD"),
                    rank: 1,
                    isUnknown: false
                )
            }
            return GroupBucket(
                id: "resolution-720",
                title: String(localized: "grouping.section.resolution720", defaultValue: "720p or Lower"),
                rank: 0,
                isUnknown: false
            )
        }
    }

    private func dateBucket(for date: Date?) -> GroupBucket {
        guard let date else {
            return unknownBucket(
                id: "date-unknown",
                title: String(localized: "grouping.section.dateUnknown", defaultValue: "Date Unknown")
            )
        }
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let valueDay = calendar.startOfDay(for: date)
        let elapsedDays = max(0, calendar.dateComponents([.day], from: valueDay, to: today).day ?? 0)
        if elapsedDays == 0 {
            return GroupBucket(
                id: "today",
                title: String(localized: "grouping.section.today", defaultValue: "Today"),
                rank: 3,
                isUnknown: false
            )
        }
        if elapsedDays <= 7 {
            return GroupBucket(
                id: "last-7-days",
                title: String(localized: "grouping.section.last7Days", defaultValue: "Last 7 Days"),
                rank: 2,
                isUnknown: false
            )
        }
        if elapsedDays <= 30 {
            return GroupBucket(
                id: "last-30-days",
                title: String(localized: "grouping.section.last30Days", defaultValue: "Last 30 Days"),
                rank: 1,
                isUnknown: false
            )
        }
        return GroupBucket(
            id: "older",
            title: String(localized: "grouping.section.older", defaultValue: "Older"),
            rank: 0,
            isUnknown: false
        )
    }

    private func unknownBucket(id: String, title: String) -> GroupBucket {
        GroupBucket(id: id, title: title, rank: Int.min, isUnknown: true)
    }

    private func updateCollectionLayoutForGrouping() {
        guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let isGrouped = grouping.key != .none
        layout.headerReferenceSize = isGrouped ? NSSize(width: 0, height: 34) : .zero
        layout.sectionHeadersPinToVisibleBounds = isGrouped
        layout.sectionInset = NSEdgeInsets(
            top: isGrouped ? 8 : 20,
            left: 20,
            bottom: 20,
            right: 20
        )
        layout.invalidateLayout()
    }

    private func toggleGroup(_ groupID: String) {
        if collapsedGroupIDs.contains(groupID) {
            collapsedGroupIDs.remove(groupID)
        } else {
            collapsedGroupIDs.insert(groupID)
        }
        reloadCollectionDataPreservingSelection()
        notifySelectionChanged()
    }

    private func video(at indexPath: IndexPath) -> VideoRecord? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].videos.indices.contains(indexPath.item),
              collapsedGroupIDs.contains(sections[indexPath.section].id) == false else {
            return nil
        }
        return sections[indexPath.section].videos[indexPath.item]
    }

    private func indexPath(forVideoID videoID: String) -> IndexPath? {
        for (sectionIndex, section) in sections.enumerated() where collapsedGroupIDs.contains(section.id) == false {
            if let itemIndex = section.videos.firstIndex(where: { $0.id == videoID }) {
                return IndexPath(item: itemIndex, section: sectionIndex)
            }
        }
        return nil
    }

    private func visibleItemIndexPaths() -> [IndexPath] {
        var indexPaths: [IndexPath] = []
        for (sectionIndex, section) in sections.enumerated()
            where collapsedGroupIDs.contains(section.id) == false {
            indexPaths.append(contentsOf: section.videos.indices.map {
                IndexPath(item: $0, section: sectionIndex)
            })
        }
        return indexPaths
    }

    private func syncCollectionSelectionFromIDs() {
        isSynchronizingSelection = true
        collectionView.selectionIndexPaths = Set(selectedVideoIDs.compactMap(indexPath(forVideoID:)))
        isSynchronizingSelection = false
    }

    private func reloadCollectionDataPreservingSelection() {
        isSynchronizingSelection = true
        collectionView.reloadData()
        collectionView.selectionIndexPaths = Set(selectedVideoIDs.compactMap(indexPath(forVideoID:)))
        isSynchronizingSelection = false
    }

    func setImportState(_ state: LibraryImportState) {
        loadViewIfNeeded()
        importState = state
        guard operationStatus == nil else { return }
        renderImportState(state)
    }

    private func renderImportState(_ state: LibraryImportState) {
        switch state {
        case .idle:
            importStatusView.isHidden = true
            importStatusHeightConstraint?.constant = 0
        case let .importing(title, detail, progress):
            importStatusView.configureImporting(title: title, detail: detail, progress: progress)
            showImportStatus()
        case let .completed(summary):
            let hasReportedResult = summary.addedCount > 0
                || summary.existingCount > 0
                || summary.failedVideoCount > 0
                || summary.failedInputCount > 0
            if hasReportedResult == false {
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
                let resultDetail = AppLocalization.list(resultParts)
                if hasViewableImportResult(summary) {
                    importStatusView.configureCompleted(title: summary.title, detail: resultDetail)
                } else {
                    importStatusView.configureFinished(title: summary.title, detail: resultDetail)
                }
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

    func setOperationStatus(_ status: LibraryOperationStatus?) {
        loadViewIfNeeded()
        if status != nil,
           relinkBrowsingContextRevision != browsingContextRevision {
            return
        }
        operationStatus = status
        guard let status else {
            renderImportState(importState)
            return
        }
        importState = .idle
        switch status {
        case let .relinkSucceeded(filename):
            importStatusView.configurePassive(
                title: String(
                    localized: "unavailable.relink.succeeded",
                    defaultValue: "Relinked"
                ),
                detail: String(
                    format: String(
                        localized: "unavailable.relink.succeeded.detail",
                        defaultValue: "“%@” is accessible again"
                    ),
                    filename
                )
            )
        case .relinkExisting:
            importStatusView.configureViewExisting(
                title: String(
                    localized: "unavailable.relink.existing.title",
                    defaultValue: "The selected file already exists in FileFacet"
                ),
                detail: String(
                    localized: "unavailable.relink.existing.detail",
                    defaultValue: "The current unavailable record was not changed."
                ),
                actionTitle: String(
                    localized: "unavailable.relink.existing.view",
                    defaultValue: "View Existing Video"
                )
            )
        case let .relinkFailed(_, message):
            importStatusView.configureRetry(
                title: String(
                    localized: "unavailable.relink.failed",
                    defaultValue: "Could Not Relink Original"
                ),
                detail: message,
                actionTitle: String(localized: "action.retry", defaultValue: "Retry")
            )
        }
        showImportStatus()
    }

    func setRelinkingVideoID(_ videoID: String?) {
        relinkingVideoID = videoID
        if videoID != nil {
            relinkBrowsingContextRevision = browsingContextRevision
        } else {
            relinkBrowsingContextRevision = nil
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
        operationStatus = nil
        clearFinishedImportState()
    }

    private func dismissNotification() {
        if operationStatus != nil {
            operationStatus = nil
            renderImportState(importState)
            return
        }
        setImportState(.idle)
        onDismissNotification()
    }

    func offerVideoRemovalUndoForCurrentStatus() {
        importStatusView.configureUndoActionOnly()
    }

    func showVideoRemovalUndo(videoCount: Int) {
        importStatusView.configureUndo(
            title: String(localized: .videoResultRemoved(videoCount)),
            detail: String(localized: .importResultOriginalRemains(videoCount))
        )
        showImportStatus()
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
        summary.addedVideoIDs.isEmpty == false || summary.existingVideoIDs.isEmpty == false
    }

    private func viewVideosForCurrentStatus() {
        let request: VideoRevealRequest?
        if case let .relinkExisting(existingVideoID, isUnavailable) = operationStatus {
            request = VideoRevealRequest(
                videoIDs: [existingVideoID],
                destination: isUnavailable ? .unavailable : .all
            )
        } else if case let .completed(summary) = importState {
            if summary.existingVideoIDs.isEmpty {
                request = VideoRevealRequest(videoIDs: summary.addedVideoIDs, destination: .recent)
            } else {
                request = VideoRevealRequest(
                    videoIDs: summary.addedVideoIDs + summary.existingVideoIDs,
                    destination: .all
                )
            }
        } else {
            request = nil
        }
        guard let request, request.videoIDs.isEmpty == false else { return }
        onViewVideos?(request)
    }

    private func showImportStatus() {
        importStatusView.isHidden = false
        importStatusHeightConstraint?.constant = 52
    }

    func setVideos(_ videos: [VideoRecord], resetBrowsingState: Bool = false) {
        loadViewIfNeeded()
        if !resetBrowsingState, self.videos.map(\.id) == videos.map(\.id),
           zip(self.videos, videos).allSatisfy({ groupBucket(for: $0.0).id == groupBucket(for: $0.1).id }) {
            for video in videos { updateVideo(video, refreshThumbnail: false) }
            return
        }
        selectedVideoIDs = resetBrowsingState ? [] : selectedVideoIDs.intersection(videos.map(\.id))
        self.videos = videos
        if resetBrowsingState {
            selectionAnchorVideoID = nil
            collapsedGroupIDs.removeAll()
        } else if let selectionAnchorVideoID,
           videos.contains(where: { $0.id == selectionAnchorVideoID }) == false {
            self.selectionAnchorVideoID = nil
        }
        rebuildSections()
        reloadCollectionDataPreservingSelection()
        if resetBrowsingState {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        scrollView.hasVerticalScroller = videos.isEmpty == false
        updateEmptyState()
        notifySelectionChanged()
    }

    func updateVideo(_ video: VideoRecord, refreshThumbnail: Bool = true) {
        guard let index = videos.firstIndex(where: { $0.id == video.id }), refreshThumbnail || videos[index] != video else { return }
        let previous = videos[index]
        videos[index] = video
        if groupBucket(for: previous).id == groupBucket(for: video).id {
            for section in sections.indices {
                if let item = sections[section].videos.firstIndex(where: { $0.id == video.id }) {
                    sections[section].videos[item] = video
                    let path = IndexPath(item: item, section: section)
                    if let cell = collectionView.item(at: path) as? VideoCollectionViewItem {
                        cell.configure(with: video, thumbnailURL: thumbnailURL(video), refreshThumbnail: refreshThumbnail)
                    }
                    break
                }
            }
        } else {
            rebuildSections()
            reloadCollectionDataPreservingSelection()
        }
        if selectedVideoIDs.contains(video.id) { notifySelectionChanged() }
    }

    // Actual viewport first, nearby items next, then the current displayed ordering.
    func mediaPriorityVideoIDs() -> [String] {
        guard isViewLoaded, !view.isHidden else { return [] }
        let ordered = sections.filter { !collapsedGroupIDs.contains($0.id) }.flatMap { $0.videos.map(\.id) }
        let visible = Set(collectionView.visibleItems().compactMap { item -> String? in
            guard let path = collectionView.indexPath(for: item) else { return nil }
            return video(at: path)?.id
        })
        let indices = ordered.indices.filter { visible.contains(ordered[$0]) }
        guard let first = indices.first, let last = indices.last else { return ordered }
        let nearby = Array(ordered[max(0, first - 12)..<min(ordered.count, last + 13)])
        var seen = Set<String>()
        return (ordered.filter { visible.contains($0) } + nearby + ordered).filter { seen.insert($0).inserted }
    }

    func selectedVideos() -> [VideoRecord] {
        videos.filter { selectedVideoIDs.contains($0.id) }
    }

    func setSelectedVideoIDs(_ videoIDs: [String], notify: Bool = true) {
        loadViewIfNeeded()
        selectedVideoIDs = Set(videoIDs).intersection(videos.map(\.id))
        syncCollectionSelectionFromIDs()
        if notify { notifySelectionChanged() }
    }

    @discardableResult
    func selectAndRevealVideos(ids videoIDs: [String]) -> Bool {
        loadViewIfNeeded()
        var seen = Set<String>()
        let uniqueVideoIDs = videoIDs.filter { seen.insert($0).inserted }
        guard uniqueVideoIDs.isEmpty == false,
              uniqueVideoIDs.allSatisfy({ id in videos.contains(where: { $0.id == id }) }) else {
            return false
        }
        let targetGroupIDs = Set(sections.compactMap { section in
            section.videos.contains(where: { uniqueVideoIDs.contains($0.id) }) ? section.id : nil
        })
        if collapsedGroupIDs.isDisjoint(with: targetGroupIDs) == false {
            collapsedGroupIDs.subtract(targetGroupIDs)
            reloadCollectionDataPreservingSelection()
        }
        selectedVideoIDs = Set(uniqueVideoIDs)
        selectionAnchorVideoID = uniqueVideoIDs[0]
        syncCollectionSelectionFromIDs()
        guard let firstIndexPath = indexPath(forVideoID: uniqueVideoIDs[0]) else { return false }
        collectionView.scrollToItems(at: [firstIndexPath], scrollPosition: .centeredVertically)
        notifySelectionChanged()
        return true
    }

    func showRestoredVideos(_ videoIDs: [String]) {
        setSelectedVideoIDs(videoIDs)
        importStatusView.configureFinished(
            title: String(localized: .importResultRestored(videoIDs.count)),
            detail: String(localized: .importResultRestoredDetail(videoIDs.count))
        )
        showImportStatus()
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        guard sections.indices.contains(section), collapsedGroupIDs.contains(sections[section].id) == false else {
            return 0
        }
        return sections[section].videos.count
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
        guard let video = video(at: indexPath) else { return item }
        item.configure(with: video, thumbnailURL: thumbnailURL(video))
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSView {
        guard kind == NSCollectionView.elementKindSectionHeader,
              grouping.key != .none,
              sections.indices.contains(indexPath.section),
              let header = collectionView.makeSupplementaryView(
                ofKind: kind,
                withIdentifier: Self.groupHeaderIdentifier,
                for: indexPath
              ) as? VideoGroupHeaderView else {
            return NSView()
        }
        let section = sections[indexPath.section]
        header.configure(
            title: section.title ?? "",
            count: section.videos.count,
            isExpanded: collapsedGroupIDs.contains(section.id) == false
        ) { [weak self] in
            self?.toggleGroup(section.id)
        }
        return header
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        guard isSynchronizingSelection == false else { return }
        let visibleIDs = Set(collectionView.selectionIndexPaths.compactMap { video(at: $0)?.id })
        if selectionGestureMode == .replacing {
            selectedVideoIDs = visibleIDs
        } else {
            selectedVideoIDs.formUnion(indexPaths.compactMap { video(at: $0)?.id })
        }
        notifySelectionChanged()
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didDeselectItemsAt indexPaths: Set<IndexPath>
    ) {
        guard isSynchronizingSelection == false else { return }
        selectedVideoIDs.subtract(indexPaths.compactMap { video(at: $0)?.id })
        notifySelectionChanged()
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        let selectedIDs = collectionView.selectionIndexPaths.contains(indexPath)
            ? selectedVideos().map(\.id)
            : video(at: indexPath).map { [$0.id] } ?? []
        guard selectedIDs.isEmpty == false else { return nil }
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
              let targetVideo = video(at: indexPath) else { return false }
        let videoIDs = collectionView.selectionIndexPaths.contains(indexPath)
            ? selectedVideos().map(\.id)
            : [targetVideo.id]
        onAssignTagID(tagID, videoIDs)
        return true
    }

    private func updateEmptyState() {
        emptyState.isHidden = videos.isEmpty == false
        emptyTitleLabel.stringValue = String(localized: .importEmptyTitle)
        emptyDetailLabel.stringValue = String(localized: .importEmptyDetail)
    }

    private func openVideo(at indexPath: IndexPath) {
        guard let video = video(at: indexPath) else { return }
        onOpenVideo(video)
    }

    private func previewSelection() {
        let selectedVideos = selectedVideos().filter { $0.availability == .available }
        guard selectedVideos.isEmpty == false else { return }
        onPreviewVideos(selectedVideos)
    }

    private func contextMenu(for indexPath: IndexPath) -> NSMenu? {
        guard let video = video(at: indexPath) else { return nil }
        selectionAnchorVideoID = video.id
        if collectionView.selectionIndexPaths.contains(indexPath) == false {
            selectedVideoIDs = [video.id]
            syncCollectionSelectionFromIDs()
            notifySelectionChanged()
        }

        let selected = selectedVideos()
        if selected.isEmpty == false,
           selected.allSatisfy({ $0.availability != .available }) {
            return unavailableContextMenu(for: selected)
        }
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
        let selectedCount = selectedVideoIDs.count
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

    private func unavailableContextMenu(for selected: [VideoRecord]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if selected.count == 1,
           let video = selected.first,
           video.availability == .unavailable {
            let relinkItem = NSMenuItem(
                title: String(
                    localized: "unavailable.relink.action",
                    defaultValue: "Relink Original…"
                ),
                action: #selector(relinkVideoFromContextMenu(_:)),
                keyEquivalent: ""
            )
            relinkItem.target = self
            relinkItem.representedObject = video.id
            relinkItem.isEnabled = relinkingVideoID != video.id
            menu.addItem(relinkItem)
            menu.addItem(.separator())
        }

        let removeTitle = selected.count > 1
            ? String(
                format: String(
                    localized: "unavailable.remove.action.multiple",
                    defaultValue: "Remove %lld Videos from FileFacet…"
                ),
                selected.count
            )
            : String(
                localized: "unavailable.remove.action",
                defaultValue: "Remove from FileFacet…"
            )
        let removeItem = NSMenuItem(
            title: removeTitle,
            action: #selector(removeVideosFromContextMenu(_:)),
            keyEquivalent: "\u{8}"
        )
        removeItem.keyEquivalentModifierMask = [.command]
        removeItem.target = self
        removeItem.isEnabled = true
        menu.addItem(removeItem)
        return menu
    }

    private func requestRemoveSelectedVideos() {
        let selected = selectedVideos()
        guard selected.isEmpty == false, let window = view.window else { return }
        let isUnavailableSelection = selected.allSatisfy { $0.availability != .available }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if isUnavailableSelection {
            if selected.count > 1 {
                alert.messageText = String(
                    format: String(
                        localized: "unavailable.remove.title.multiple",
                        defaultValue: "Remove %lld records from FileFacet?"
                    ),
                    selected.count
                )
                alert.informativeText = String(
                    localized: "unavailable.remove.detail.multiple",
                    defaultValue: "The original tags and media information for these records will be deleted from FileFacet. This will not affect original files that may exist on your Mac."
                )
            } else {
                alert.messageText = String(
                    localized: "unavailable.remove.title",
                    defaultValue: "Remove this record from FileFacet?"
                )
                alert.informativeText = String(
                    localized: "unavailable.remove.detail",
                    defaultValue: "The original tags and media information will be deleted from FileFacet. This will not affect the original file that may exist on your Mac."
                )
            }
        } else {
            alert.messageText = selected.count > 1
                ? String(localized: .videoRemoveTitleMultiple(selected.count))
                : String(localized: .videoRemoveTitleSingle)
            alert.informativeText = selected.count > 1
                ? String(localized: .videoRemoveDetailMultiple)
                : String(localized: .videoRemoveDetailSingle)
        }
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
                self.showVideoRemovalUndo(videoCount: videoIDs.count)
            }
        }
    }

    private func handleSelectionGesture(
        at indexPath: IndexPath?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        selectionGestureMode = modifiers.contains(.command) || modifiers.contains(.shift)
            ? .extending
            : .replacing
        guard let indexPath, let selectedVideo = video(at: indexPath) else {
            if modifiers.contains(.shift) == false {
                selectionAnchorVideoID = nil
                selectedVideoIDs.removeAll()
                syncCollectionSelectionFromIDs()
                notifySelectionChanged()
                return true
            }
            return false
        }

        guard modifiers.contains(.shift) else {
            selectionAnchorVideoID = selectedVideo.id
            if modifiers.contains(.command) == false,
               collectionView.selectionIndexPaths.contains(indexPath),
               selectedVideoIDs != [selectedVideo.id] {
                selectedVideoIDs = [selectedVideo.id]
                notifySelectionChanged()
            }
            return false
        }

        let visibleIndexPaths = visibleItemIndexPaths()
        guard let targetPosition = visibleIndexPaths.firstIndex(of: indexPath) else { return false }
        let anchorPosition = selectionAnchorVideoID
            .flatMap(indexPath(forVideoID:))
            .flatMap { visibleIndexPaths.firstIndex(of: $0) } ?? targetPosition
        selectionAnchorVideoID = video(at: visibleIndexPaths[anchorPosition])?.id

        let lowerBound = min(anchorPosition, targetPosition)
        let upperBound = max(anchorPosition, targetPosition)
        let rangeSelection = Set(visibleIndexPaths[lowerBound...upperBound])
        if modifiers.contains(.command) {
            selectedVideoIDs.formUnion(rangeSelection.compactMap { video(at: $0)?.id })
        } else {
            selectedVideoIDs = Set(rangeSelection.compactMap { video(at: $0)?.id })
        }
        syncCollectionSelectionFromIDs()
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

    @objc private func relinkVideoFromContextMenu(_ sender: NSMenuItem) {
        guard let video = video(from: sender),
              video.availability == .unavailable else { return }
        onRelinkVideo(video)
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
        onSelectionChanged(selectedVideos())
    }
}

@MainActor
private final class VideoGroupHeaderView: NSView {
    private let disclosureButton = NSButton()
    private let titleButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        disclosureButton.title = ""
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.isBordered = false
        disclosureButton.bezelStyle = .inline
        disclosureButton.controlSize = .small
        disclosureButton.contentTintColor = .secondaryLabelColor
        disclosureButton.target = self
        disclosureButton.action = #selector(toggle)

        titleButton.translatesAutoresizingMaskIntoConstraints = false
        titleButton.isBordered = false
        titleButton.bezelStyle = .inline
        titleButton.alignment = .left
        titleButton.font = .systemFont(ofSize: 12, weight: .semibold)
        titleButton.target = self
        titleButton.action = #selector(toggle)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        addSubview(disclosureButton)
        addSubview(titleButton)
        addSubview(countLabel)
        addSubview(separator)
        NSLayoutConstraint.activate([
            disclosureButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 16),
            disclosureButton.heightAnchor.constraint(equalToConstant: 22),
            titleButton.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 2),
            titleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: titleButton.trailingAnchor, constant: 6),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.94).cgColor
    }

    func configure(title: String, count: Int, isExpanded: Bool, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        disclosureButton.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
        disclosureButton.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        titleButton.title = title
        countLabel.stringValue = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityExpanded(isExpanded)
    }

    @objc private func toggle() {
        onToggle?()
    }
}

@MainActor
private final class ImportStatusView: NSView {
    private enum ActionMode {
        case cancel
        case dismiss
        case view
        case undo
        case retry
    }

    var onCancel: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onView: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRetry: (() -> Void)?

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
        actionButton.isHidden = false
        closeButton.isHidden = true
    }

    func configurePassive(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        actionButton.isHidden = true
        closeButton.isHidden = false
    }

    func configureFinished(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        actionButton.title = String(localized: .actionDone)
        actionMode = .dismiss
        actionButton.isHidden = false
        closeButton.isHidden = false
    }

    func configureCompleted(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        actionButton.title = String(localized: .actionView)
        actionMode = .view
        actionButton.isHidden = false
        closeButton.isHidden = false
    }

    func configureUndo(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        actionButton.title = String(localized: .actionUndo)
        actionMode = .undo
        actionButton.isHidden = false
        closeButton.isHidden = false
    }

    func configureRetry(title: String, detail: String, actionTitle: String) {
        configureAction(title: title, detail: detail, actionTitle: actionTitle, mode: .retry)
    }

    func configureViewExisting(title: String, detail: String, actionTitle: String) {
        configureAction(title: title, detail: detail, actionTitle: actionTitle, mode: .view)
    }

    private func configureAction(
        title: String,
        detail: String,
        actionTitle: String,
        mode: ActionMode
    ) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        actionButton.title = actionTitle
        actionMode = mode
        actionButton.isHidden = false
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
        case .retry: onRetry?()
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
    private var imageTask: Task<Void, Never>?
    private var imageRequest = UUID()
    private var configuredVideo: VideoRecord?
    private var configuredURL: URL?

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageRequest = UUID()
        configuredVideo = nil
        configuredURL = nil
        thumbnailView.image = nil
        isHovered = false
        updateSelectionAppearance()
    }


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

    func configure(with video: VideoRecord, thumbnailURL: URL?, refreshThumbnail: Bool = false) {
        loadViewIfNeeded()
        let needsImage = refreshThumbnail || configuredVideo?.id != video.id || configuredURL != thumbnailURL
            || configuredVideo?.thumbnailStatus != video.thumbnailStatus
            || configuredVideo?.contentFingerprint != video.contentFingerprint
        if configuredVideo?.id != video.id {
            isHovered = false
            updateSelectionAppearance()
        }
        configuredVideo = video
        configuredURL = thumbnailURL
        if needsImage {
            imageTask?.cancel()
            let request = UUID()
            imageRequest = request
            thumbnailView.image = nil
            if let thumbnailURL {
                imageTask = Task { [weak self] in
                    let image = await DecodedVideoThumbnailCache.shared.image(at: thumbnailURL)
                    guard !Task.isCancelled, let self, imageRequest == request else { return }
                    thumbnailView.image = image
                }
            }
        }
        thumbnailView.setStatus(video.accessPresentation)
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.backgroundColor = backgroundColor.cgColor
        CATransaction.commit()
    }
}

@MainActor
private final class VideoThumbnailView: NSView {
    private let placeholderView = NSImageView()
    private let offlineOverlayView = NSView()
    private let offlineBadgeView = NSView()
    private let statusIcon = NSImageView()

    var image: CGImage? {
        didSet {
            placeholderView.isHidden = image != nil
            updateImageLayer()
        }
    }

    func setStatus(_ status: VideoThumbnailStatus) {
        let label = status.accessibilityLabel
        offlineOverlayView.isHidden = status == .none || status == .cloud
        offlineBadgeView.isHidden = status.symbol == nil
        statusIcon.image = status.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: label) }
        statusIcon.toolTip = label
        statusIcon.setAccessibilityElement(label != nil)
        statusIcon.setAccessibilityLabel(label)
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
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        statusIcon.contentTintColor = .white
        statusIcon.imageScaling = .scaleProportionallyDown
        offlineBadgeView.addSubview(statusIcon)
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
            offlineBadgeView.widthAnchor.constraint(equalToConstant: 23),
            offlineBadgeView.heightAnchor.constraint(equalToConstant: 20),
            statusIcon.centerXAnchor.constraint(equalTo: offlineBadgeView.centerXAnchor),
            statusIcon.centerYAnchor.constraint(equalTo: offlineBadgeView.centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 16),
            statusIcon.heightAnchor.constraint(equalToConstant: 15),
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
        layer?.contents = image
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
        refreshHover()
    }

    @objc private func refreshHover() {
        guard let window, window.isKeyWindow else { onHoverChanged?(false); return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        onHoverChanged?(visibleRect.contains(point))
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshHover), name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(refreshHover), name: NSWindow.didBecomeKeyNotification, object: window)
        }
        refreshHover()
    }
}

// File I/O and eager JPEG decoding stay on this actor, away from AppKit's main actor.
private actor DecodedVideoThumbnailCache {
    static let shared = DecodedVideoThumbnailCache()
    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 64 * 1_024 * 1_024
        cache.countLimit = 256
        return cache
    }()

    func image(at url: URL) -> CGImage? {
        guard !Task.isCancelled,
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        let key = "\(url.path)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), !Task.isCancelled else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}
