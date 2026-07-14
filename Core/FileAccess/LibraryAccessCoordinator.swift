import Foundation

struct LibrarySummary: Equatable, Sendable {
    let name: String
}

enum LibraryScanState: Equatable, Sendable {
    case idle
    case scanning
    case completed(videoCount: Int)
    case failed(message: String)
}

@MainActor
final class LibraryAccessCoordinator {
    private let database: DatabaseStore
    private let picker: LibraryPicker
    private let discovery: any VideoFileDiscovering
    private let mediaService: MediaProcessingService?
    private var activeResource: SecurityScopedResource?
    private var scanTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?
    private var fileEventTask: Task<Void, Never>?
    private var tags: [TagRecord] = []
    private var currentFilter: LibraryFilter = .all
    private var currentSearch = ""
    private lazy var fileEventsWatcher = FSEventsWatcher { [weak self] in
        Task { @MainActor [weak self] in self?.scheduleScanFromFileEvent() }
    }

    var onLibraryChanged: ((LibrarySummary) -> Void)?
    var onVideosChanged: (([VideoRecord]) -> Void)?
    var onVideoChanged: ((VideoRecord) -> Void)?
    var onScanStateChanged: ((LibraryScanState) -> Void)?
    var onTagsChanged: (([TagRecord]) -> Void)?
    var onTagAssignmentsChanged: (() -> Void)?
    var onError: ((String) -> Void)?
    weak var undoManager: UndoManager?

    var hasActiveLibrary: Bool { activeResource != nil }

    init(
        database: DatabaseStore,
        picker: LibraryPicker = LibraryPicker(),
        discovery: any VideoFileDiscovering = VideoFileDiscovery()
    ) {
        self.database = database
        self.picker = picker
        self.discovery = discovery
        mediaService = try? MediaProcessingService()
    }

    func restoreLibrary() {
        Task {
            do {
                guard let record = try await database.fetchPrimaryLibrary() else { return }
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: record.rootBookmarkData,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                try connect(url: url)
                onLibraryChanged?(LibrarySummary(name: url.lastPathComponent))

                if isStale {
                    let refreshedBookmark = try makeBookmark(for: url)
                    try await database.saveLibrary(
                        LibraryRecord(
                            id: record.id,
                            name: url.lastPathComponent,
                            rootBookmarkData: refreshedBookmark,
                            createdAt: record.createdAt,
                            lastScanAt: record.lastScanAt
                        )
                    )
                }

                let existingVideos = try await database.fetchVideos(
                    libraryID: record.id,
                    filter: currentFilter,
                    searchText: currentSearch
                )
                try await refreshTags(libraryID: record.id)
                onVideosChanged?(existingVideos)
                startMediaProcessing(videos: existingVideos, rootURL: url)
                startScan(url: url, libraryID: record.id)
            } catch {
                AppLogger.library.error("Library restore failed with category: \(String(describing: type(of: error)), privacy: .public)")
                onError?("无法恢复视频资料库访问权限，请重新选择目录。")
            }
        }
    }

    func chooseLibrary() {
        guard let url = picker.chooseDirectory() else { return }

        do {
            let bookmark = try makeBookmark(for: url)
            try connect(url: url)
            let record = LibraryRecord(
                id: LibraryRecord.primaryID,
                name: url.lastPathComponent,
                rootBookmarkData: bookmark,
                createdAt: Date(),
                lastScanAt: nil
            )

            Task {
                do {
                    scanTask?.cancel()
                    mediaTask?.cancel()
                    try await database.replaceLibrary(record)
                    onLibraryChanged?(LibrarySummary(name: url.lastPathComponent))
                    onVideosChanged?([])
                    tags = []
                    onTagsChanged?([])
                    AppLogger.library.notice("Library authorization saved")
                    startScan(url: url, libraryID: record.id)
                } catch {
                    AppLogger.database.error("Library save failed with category: \(String(describing: type(of: error)), privacy: .public)")
                    onError?("资料库权限已获得，但保存失败。请稍后重试。")
                }
            }
        } catch {
            AppLogger.library.error("Library authorization failed with category: \(String(describing: type(of: error)), privacy: .public)")
            onError?("无法获得该目录的持续访问权限。")
        }
    }

