import Foundation

enum LibraryImportState: Equatable, Sendable {
    case idle
    case importing(title: String, detail: String, progress: Double?)
    case completed(addedCount: Int, existingCount: Int, failedCount: Int)
    case cancelled
    case failed(message: String)
}

private struct PendingImportSource {
    let id: String
    let url: URL
    let bookmark: Data
    let isNew: Bool
}

private enum LastUndoMutation {
    case tag
    case videoRemoval(VideoRemovalSnapshot)
}

@MainActor
final class LibraryAccessCoordinator {
    private let database: DatabaseStore
    private let picker: LibraryPicker
    private let discovery: any VideoFileDiscovering
    private let mediaService: MediaProcessingService?
    private var resources: [String: SecurityScopedResource] = [:]
    private var sourceURLs: [String: URL] = [:]
    private var sourceBookmarks: [String: Data] = [:]
    private var watchersByPath: [String: FSEventsWatcher] = [:]
    private var sourceWatchPaths: [String: String] = [:]
    private var resolvedVideoURLs: [String: URL] = [:]
    private var importTask: Task<Void, Never>?
    private var importRevision = 0
    private var maintenanceTask: Task<Void, Never>?
    private var maintenanceDebounceTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    private var artifactCleanupTask: Task<Void, Never>?
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
    var onVideoRemovalUndoDiscarded: (() -> Void)?
    private let undoManager = UndoManager()
    private var lastUndoMutation: LastUndoMutation?

    var canUndoLastMutation: Bool {
        pendingTagMutationCount == 0 && undoManager.canUndo
    }

    var canUndoVideoRemoval: Bool {
        guard canUndoLastMutation else { return false }
        if case .videoRemoval = lastUndoMutation { return true }
        return false
    }

    var onVideoRemovalRestored: (([String]) -> Void)?

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
                let previousCleanupTask = artifactCleanupTask
                let cleanupTask = Task { [weak self] in
                    _ = await previousCleanupTask?.value
                    guard let self else { return }
                    do {
                        let removedSourceIDs = try await database.removeUnreferencedSourceAuthorizations()
                        for sourceID in removedSourceIDs { disconnectSource(sourceID) }
                        if let mediaService {
                            let referencedThumbnailIDs = try await database.fetchReferencedThumbnailIDs()
                            try await mediaService.removeUnreferencedThumbnails(retaining: referencedThumbnailIDs)
                        }
                    } catch {
                        AppLogger.library.error(
                            "Startup artifact cleanup failed with category: \(String(describing: type(of: error)), privacy: .public)"
                        )
                    }
                }
                artifactCleanupTask = cleanupTask
                await cleanupTask.value
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
                        sourceBookmarks[source.id] = source.rootBookmarkData
                        try connect(sourceID: source.id, url: url)
                        if isStale {
                            let refreshedBookmark = try makeBookmark(for: url)
                            sourceBookmarks[source.id] = refreshedBookmark
                            try await database.saveSourceAuthorization(SourceAuthorizationRecord(
                                id: source.id,
                                libraryID: source.libraryID,
                                displayName: url.lastPathComponent,
                                rootBookmarkData: refreshedBookmark,
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
                if sourceURLs.isEmpty == false { scheduleMaintenance() }
            } catch {
                AppLogger.library.error("Library restore failed with category: \(String(describing: type(of: error)), privacy: .public)")
                onError?("无法读取现有视频索引，请重新启动应用。")
            }
        }
    }

    func importVideos() {
        guard let url = picker.chooseDirectory() else { return }

        startImport(
            urls: [url],
            title: "正在导入“\(url.lastPathComponent)”",
            initialDetail: "正在发现视频…"
        )
    }

    func importDroppedVideos(_ urls: [URL]) {
        let videoURLs = urls
            .filter(VideoFileDiscovery.isSupportedVideoURL)
            .reduce(into: [URL]()) { result, url in
                let standardizedURL = url.standardizedFileURL
                if result.contains(where: { $0.standardizedFileURL == standardizedURL }) == false {
                    result.append(standardizedURL)
                }
            }
        guard videoURLs.isEmpty == false else {
            onImportStateChanged?(.failed(
                message: "没有可导入的视频。请拖入 MOV、MP4、M4V、AVI、MKV 或 WebM 文件。"
            ))
            return
        }

        startImport(
            urls: videoURLs,
            title: "正在导入拖入的 \(videoURLs.count) 个视频",
            initialDetail: "正在核对已导入的视频…"
        )
    }

