import Foundation

enum LibraryImportState: Equatable, Sendable {
    case idle
    case importing
    case completed
    case failed(message: String)
}

@MainActor
final class LibraryAccessCoordinator {
    private let database: DatabaseStore
    private let picker: LibraryPicker
    private let discovery: any VideoFileDiscovering
    private let mediaService: MediaProcessingService?
    private var resources: [String: SecurityScopedResource] = [:]
    private var sourceURLs: [String: URL] = [:]
    private var watchers: [String: FSEventsWatcher] = [:]
    private var resolvedVideoURLs: [String: URL] = [:]
    private var importTask: Task<Void, Never>?
    private var importRevision = 0
    private var maintenanceTask: Task<Void, Never>?
    private var maintenanceDebounceTasks: [String: Task<Void, Never>] = [:]
    private var mediaTask: Task<Void, Never>?
    private var pendingMediaVideos: [String: VideoRecord] = [:]
    private var queryTask: Task<Void, Never>?
    private var tagMutationTask: Task<Void, Never>?
    private var pendingTagMutationCount = 0
    private var tagStateRevision = 0
    private var tags: [TagRecord] = []
    private var currentFilter: LibraryFilter = .all
    private var currentSearch = ""

    var onVideosChanged: (([VideoRecord]) -> Void)?
    var onSidebarFilterCountsChanged: ((SidebarFilterCounts) -> Void)?
    var onVideoChanged: ((VideoRecord) -> Void)?
    var onImportStateChanged: ((LibraryImportState) -> Void)?
    var onTagsChanged: (([TagRecord]) -> Void)?
    var onTagAssignmentsChanged: (() -> Void)?
    var onError: ((String) -> Void)?
    var onOperationError: ((String) -> Void)?
    private let undoManager = UndoManager()