    func rescan() {
        guard let url = activeResource?.url else { return }
        startScan(url: url, libraryID: LibraryRecord.primaryID)
    }

    func applyFilter(_ filter: LibraryFilter) {
        currentFilter = filter
        refreshVisibleVideos()
    }

    func applySearch(_ searchText: String) {
        currentSearch = searchText
        refreshVisibleVideos(debounceNanoseconds: 150_000_000)
    }

    func fileURL(for video: VideoRecord) -> URL? {
        guard let rootURL = activeResource?.url else { return nil }
        return fileURL(for: video, rootURL: rootURL)
    }

    private func fileURL(for video: VideoRecord, rootURL: URL) -> URL? {
        let components = video.relativePath.split(separator: "/")
        guard components.contains("..") == false else { return nil }
        return components.reduce(rootURL) { url, component in
            url.appendingPathComponent(String(component))
        }
    }

    func thumbnailURL(for video: VideoRecord) -> URL? {
        guard let thumbnailID = video.thumbnailID else { return nil }
        return mediaService?.thumbnailURL(for: thumbnailID)
    }

    func createTag(name: String, parentID: String?) {
        mutateTags(actionName: "新建标签") { database in
            _ = try await database.createTag(libraryID: LibraryRecord.primaryID, name: name, parentID: parentID)
        }
    }

    func renameTag(_ tag: TagRecord, name: String) {
        mutateTags(actionName: "重命名标签") { database in try await database.renameTag(id: tag.id, name: name) }
    }

    func deleteTag(_ tag: TagRecord) {
        mutateTags(actionName: "删除标签") { database in try await database.deleteTag(id: tag.id) }
    }

    func moveTag(_ tag: TagRecord, parentID: String?, sortOrder: Int) {
        mutateTags(actionName: "移动标签") { database in try await database.moveTag(id: tag.id, parentID: parentID, sortOrder: sortOrder) }
    }

    func setTagColor(_ tag: TagRecord, color: String?) {
        mutateTags(actionName: "设置标签颜色") { database in try await database.setTagColor(id: tag.id, color: color) }
    }

    func mergeTag(_ source: TagRecord, into target: TagRecord) {
        mutateTags(actionName: "合并标签") { database in try await database.mergeTag(sourceID: source.id, targetID: target.id) }
    }

    func setTagAssignment(_ tag: TagRecord, videoIDs: [String], enabled: Bool) {
        mutateTags(actionName: enabled ? "添加标签" : "移除标签") { database in
            try await database.setTagAssignment(tagID: tag.id, videoIDs: videoIDs, enabled: enabled)
        }
    }

    func setTagAssignment(tagID: String, videoIDs: [String], enabled: Bool) {
        guard let tag = tags.first(where: { $0.id == tagID }) else { return }
        setTagAssignment(tag, videoIDs: videoIDs, enabled: enabled)
    }

    func tagAssignmentStates(videoIDs: [String], completion: @escaping ([String: TagAssignmentState]) -> Void) {
        let tags = self.tags
        Task {
            let states = (try? await database.tagAssignmentStates(videoIDs: videoIDs, tags: tags)) ?? [:]
            completion(states)
        }
    }

    private func connect(url: URL) throws {
        fileEventsWatcher.stop()
        guard let resource = SecurityScopedResource(url: url) else {
            throw CocoaError(.fileReadNoPermission)
        }
        activeResource = resource
        fileEventsWatcher.start(watching: url)
    }

    private func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func startScan(url: URL, libraryID: String) {
        scanTask?.cancel()
        onScanStateChanged?(.scanning)
        let discovery = self.discovery
        let database = self.database

        scanTask = Task {
            do {
                let discovered = try await Task.detached(priority: .utility) {
                    try discovery.discoverVideos(at: url)
                }.value
                try Task.checkCancellation()
                let videos = try await database.applyScan(
                    libraryID: libraryID,
                    discoveredVideos: discovered
                )
                try Task.checkCancellation()
                try await refreshTags(libraryID: libraryID)
                let visibleVideos = try await database.fetchVideos(
                    libraryID: libraryID,
                    filter: currentFilter,
                    searchText: currentSearch
                )
                onVideosChanged?(visibleVideos)
                onScanStateChanged?(.completed(videoCount: videos.count))
                startMediaProcessing(videos: videos, rootURL: url)
                AppLogger.library.notice("Library scan completed with \(videos.count, privacy: .public) videos")
            } catch is CancellationError {
                AppLogger.library.notice("Library scan cancelled")
            } catch {
                AppLogger.library.error("Library scan failed with category: \(String(describing: type(of: error)), privacy: .public)")
                onScanStateChanged?(.failed(message: "扫描未完成，仍显示上一次成功建立的索引。"))
            }
        }
    }