    private func startImport(urls: [URL], title: String, initialDetail: String) {
        let standardizedURLs = urls.map(\.standardizedFileURL)

        var preparationFailedCount = 0
        var sources: [PendingImportSource] = []
        for url in standardizedURLs {
            do {
                sources.append(try prepareImportSource(for: url))
            } catch {
                preparationFailedCount += 1
            }
        }
        guard let initialSource = sources.first else {
            onImportStateChanged?(.failed(message: "无法获得所选内容的持续访问权限。"))
            return
        }
        importTask?.cancel()
        importRevision += 1
        let revision = importRevision
        let previousMutationTask = tagMutationTask
        let previousCleanupTask = artifactCleanupTask
        onImportStateChanged?(.importing(title: title, detail: initialDetail, progress: nil))
        let discovery = self.discovery
        let database = self.database
        importTask = Task { [weak self] in
            _ = await previousMutationTask?.value
            _ = await previousCleanupTask?.value
            guard let self else { return }
            var persistedSourceIDs = Set<String>()
            defer {
                if importRevision == revision { importTask = nil }
            }
            do {
                if try await database.fetchPrimaryLibrary() == nil {
                    try await database.saveLibrary(LibraryRecord(
                        id: LibraryRecord.primaryID,
                        name: "全部视频",
                        rootBookmarkData: initialSource.bookmark,
                        createdAt: Date(),
                        lastScanAt: nil
                    ))
                }
                var addedCount = 0
                var existingCount = 0
                var failedCount = preparationFailedCount
                var importedVideos: [VideoRecord] = []
                for (index, source) in sources.enumerated() {
                    try Task.checkCancellation()
                    let sourceProgress = Double(index) / Double(sources.count)
                    onImportStateChanged?(.importing(
                        title: title,
                        detail: sources.count == 1
                            ? "正在发现视频…"
                            : "正在核对第 \(index + 1) / \(sources.count) 个视频…",
                        progress: sources.count == 1 ? nil : sourceProgress
                    ))
                    do {
                        try connect(sourceID: source.id, url: source.url)
                        sourceBookmarks[source.id] = source.bookmark
                        let sourceURL = source.url
                        let discoveryTask = Task.detached(priority: .utility) {
                            try discovery.discoverVideoResult(at: sourceURL)
                        }
                        let discoveryResult = try await withTaskCancellationHandler {
                            try await discoveryTask.value
                        } onCancel: {
                            discoveryTask.cancel()
                        }
                        try Task.checkCancellation()
                        onImportStateChanged?(.importing(
                            title: title,
                            detail: "正在保存视频…",
                            progress: (Double(index) + 0.5) / Double(sources.count)
                        ))
                        try await database.saveSourceAuthorization(SourceAuthorizationRecord(
                            id: source.id,
                            libraryID: LibraryRecord.primaryID,
                            displayName: source.url.lastPathComponent,
                            rootBookmarkData: source.bookmark,
                            createdAt: Date()
                        ))
                        persistedSourceIDs.insert(source.id)
                        let result = try await database.importVideos(
                            sourceID: source.id,
                            discoveredVideos: discoveryResult.videos,
                            discoveryFailedCount: discoveryResult.failedCount
                        )
                        addedCount += result.addedCount
                        existingCount += result.existingCount
                        failedCount += result.failedCount
                        importedVideos.append(contentsOf: result.importedVideos)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failedCount += 1
                        if source.isNew, persistedSourceIDs.contains(source.id) == false {
                            disconnectSource(source.id)
                        }
                        AppLogger.library.error(
                            "Import item failed with category: \(String(describing: type(of: error)), privacy: .public)"
                        )
                    }
                }
                onImportStateChanged?(.importing(
                    title: title,
                    detail: "正在更新资料库…",
                    progress: 0.98
                ))
                try await refreshTags(libraryID: LibraryRecord.primaryID)
                try await refreshResolvedVideoURLs()
                try await refreshVisibleVideosNow()
                tagStateRevision += 1
                invalidateUndoHistoryUnlessVideoRemoval()
                startMediaProcessing(videos: importedVideos)
                guard importRevision == revision else { return }
                onImportStateChanged?(.completed(
                    addedCount: addedCount,
                    existingCount: existingCount,
                    failedCount: failedCount
                ))
                AppLogger.library.notice("Manual import completed with \(addedCount, privacy: .public) new videos")
            } catch is CancellationError {
                disconnectUnpersistedNewSources(sources, persistedSourceIDs: persistedSourceIDs)
                await refreshAfterInterruptedImportInFreshTask()
                guard importRevision == revision else { return }
                onImportStateChanged?(.cancelled)
            } catch {
                disconnectUnpersistedNewSources(sources, persistedSourceIDs: persistedSourceIDs)
                AppLogger.library.error("Manual import failed with category: \(String(describing: type(of: error)), privacy: .public)")
                await refreshAfterInterruptedImportInFreshTask()
                guard importRevision == revision else { return }
                onImportStateChanged?(.failed(message: "导入未完成；已经完整加入的视频会保留，请重试剩余内容。"))
            }
        }
    }