    var canUndoLastTagMutation: Bool {
        pendingTagMutationCount == 0 && undoManager.canUndo
    }

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
                let sources = try await database.fetchSourceAuthorizations()
                for source in sources {
                    do {
                        var isStale = false
                        let url = try URL(
                            resolvingBookmarkData: source.rootBookmarkData,
                            options: [.withSecurityScope, .withoutUI],
                            relativeTo: nil,
                            bookmarkDataIsStale: &isStale
                        )
                        try connect(sourceID: source.id, url: url)
                        if isStale {
                            try await database.saveSourceAuthorization(SourceAuthorizationRecord(
                                id: source.id,
                                libraryID: source.libraryID,
                                displayName: url.lastPathComponent,
                                rootBookmarkData: try makeBookmark(for: url),
                                createdAt: source.createdAt
                            ))
                        }
                    } catch {
                        AppLogger.library.error("Source restore failed with category: \(String(describing: type(of: error)), privacy: .public)")
                    }
                }
                let existingVideos = try await database.fetchVideos(
                    libraryID: LibraryRecord.primaryID,
                    filter: currentFilter,
                    searchText: currentSearch
                )
                try await refreshTags(libraryID: LibraryRecord.primaryID)
                try await refreshResolvedVideoURLs()
                try await refreshSidebarFilterCounts()
                onVideosChanged?(existingVideos)
                startMediaProcessing(videos: existingVideos)
                for sourceID in sourceURLs.keys { scheduleMaintenance(sourceID: sourceID) }
            } catch {
                AppLogger.library.error("Library restore failed with category: \(String(describing: type(of: error)), privacy: .public)")
                onError?("无法读取现有视频索引，请重新启动应用。")
            }
        }
    }

    func importVideos() {
        guard let url = picker.chooseDirectory() else { return }

        do {
            let bookmark = try makeBookmark(for: url)
            let standardizedURL = url.standardizedFileURL
            let existingSourceID = sourceURLs.first { $0.value.standardizedFileURL == standardizedURL }?.key
            let sourceID = existingSourceID ?? UUID().uuidString
            try connect(sourceID: sourceID, url: standardizedURL)
            importTask?.cancel()
            importRevision += 1
            let revision = importRevision
            onImportStateChanged?(.importing)
            let discovery = self.discovery
            let database = self.database
            importTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if importRevision == revision { importTask = nil }
                }
                do {
                    if try await database.fetchPrimaryLibrary() == nil {
                        try await database.saveLibrary(LibraryRecord(
                            id: LibraryRecord.primaryID,
                            name: "全部视频",
                            rootBookmarkData: bookmark,
                            createdAt: Date(),
                            lastScanAt: nil
                        ))
                    }
                    try await database.saveSourceAuthorization(SourceAuthorizationRecord(
                        id: sourceID,
                        libraryID: LibraryRecord.primaryID,
                        displayName: standardizedURL.lastPathComponent,
                        rootBookmarkData: bookmark,
                        createdAt: Date()
                    ))
                    let discoveryTask = Task.detached(priority: .utility) {
                        try discovery.discoverVideoResult(at: standardizedURL)
                    }
                    let discoveryResult = try await withTaskCancellationHandler {
                        try await discoveryTask.value
                    } onCancel: {
                        discoveryTask.cancel()
                    }
                    try Task.checkCancellation()
                    let result = try await database.importVideos(
                        sourceID: sourceID,
                        discoveredVideos: discoveryResult.videos,
                        discoveryFailedCount: discoveryResult.failedCount
                    )
                    try await refreshTags(libraryID: LibraryRecord.primaryID)
                    try await refreshResolvedVideoURLs()
                    try await refreshVisibleVideosNow()
                    tagStateRevision += 1
                    undoManager.removeAllActions()
                    startMediaProcessing(videos: result.importedVideos)
                    guard importRevision == revision else { return }
                    onImportStateChanged?(.completed)
                    onOperationError?(
                        "导入完成：新增 \(result.addedCount) 个，已存在 \(result.existingCount) 个，失败 \(result.failedCount) 个。"
                    )
                    AppLogger.library.notice("Manual import completed with \(result.addedCount, privacy: .public) new videos")
                } catch is CancellationError {
                    await refreshAfterInterruptedImportInFreshTask()
                    guard importRevision == revision else { return }
                    onImportStateChanged?(.idle)
                    onOperationError?("已取消导入，已经完整加入的视频会保留。")
                } catch {
                    AppLogger.library.error("Manual import failed with category: \(String(describing: type(of: error)), privacy: .public)")
                    await refreshAfterInterruptedImportInFreshTask()
                    guard importRevision == revision else { return }
                    onImportStateChanged?(.failed(message: "导入未完成；已经完整加入的视频会保留，请重试剩余内容。"))
                }
            }
        } catch {
            AppLogger.library.error("Import authorization failed with category: \(String(describing: type(of: error)), privacy: .public)")
            onOperationError?("无法获得该文件夹的持续访问权限。")
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    private func refreshAfterInterruptedImportInFreshTask() async {
        let refreshTask = Task { @MainActor [weak self] in
            await self?.refreshAfterInterruptedImport()
        }
        await refreshTask.value
    }

    private func refreshAfterInterruptedImport() async {
        do {
            try await refreshTags(libraryID: LibraryRecord.primaryID)
            try await refreshResolvedVideoURLs()
            try await refreshVisibleVideosNow()
            tagStateRevision += 1
            undoManager.removeAllActions()
            let videos = try await database.fetchVideos(libraryID: LibraryRecord.primaryID)
            startMediaProcessing(videos: videos)
        } catch {
            AppLogger.library.error(
                "Interrupted import refresh failed with category: \(String(describing: type(of: error)), privacy: .public)"
            )
        }
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
        resolvedVideoURLs[video.id]
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

    func setTagAssignment(
        _ tag: TagRecord,
        videoIDs: [String],
        enabled: Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        mutateTags(actionName: enabled ? "添加标签" : "移除标签") { database in
            try await database.setTagAssignment(tagID: tag.id, videoIDs: videoIDs, enabled: enabled)
        } completion: { succeeded in
            completion?(succeeded)
        }
    }

    func applyTagAssignments(
        _ assignments: [String: Bool],
        videoIDs: [String],
        completion: ((Bool) -> Void)? = nil
    ) {
        mutateTags(actionName: "应用标签") { database in
            try await database.setTagAssignments(assignments, videoIDs: videoIDs)
        } completion: { succeeded in
            completion?(succeeded)
        }
    }

    func applyTagDraft(
        creations: [TagCreationDraft],
        assignments: [String: Bool],
        videoIDs: [String],
        completion: ((Bool) -> Void)? = nil
    ) {
        mutateTags(actionName: "应用标签") { database in
            try await database.applyTagDraft(
                libraryID: LibraryRecord.primaryID,
                creations: creations,
                assignments: assignments,
                videoIDs: videoIDs
            )
        } completion: { succeeded in
            completion?(succeeded)
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

    func undoLastTagMutation() {
        guard canUndoLastTagMutation else { return }
        undoManager.undo()
    }

    private func connect(sourceID: String, url: URL) throws {
        if sourceURLs[sourceID]?.standardizedFileURL == url.standardizedFileURL,
           resources[sourceID] != nil { return }
        watchers[sourceID]?.stop()
        guard let resource = SecurityScopedResource(url: url) else {
            throw CocoaError(.fileReadNoPermission)
        }
        resources[sourceID] = resource
        sourceURLs[sourceID] = url
        let watcher = FSEventsWatcher { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleMaintenance(sourceID: sourceID) }
        }
        watchers[sourceID] = watcher
        watcher.start(watching: url)
    }

    private func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func scheduleMaintenance(sourceID: String) {
        maintenanceDebounceTasks[sourceID]?.cancel()
        maintenanceDebounceTasks[sourceID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                self?.startMaintenance(sourceID: sourceID)
            } catch {}
        }
    }

    private func startMaintenance(sourceID: String) {
        guard sourceURLs[sourceID] != nil else { return }
        let sources = sourceURLs
        maintenanceTask?.cancel()
        let discovery = self.discovery
        let database = self.database
        maintenanceTask = Task(priority: .utility) { [weak self] in
            do {
                var discoveredVideosBySource: [String: [DiscoveredVideo]] = [:]
                var canConfirmDeletions = true
                for sourceID in sources.keys.sorted() {
                    guard let url = sources[sourceID] else { continue }
                    do {
                        let discoveryTask = Task.detached(priority: .utility) {
                            try discovery.discoverVideoResult(at: url)
                        }
                        let discoveryResult = try await withTaskCancellationHandler {
                            try await discoveryTask.value
                        } onCancel: {
                            discoveryTask.cancel()
                        }
                        if discoveryResult.failedCount > 0 {
                            canConfirmDeletions = false
                        } else {
                            discoveredVideosBySource[sourceID] = discoveryResult.videos
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        canConfirmDeletions = false
                        AppLogger.library.error(
                            "Source maintenance discovery failed with category: \(String(describing: type(of: error)), privacy: .public)"
                        )
                    }
                }
                try Task.checkCancellation()
                let result = try await database.reconcileSources(
                    discoveredVideosBySource: discoveredVideosBySource,
                    confirmDeletions: canConfirmDeletions
                )
                try Task.checkCancellation()
                guard let self else { return }
                try await refreshResolvedVideoURLs()
                try await refreshTags(libraryID: LibraryRecord.primaryID)
                try await refreshVisibleVideosNow()
                if result.deletedThumbnailIDs.isEmpty == false {
                    try? await mediaService?.removeThumbnails(identifiers: result.deletedThumbnailIDs)
                }
                let updated = try await database.fetchVideos(libraryID: LibraryRecord.primaryID)
                    .filter { result.updatedVideoIDs.contains($0.id) }
                startMediaProcessing(videos: updated)
                AppLogger.library.notice("Silent source maintenance completed")
            } catch is CancellationError {
                return
            } catch {
                AppLogger.library.error("Silent source maintenance failed with category: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    private func refreshResolvedVideoURLs() async throws {
        let locations = try await database.fetchVideoLocations()
        var urls: [String: URL] = [:]
        var fallbackUpdates: [VideoLocationFallbackUpdate] = []
        for location in locations {
            guard let rootURL = sourceURLs[location.sourceID] else { continue }
            let components = location.relativePath.split(separator: "/")
            guard components.contains("..") == false else { continue }
            let fileURL = components.reduce(rootURL) { partialURL, component in
                partialURL.appendingPathComponent(String(component))
            }
            if urls[location.videoID] == nil { urls[location.videoID] = fileURL }
            if location.fallbackPathKey == nil {
                fallbackUpdates.append(VideoLocationFallbackUpdate(
                    videoID: location.videoID,
                    sourceID: location.sourceID,
                    relativePath: location.relativePath,
                    fallbackPathKey: fallbackPathKey(for: fileURL)
                ))
            }
        }
        try await database.backfillVideoLocationFallbackKeys(fallbackUpdates)
        resolvedVideoURLs = urls
    }

    private func startMediaProcessing(videos: [VideoRecord]) {
        guard let mediaService else { return }
        let pendingVideos = videos.filter { video in
            if video.metadataStatus == .pending || video.thumbnailStatus == .pending { return true }
            guard video.thumbnailStatus == .completed,
                  let thumbnailID = video.thumbnailID else { return false }
            return FileManager.default.fileExists(atPath: mediaService.thumbnailURL(for: thumbnailID).path) == false
        }
        guard pendingVideos.isEmpty == false else { return }
        for video in pendingVideos {
            pendingMediaVideos[video.id] = video
        }
        guard mediaTask == nil else { return }
        let database = self.database

        mediaTask = Task { [weak self] in
            guard let self else { return }
            while let video = pendingMediaVideos.values.first {
                pendingMediaVideos.removeValue(forKey: video.id)
                do {
                    try Task.checkCancellation()
                    guard let fileURL = resolvedVideoURLs[video.id] else { continue }
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
            mediaTask = nil
        }
    }

    private func refreshTags(libraryID: String) async throws {
        tags = try await database.fetchTags(libraryID: libraryID)
        onTagsChanged?(tags)
    }

    private func mutateTags(
        actionName: String,
        operation: @escaping @Sendable (DatabaseStore) async throws -> Void,
        completion: ((Bool) -> Void)? = nil
    ) {
        let database = self.database
        let previousTask = tagMutationTask
        pendingTagMutationCount += 1
        tagMutationTask = Task { [weak self] in
            _ = await previousTask?.value
            guard let self else { return }
            defer { pendingTagMutationCount -= 1 }
            do {
                let startingRevision = tagStateRevision
                let snapshot = try await database.captureTagState(libraryID: LibraryRecord.primaryID)
                try await operation(database)
                try await refreshTags(libraryID: LibraryRecord.primaryID)
                try await refreshVisibleVideosNow()
                completion?(true)
                onTagAssignmentsChanged?()
                undoManager.removeAllActions()
                if tagStateRevision == startingRevision {
                    undoManager.registerUndo(withTarget: self) { target in
                        target.restoreTagState(snapshot)
                    }
                    undoManager.setActionName(actionName)
                }
            } catch {
                completion?(false)
                AppLogger.database.error("Tag mutation failed with category: \(String(describing: type(of: error)), privacy: .public)")
                onOperationError?("标签操作未完成，请检查名称或层级后重试。")
            }
        }
    }

    private func restoreTagState(_ snapshot: TagStateSnapshot) {
        let previousTask = tagMutationTask
        pendingTagMutationCount += 1
        tagMutationTask = Task { [weak self] in
            _ = await previousTask?.value
            guard let self else { return }
            defer { pendingTagMutationCount -= 1 }
            do {
                try await database.restoreTagState(snapshot)
                try await refreshTags(libraryID: snapshot.libraryID)
                try await refreshVisibleVideosNow()
                onTagAssignmentsChanged?()
                undoManager.removeAllActions()
            } catch {
                AppLogger.database.error("Tag undo failed with category: \(String(describing: type(of: error)), privacy: .public)")
                onOperationError?("撤销未完成，请重试。")
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
                onOperationError?("筛选视频时发生错误，请重试。")
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
        try await refreshSidebarFilterCounts()
    }

    private func refreshSidebarFilterCounts() async throws {
        let counts = try await database.fetchSidebarFilterCounts(libraryID: LibraryRecord.primaryID)
        onSidebarFilterCountsChanged?(counts)
    }
}