    private func scheduleScanFromFileEvent() {
        fileEventTask?.cancel()
        fileEventTask = Task {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard let url = activeResource?.url else { return }
                startScan(url: url, libraryID: LibraryRecord.primaryID)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func startMediaProcessing(videos: [VideoRecord], rootURL: URL) {
        mediaTask?.cancel()
        guard let mediaService else { return }
        let pendingVideos = videos.filter {
            $0.metadataStatus != .completed || $0.thumbnailStatus != .completed
        }
        guard pendingVideos.isEmpty == false else { return }
        let database = self.database

        mediaTask = Task {
            for video in pendingVideos {
                do {
                    try Task.checkCancellation()
                    guard let fileURL = fileURL(for: video, rootURL: rootURL) else { continue }
                    let result = await mediaService.process(video: video, fileURL: fileURL)
                    try Task.checkCancellation()
                    if let updated = try await database.updateMediaInfo(videoID: video.id, result: result) {
                        onVideoChanged?(updated)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    AppLogger.library.error("Media processing failed with category: \(String(describing: type(of: error)), privacy: .public)")
                }
            }
        }
    }

    private func refreshTags(libraryID: String) async throws {
        tags = try await database.fetchTags(libraryID: libraryID)
        onTagsChanged?(tags)
    }

    private func mutateTags(
        actionName: String,
        operation: @escaping @Sendable (DatabaseStore) async throws -> Void
    ) {
        let database = self.database
        Task {
            do {
                let snapshot = try await database.captureTagState(libraryID: LibraryRecord.primaryID)
                try await operation(database)
                try await refreshTags(libraryID: LibraryRecord.primaryID)
                try await refreshVisibleVideosNow()
                onTagAssignmentsChanged?()
                undoManager?.registerUndo(withTarget: self) { target in
                    target.restoreTagState(snapshot, actionName: actionName)
                }
                undoManager?.setActionName(actionName)
            } catch {
                AppLogger.database.error("Tag mutation failed with category: \(String(describing: type(of: error)), privacy: .public)")
                onError?("标签操作未完成，请检查名称或层级后重试。")
            }
        }
    }

    private func restoreTagState(_ snapshot: TagStateSnapshot, actionName: String) {
        Task {
            do {
                let redoSnapshot = try await database.captureTagState(libraryID: snapshot.libraryID)
                try await database.restoreTagState(snapshot)
                try await refreshTags(libraryID: snapshot.libraryID)
                try await refreshVisibleVideosNow()
                onTagAssignmentsChanged?()
                undoManager?.registerUndo(withTarget: self) { target in
                    target.restoreTagState(redoSnapshot, actionName: actionName)
                }
                undoManager?.setActionName(actionName)
            } catch {
                AppLogger.database.error("Tag undo failed with category: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    private func refreshVisibleVideos(debounceNanoseconds: UInt64 = 0) {
        queryTask?.cancel()
        let database = self.database
        let filter = currentFilter
        let search = currentSearch
        queryTask = Task {
            do {
                if debounceNanoseconds > 0 { try await Task.sleep(nanoseconds: debounceNanoseconds) }
                let videos = try await database.fetchVideos(
                    libraryID: LibraryRecord.primaryID,
                    filter: filter,
                    searchText: search
                )
                try Task.checkCancellation()
                onVideosChanged?(videos)
            } catch is CancellationError {
                return
            } catch {
                AppLogger.database.error("Video query failed with category: \(String(describing: type(of: error)), privacy: .public)")
                onError?("筛选视频时发生错误，请重试。")
            }
        }
    }

    private func refreshVisibleVideosNow() async throws {
        let videos = try await database.fetchVideos(
            libraryID: LibraryRecord.primaryID,
            filter: currentFilter,
            searchText: currentSearch
        )
        onVideosChanged?(videos)
    }
}