    private func disconnectUnpersistedNewSources(
        _ sources: [PendingImportSource],
        persistedSourceIDs: Set<String>
    ) {
        for source in sources where source.isNew && persistedSourceIDs.contains(source.id) == false {
            disconnectSource(source.id)
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
            invalidateUndoHistoryUnlessVideoRemoval()
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

    func moveTags(_ tags: [TagRecord], parentID: String?, sortOrder: Int) {
        let tagIDs = tags.map(\.id)
        mutateTags(actionName: tags.count > 1 ? "移动多个标签" : "移动标签") { database in
            try await database.moveTags(ids: tagIDs, parentID: parentID, sortOrder: sortOrder)
        }
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

    func removeVideos(ids: [String], completion: ((Bool) -> Void)? = nil) {
        let videoIDs = Array(Set(ids))
        guard videoIDs.isEmpty == false else {
            completion?(false)
            return
        }
        let previousTask = tagMutationTask
        let previousImportTask = importTask
        pendingTagMutationCount += 1
        tagMutationTask = Task { [weak self] in
            _ = await previousTask?.value
            _ = await previousImportTask?.value
            guard let self else { return }
            defer { pendingTagMutationCount -= 1 }
            do {
                let snapshot = try await database.removeVideos(ids: videoIDs)
                guard snapshot.videos.isEmpty == false else {
                    completion?(false)
                    return
                }
                for videoID in videoIDs { pendingMediaVideos.removeValue(forKey: videoID) }
                registerVideoRemovalUndo(snapshot)
                do {
                    try await refreshResolvedVideoURLs()
                    try await refreshTags(libraryID: LibraryRecord.primaryID)
                    try await refreshVisibleVideosNow()
                    onTagAssignmentsChanged?()
                } catch {
                    AppLogger.database.error(
                        "Video removal refresh failed with category: \(String(describing: type(of: error)), privacy: .public)"
                    )
                    onOperationError?("视频已从资料库移出，但列表未能刷新；重新启动应用后会显示最新结果。")
                }
                completion?(true)
            } catch {
                completion?(false)
                AppLogger.database.error("Video removal failed with category: \(String(describing: type(of: error)), privacy: .public)")
                onOperationError?("视频未能从资料库移出，请重试。")
            }
        }
    }

    func tagAssignmentStates(videoIDs: [String], completion: @escaping ([String: TagAssignmentState]) -> Void) {
        let tags = self.tags
        Task {
            let states = (try? await database.tagAssignmentStates(videoIDs: videoIDs, tags: tags)) ?? [:]
            completion(states)
        }
    }

    func undoLastMutation() {
        guard canUndoLastMutation else { return }
        undoManager.undo()
    }

    private func restoreRemovedVideos(_ snapshot: VideoRemovalSnapshot) {
        let previousTask = tagMutationTask
        pendingTagMutationCount += 1
        tagMutationTask = Task { [weak self] in
            _ = await previousTask?.value
            guard let self else { return }
            defer { pendingTagMutationCount -= 1 }
            do {
                let restoredVideoIDs = try await database.restoreVideos(snapshot)
                do {
                    try await refreshResolvedVideoURLs()
                    try await refreshTags(libraryID: LibraryRecord.primaryID)
                    try await refreshVisibleVideosNow()
                    onTagAssignmentsChanged?()
                } catch {
                    AppLogger.database.error(
                        "Video removal undo refresh failed with category: \(String(describing: type(of: error)), privacy: .public)"
                    )
                    onOperationError?("视频已经恢复，但列表未能刷新；重新启动应用后会显示最新结果。")
                }
                undoManager.removeAllActions()
                lastUndoMutation = nil
                onVideoRemovalRestored?(restoredVideoIDs)
            } catch {
                undoManager.removeAllActions()
                installVideoRemovalUndo(snapshot)
                AppLogger.database.error("Video removal undo failed with category: \(String(describing: type(of: error)), privacy: .public)")
                onOperationError?("撤回移出未完成，请重试。")
            }
        }
    }

    private func registerVideoRemovalUndo(_ snapshot: VideoRemovalSnapshot) {
        invalidateUndoHistory()
        installVideoRemovalUndo(snapshot)
    }

    private func installVideoRemovalUndo(_ snapshot: VideoRemovalSnapshot) {
        lastUndoMutation = .videoRemoval(snapshot)
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreRemovedVideos(snapshot)
        }
        undoManager.setActionName(snapshot.videos.count > 1 ? "移出多个视频" : "移出视频")
    }

    private func invalidateUndoHistoryUnlessVideoRemoval() {
        if case .videoRemoval = lastUndoMutation { return }
        invalidateUndoHistory()
    }

    private func invalidateUndoHistory() {
        let discardedRemoval: VideoRemovalSnapshot?
        if case let .videoRemoval(snapshot) = lastUndoMutation {
            discardedRemoval = snapshot
        } else {
            discardedRemoval = nil
        }
        undoManager.removeAllActions()
        lastUndoMutation = nil
        if let discardedRemoval {
            onVideoRemovalUndoDiscarded?()
            cleanupDiscardedRemoval(discardedRemoval)
        }
    }

    private func cleanupDiscardedRemoval(_ snapshot: VideoRemovalSnapshot) {
        let database = self.database
        let mediaService = self.mediaService
        let previousCleanupTask = artifactCleanupTask
        artifactCleanupTask = Task { [weak self] in
            _ = await previousCleanupTask?.value
            do {
                var removableThumbnailIDs: [String] = []
                for video in snapshot.videos {
                    if try await database.fetchVideo(id: video.id) == nil,
                       let thumbnailID = video.thumbnailID {
                        removableThumbnailIDs.append(thumbnailID)
                    }
                }
                try await mediaService?.removeThumbnails(identifiers: removableThumbnailIDs)
                let sourceIDs = snapshot.locations.map(\.sourceID)
                let removedSourceIDs = try await database.removeUnreferencedSourceAuthorizations(
                    candidateIDs: sourceIDs
                )
                for sourceID in removedSourceIDs { self?.disconnectSource(sourceID) }
            } catch {
                AppLogger.library.error(
                    "Removed video cleanup failed with category: \(String(describing: type(of: error)), privacy: .public)"
                )
            }
        }
    }

    private func connect(sourceID: String, url: URL) throws {
        if sourceURLs[sourceID]?.standardizedFileURL == url.standardizedFileURL,
           resources[sourceID] != nil { return }
        guard let resource = SecurityScopedResource(url: url) else {
            throw CocoaError(.fileReadNoPermission)
        }
        resources[sourceID] = resource
        sourceURLs[sourceID] = url
        updateWatcher(sourceID: sourceID, url: url)
    }

    private func updateWatcher(sourceID: String, url: URL) {
        let watchURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let watchPath = watchURL.standardizedFileURL.path
        let previousPath = sourceWatchPaths.updateValue(watchPath, forKey: sourceID)
        if let previousPath,
           previousPath != watchPath,
           sourceWatchPaths.values.contains(previousPath) == false {
            watchersByPath.removeValue(forKey: previousPath)?.stop()
        }
        guard watchersByPath[watchPath] == nil else { return }
        let watcher = FSEventsWatcher { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleMaintenance() }
        }
        watchersByPath[watchPath] = watcher
        watcher.start(watching: watchURL)
    }

    private func disconnectSource(_ sourceID: String) {
        resources.removeValue(forKey: sourceID)
        sourceURLs.removeValue(forKey: sourceID)
        sourceBookmarks.removeValue(forKey: sourceID)
        guard let watchPath = sourceWatchPaths.removeValue(forKey: sourceID),
              sourceWatchPaths.values.contains(watchPath) == false else { return }
        watchersByPath.removeValue(forKey: watchPath)?.stop()
    }

    private func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func prepareImportSource(for url: URL) throws -> PendingImportSource {
        let existingSourceID = sourceURLs.first {
            $0.value.standardizedFileURL == url.standardizedFileURL
        }?.key
        let sourceID = existingSourceID ?? UUID().uuidString

        let bookmark: Data
        do {
            bookmark = try makeBookmark(for: url)
        } catch {
            AppLogger.library.error(
                "Import bookmark creation failed with category: \(String(describing: type(of: error)), privacy: .public)"
            )
            throw error
        }

        let authorizedURL: URL
        do {
            var isStale = false
            authorizedURL = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            AppLogger.library.error(
                "Import bookmark resolution failed with category: \(String(describing: type(of: error)), privacy: .public)"
            )
            throw error
        }

        do {
            try connect(sourceID: sourceID, url: authorizedURL)
        } catch {
            AppLogger.library.error(
                "Import scoped access failed with category: \(String(describing: type(of: error)), privacy: .public)"
            )
            throw error
        }

        sourceBookmarks[sourceID] = bookmark
        return PendingImportSource(
            id: sourceID,
            url: authorizedURL,
            bookmark: bookmark,
            isNew: existingSourceID == nil
        )
    }

    private func scheduleMaintenance() {
        maintenanceDebounceTask?.cancel()
        maintenanceDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                self?.startMaintenance()
            } catch {}
        }
    }

    private func startMaintenance() {
        guard sourceURLs.isEmpty == false else { return }
        maintenanceTask?.cancel()
        let discovery = self.discovery
        let database = self.database
        maintenanceTask = Task(priority: .utility) { [weak self] in
            do {
                guard let self else { return }
                await refreshSourceURLsFromBookmarks()
                let sources = sourceURLs
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

    private func refreshSourceURLsFromBookmarks() async {
        let bookmarks = sourceBookmarks
        for (sourceID, bookmark) in bookmarks {
            do {
                var isStale = false
                let resolvedURL = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                let locationChanged = sourceURLs[sourceID]?.standardizedFileURL != resolvedURL.standardizedFileURL
                guard locationChanged || isStale else { continue }
                try connect(sourceID: sourceID, url: resolvedURL)
                let refreshedBookmark = isStale ? try makeBookmark(for: resolvedURL) : bookmark
                sourceBookmarks[sourceID] = refreshedBookmark
                try await database.saveSourceAuthorization(SourceAuthorizationRecord(
                    id: sourceID,
                    libraryID: LibraryRecord.primaryID,
                    displayName: resolvedURL.lastPathComponent,
                    rootBookmarkData: refreshedBookmark,
                    createdAt: Date()
                ))
            } catch {
                AppLogger.library.error(
                    "Source bookmark refresh failed with category: \(String(describing: type(of: error)), privacy: .public)"
                )
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
                    } else if let thumbnailID = result.thumbnailID {
                        try? await mediaService.removeThumbnails(identifiers: [thumbnailID])
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
        let previousImportTask = importTask
        pendingTagMutationCount += 1
        tagMutationTask = Task { [weak self] in
            _ = await previousTask?.value
            _ = await previousImportTask?.value
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
                invalidateUndoHistory()
                if tagStateRevision == startingRevision {
                    undoManager.registerUndo(withTarget: self) { target in
                        target.restoreTagState(snapshot)
                    }
                    undoManager.setActionName(actionName)
                    lastUndoMutation = .tag
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
                invalidateUndoHistory()
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
