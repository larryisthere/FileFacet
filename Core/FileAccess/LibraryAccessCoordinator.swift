import AppKit
import Foundation

enum FolderImportMethod: Equatable, Sendable {
    case direct
    case folderTags(includeSelectedRoot: Bool)
}

enum LibraryImportState: Equatable, Sendable {
    case idle
    case importing(title: String, detail: String, progress: Double?)
    case completed(LibraryImportSummary)
    case cancelled
    case failed(message: String)
}

enum LibraryOperationStatus: Equatable, Sendable {
    case relinkSucceeded(filename: String)
    case relinkExisting(existingVideoID: String, isUnavailable: Bool)
    case relinkFailed(videoID: String, message: String)
}

struct LibraryImportSummary: Equatable, Sendable {
    let title: String
    let addedCount: Int
    let existingCount: Int
    let failedVideoCount: Int
    let failedInputCount: Int
    let addedVideoIDs: [String]
    let existingVideoIDs: [String]
    let checkedInputCount: Int
    let checkedFolderCount: Int
    let createdFolderTagCount: Int
}

private struct LibraryImportRequest {
    let roots: [VideoImportRoot]
    let title: String
    let completionTitle: String
    let initialDetail: String
    let inputCount: Int
    let folderCount: Int
    let method: FolderImportMethod
}

private enum LibraryImportEntryPoint: Equatable {
    case picker
    case drop

    var emptyMessage: String {
        switch self {
        case .picker: String(localized: .importNoContentPicker)
        case .drop: String(localized: .importNoContentDrop)
        }
    }

    var completionTitle: String {
        switch self {
        case .picker: String(localized: .importCompletedPicker)
        case .drop: String(localized: .importCompletedDrop)
        }
    }

    func title(for plan: VideoImportPlan) -> String {
        if plan.roots.count == 1, let root = plan.roots.first {
            return String(localized: .importProgressNamedItem(root.url.lastPathComponent))
        }
        if plan.fileCount > 0, plan.folderCount > 0 {
            return self == .picker
                ? String(localized: .importProgressPickerItems(plan.acceptedInputCount))
                : String(localized: .importProgressDropItems(plan.acceptedInputCount))
        }
        if plan.folderCount > 0 {
            return self == .picker
                ? String(localized: .importProgressPickerFolders(plan.folderCount))
                : String(localized: .importProgressDropFolders(plan.folderCount))
        }
        return self == .picker
            ? String(localized: .importProgressPickerVideos(plan.fileCount))
            : String(localized: .importProgressDropVideos(plan.fileCount))
    }
}

private struct PendingImportSource {
    let id: String
    let url: URL
    let bookmark: Data
    let isNew: Bool
    let kind: VideoImportRootKind
    let requestIndex: Int
}

private struct VideoAccessResolution: Sendable {
    let resolvedURLs: [String: URL]
    let offlineSourceNames: [String: String]
    let accessLostSourceNames: [String: String]
    let reachableSourceIDs: Set<String>
    let fallbackUpdates: [VideoLocationFallbackUpdate]
    let confirmedMissingLocations: [VideoLocationRecord]
}

private enum LastUndoMutation {
    case tag
    case videoRemoval(VideoRemovalSnapshot)
}

private enum RelinkConfirmationChoice {
    case reselect
    case connect
    case cancel
}

private enum RelinkFlowError: Error {
    case invalidVideo
    case fileChangedDuringReview
}

@MainActor
final class LibraryAccessCoordinator {
    private let database: DatabaseStore
    private let picker: LibraryPicker
    private let discovery: any VideoFileDiscovering
    private let resolveFolderImportMethod: @MainActor () async -> FolderImportMethod?
    private let mediaService: MediaProcessingService?
    private var resources: [String: SecurityScopedResource] = [:]
    private var sourceURLs: [String: URL] = [:]
    private var knownSourceURLs: [String: URL] = [:]
    private var sourceBookmarks: [String: Data] = [:]
    private var sourceDisplayNames: [String: String] = [:]
    private var watchersByPath: [String: FSEventsWatcher] = [:]
    private var sourceWatchPaths: [String: String] = [:]
    private var resolvedVideoURLs: [String: URL] = [:]
    private var lastKnownVideoPaths: [String: String] = [:]
    private var offlineSourceNameByVideoID: [String: String] = [:]
    private var accessLostSourceNameByVideoID: [String: String] = [:]
    private var reachableSourceIDs = Set<String>()
    private var importTask: Task<Void, Never>?
    private var relinkTask: Task<Void, Never>?
    private var relinkingVideoID: String?
    private var importRevision = 0
    private var maintenanceTask: Task<Void, Never>?
    private var maintenanceDebounceTask: Task<Void, Never>?
    private var volumeAvailabilityTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    private var mediaFactsRefreshTask: Task<Void, Never>?
    private var mediaFactsRefreshRevision = 0
    private var artifactCleanupTask: Task<Void, Never>?
    private var pendingMediaVideos: [String: VideoRecord] = [:]
    private var queryTask: Task<Void, Never>?
    private var smartCollectionTask: Task<Void, Never>?
    private var tagMutationTask: Task<Void, Never>?
    private var pendingTagMutationCount = 0
    private var tagStateRevision = 0
    private var tags: [TagRecord] = []
    private var smartCollections: [SmartCollectionRecord] = []
    private var currentFilter: LibraryFilter = .all
    private var currentSearch = ""
    private var currentRule = LibraryQueryRule.standard

    var onVideosChanged: (([VideoRecord]) -> Void)?
    var onSidebarFilterCountsChanged: ((SidebarFilterCounts) -> Void)?
    var onFilterChangedBySystem: ((LibraryFilter) -> Void)?
    var onVideoChanged: ((VideoRecord) -> Void)?
    var onImportStateChanged: ((LibraryImportState) -> Void)?
    var onTagsChanged: (([TagRecord]) -> Void)?
    var onSmartCollectionsChanged: (([SmartCollectionRecord]) -> Void)?
    var onTagAssignmentsChanged: (() -> Void)?
    var onError: ((String) -> Void)?
    var onOperationError: ((String) -> Void)?
    var onOperationStatusChanged: ((LibraryOperationStatus?) -> Void)?
    var onRelinkingVideoChanged: ((String?) -> Void)?
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
        discovery: any VideoFileDiscovering = VideoFileDiscovery(),
        resolveFolderImportMethod: @escaping @MainActor () async -> FolderImportMethod? = {
            .direct
        }
    ) {
        self.database = database
        self.picker = picker
        self.discovery = discovery
        self.resolveFolderImportMethod = resolveFolderImportMethod
        mediaService = try? MediaProcessingService()
    }

    func restoreLibrary() {
        Task { [self] in
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
                    sourceBookmarks[source.id] = source.rootBookmarkData
                    sourceDisplayNames[source.id] = source.displayName
                    do {
                        var isStale = false
                        let url = try URL(
                            resolvingBookmarkData: source.rootBookmarkData,
                            options: [.withSecurityScope, .withoutUI, .withoutMounting],
                            relativeTo: nil,
                            bookmarkDataIsStale: &isStale
                        )
                        knownSourceURLs[source.id] = url
                        try connect(sourceID: source.id, url: url)
                        if isStale {
                            let refreshedBookmark = try makeBookmark(for: url)
                            sourceBookmarks[source.id] = refreshedBookmark
                            sourceDisplayNames[source.id] = url.lastPathComponent
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
                try await refreshTags(libraryID: LibraryRecord.primaryID)
                try await refreshResolvedVideoURLs()
                try await refreshVisibleVideosNow()
                let existingVideos = try await database.fetchVideos(libraryID: LibraryRecord.primaryID)
                startMediaProcessing(videos: existingVideos)
                if sourceURLs.isEmpty == false { scheduleMaintenance() }
            } catch {
                AppLogger.library.error("Library restore failed with category: \(String(describing: type(of: error)), privacy: .public)")
                onError?(String(localized: .importVideoIndexRead))
            }
        }
    }

    func importVideos() {
        guard let urls = picker.chooseImportItems() else { return }
        Task { [weak self] in
            await self?.importItems(urls, entryPoint: .picker)
        }
    }

    func importDroppedItems(_ urls: [URL]) {
        Task { [weak self] in
            await self?.importItems(urls, entryPoint: .drop)
        }
    }

    private func importItems(_ urls: [URL], entryPoint: LibraryImportEntryPoint) async {
        let plan = VideoFileDiscovery.importPlan(for: urls)
        guard plan.roots.isEmpty == false else {
            discardVideoRemovalUndo()
            onImportStateChanged?(.failed(message: entryPoint.emptyMessage))
            return
        }
        let method: FolderImportMethod
        if plan.folderCount > 0 {
            guard let resolvedMethod = await resolveFolderImportMethod() else { return }
            method = resolvedMethod
        } else {
            method = .direct
        }
        let initialDetail: String
        if plan.collapsedInputCount > 0 {
            initialDetail = plan.collapsedInputCount == 1
                ? String(localized: .importProgressMergedOne(plan.roots.count))
                : String(
                    localized: .importProgressMergedMultiple(
                        plan.collapsedInputCount,
                        plan.roots.count
                    )
                )
        } else if plan.roots.count == 1, let root = plan.roots.first {
            initialDetail = root.kind == .directory
                ? String(localized: .importProgressScanningFolder)
                : String(localized: .importProgressCheckingVideo)
        } else {
            initialDetail = String(localized: .importProgressProcessing(plan.roots.count))
        }
        discardVideoRemovalUndo()
        runImport(LibraryImportRequest(
            roots: plan.roots,
            title: entryPoint.title(for: plan),
            completionTitle: entryPoint.completionTitle,
            initialDetail: initialDetail,
            inputCount: plan.roots.count,
            folderCount: plan.roots.filter { $0.kind == .directory }.count,
            method: method
        ))
    }

    private func runImport(_ request: LibraryImportRequest) {
        var preparationFailedCount = 0
        var sources: [PendingImportSource] = []
        for (index, root) in request.roots.enumerated() {
            do {
                sources.append(try prepareImportSource(for: root, requestIndex: index))
            } catch {
                preparationFailedCount += 1
            }
        }
        guard let initialSource = sources.first else {
            onImportStateChanged?(.failed(message: String(localized: .importPermission)))
            return
        }
        importTask?.cancel()
        importRevision += 1
        let revision = importRevision
        let previousMutationTask = tagMutationTask
        let previousCleanupTask = artifactCleanupTask
        onImportStateChanged?(.importing(title: request.title, detail: request.initialDetail, progress: nil))
        let discovery = self.discovery
        let database = self.database
        importTask = Task { [weak self] in
            _ = await previousMutationTask?.value
            _ = await previousCleanupTask?.value
            guard let self else { return }
            discardVideoRemovalUndo()
            var persistedSourceIDs = Set<String>()
            defer {
                if importRevision == revision { importTask = nil }
            }
            do {
                if try await database.fetchPrimaryLibrary() == nil {
                    try await database.saveLibrary(LibraryRecord(
                        id: LibraryRecord.primaryID,
                        name: AppConfiguration.internalName,
                        rootBookmarkData: initialSource.bookmark,
                        createdAt: Date(),
                        lastScanAt: nil
                    ))
                }
                var addedCount = 0
                var existingCount = 0
                var failedVideoCount = 0
                var failedInputCount = preparationFailedCount
                var importedVideos: [VideoRecord] = []
                var addedVideoIDs: [String] = []
                var existingVideoIDs: [String] = []
                var createdFolderTagIDs = Set<String>()
                for (sourceIndex, source) in sources.enumerated() {
                    try Task.checkCancellation()
                    let sourceProgress = Double(sourceIndex) / Double(sources.count)
                    onImportStateChanged?(.importing(
                        title: request.title,
                        detail: request.inputCount == 1
                            ? (
                                source.kind == .directory
                                    ? String(localized: .importProgressScanningFolder)
                                    : String(localized: .importProgressCheckingVideo)
                            )
                            : String(
                                localized: .importProgressScanningPosition(
                                    source.requestIndex + 1,
                                    request.inputCount
                                )
                            ),
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
                            title: request.title,
                            detail: request.inputCount == 1
                                ? String(localized: .importProgressSaving)
                                : String(
                                    localized: .importProgressSavingPosition(
                                        source.requestIndex + 1,
                                        request.inputCount
                                    )
                                ),
                            progress: (Double(sourceIndex) + 0.5) / Double(sources.count)
                        ))
                        try await database.saveSourceAuthorization(SourceAuthorizationRecord(
                            id: source.id,
                            libraryID: LibraryRecord.primaryID,
                            displayName: source.url.lastPathComponent,
                            rootBookmarkData: source.bookmark,
                            createdAt: Date()
                        ))
                        sourceDisplayNames[source.id] = source.url.lastPathComponent
                        persistedSourceIDs.insert(source.id)
                        let folderTagOptions: FolderTagImportOptions?
                        if source.kind == .directory,
                           case let .folderTags(includeSelectedRoot) = request.method {
                            folderTagOptions = FolderTagImportOptions(
                                selectedRootName: includeSelectedRoot
                                    ? source.url.lastPathComponent
                                    : nil
                            )
                        } else {
                            folderTagOptions = nil
                        }
                        let result = try await database.importVideos(
                            sourceID: source.id,
                            discoveredVideos: discoveryResult.videos,
                            discoveryFailedCount: discoveryResult.failedCount,
                            folderTagOptions: folderTagOptions
                        )
                        addedCount += result.addedCount
                        existingCount += result.existingCount
                        failedVideoCount += result.failedCount
                        addedVideoIDs.append(contentsOf: result.addedVideoIDs)
                        existingVideoIDs.append(contentsOf: result.existingVideoIDs)
                        importedVideos.append(contentsOf: result.importedVideos)
                        createdFolderTagIDs.formUnion(result.createdFolderTagIDs)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failedInputCount += 1
                        if source.isNew, persistedSourceIDs.contains(source.id) == false {
                            disconnectSource(source.id)
                        }
                        AppLogger.library.error(
                            "Import item failed with category: \(String(describing: type(of: error)), privacy: .public)"
                        )
                    }
                }
                onImportStateChanged?(.importing(
                    title: request.title,
                    detail: String(localized: .importProgressUpdating),
                    progress: 0.98
                ))
                try await refreshTags(libraryID: LibraryRecord.primaryID)
                try await refreshResolvedVideoURLs()
                try await refreshVisibleVideosNow()
                onTagAssignmentsChanged?()
                tagStateRevision += 1
                invalidateUndoHistoryUnlessVideoRemoval()
                startMediaProcessing(videos: importedVideos)
                guard importRevision == revision else { return }
                let uniqueAddedVideoIDs = stableUniqueVideoIDs(addedVideoIDs)
                let addedVideoIDSet = Set(uniqueAddedVideoIDs)
                let uniqueExistingVideoIDs = stableUniqueVideoIDs(existingVideoIDs)
                    .filter { addedVideoIDSet.contains($0) == false }
                onImportStateChanged?(.completed(LibraryImportSummary(
                    title: request.completionTitle,
                    addedCount: addedCount,
                    existingCount: existingCount,
                    failedVideoCount: failedVideoCount,
                    failedInputCount: failedInputCount,
                    addedVideoIDs: uniqueAddedVideoIDs,
                    existingVideoIDs: uniqueExistingVideoIDs,
                    checkedInputCount: request.inputCount,
                    checkedFolderCount: request.folderCount,
                    createdFolderTagCount: createdFolderTagIDs.count
                )))
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
                onImportStateChanged?(.failed(message: String(localized: .importFailedDetail)))
            }
        }
    }

    private func stableUniqueVideoIDs(_ videoIDs: [String]) -> [String] {
        var seen = Set<String>()
        return videoIDs.filter { seen.insert($0).inserted }
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
            onTagAssignmentsChanged?()
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

    func applyQuery(_ query: LibraryQueryRequest, debounceSearch: Bool = false) {
        currentFilter = query.baseFilter
        currentSearch = query.temporaryFilenameSearch
        currentRule = query.rule.normalized()
        refreshVisibleVideos(
            debounceNanoseconds: debounceSearch ? 150_000_000 : 0
        )
    }

    func createSmartCollection(
        name: String,
        rule: LibraryQueryRule,
        completion: @escaping (SmartCollectionRecord?) -> Void
    ) {
        let now = Date()
        let nextOrder = (smartCollections.map(\.sortOrder).max() ?? -1) + 1
        persistSmartCollection(
            SmartCollectionRecord(
                id: UUID().uuidString,
                libraryID: LibraryRecord.primaryID,
                name: name,
                rule: rule.normalized(),
                sortOrder: nextOrder,
                createdAt: now,
                updatedAt: now
            ),
            completion: completion
        )
    }

    func updateSmartCollection(
        id: String,
        name: String? = nil,
        rule: LibraryQueryRule? = nil,
        completion: @escaping (SmartCollectionRecord?) -> Void
    ) {
        guard var record = smartCollections.first(where: { $0.id == id }) else {
            completion(nil)
            return
        }
        if let name { record.name = name }
        if let rule { record.rule = rule.normalized() }
        record.updatedAt = Date()
        persistSmartCollection(record, completion: completion)
    }

    func deleteSmartCollection(id: String, completion: @escaping (Bool) -> Void) {
        let previousTask = smartCollectionTask
        smartCollectionTask = Task { [weak self] in
            _ = await previousTask?.value
            guard let self else {
                completion(false)
                return
            }
            do {
                try await database.deleteSmartCollection(id: id)
                try await refreshSmartCollections(libraryID: LibraryRecord.primaryID)
                completion(true)
            } catch {
                AppLogger.database.error(
                    "Smart collection deletion failed with category: \(String(describing: type(of: error)), privacy: .public)"
                )
                onOperationError?(String(localized: .errorDatabaseOperation))
                completion(false)
            }
        }
    }

    private func persistSmartCollection(
        _ record: SmartCollectionRecord,
        completion: @escaping (SmartCollectionRecord?) -> Void
    ) {
        let previousTask = smartCollectionTask
        smartCollectionTask = Task { [weak self] in
            _ = await previousTask?.value
            guard let self else {
                completion(nil)
                return
            }
            do {
                try await database.saveSmartCollection(record)
                try await refreshSmartCollections(libraryID: LibraryRecord.primaryID)
                completion(smartCollections.first(where: { $0.id == record.id }))
            } catch {
                AppLogger.database.error(
                    "Smart collection persistence failed with category: \(String(describing: type(of: error)), privacy: .public)"
                )
                onOperationError?(String(localized: .errorDatabaseOperation))
                completion(nil)
            }
        }
    }

    func refreshVolumeAvailability(interruptMediaProcessing: Bool) {
        volumeAvailabilityTask?.cancel()
        let interruptedMediaTask = interruptMediaProcessing ? mediaTask : nil
        if interruptMediaProcessing {
            interruptedMediaTask?.cancel()
            mediaTask = nil
            pendingMediaVideos.removeAll()
        }
        volumeAvailabilityTask = Task { [weak self] in
            guard let self else { return }
            _ = await interruptedMediaTask?.value
            resetRuntimeSourceConnections()
            await refreshSourceURLsFromBookmarks()
            do {
                try Task.checkCancellation()
                try await refreshResolvedVideoURLs()
                try await refreshVisibleVideosNow()
                let videos = try await database.fetchVideos(libraryID: LibraryRecord.primaryID)
                startMediaProcessing(videos: videos)
                if reachableSourceIDs.isEmpty == false {
                    scheduleMaintenance()
                }
            } catch is CancellationError {
                return
            } catch {
                AppLogger.library.error(
                    "Volume availability refresh failed with category: \(String(describing: type(of: error)), privacy: .public)"
                )
            }
        }
    }

    func fileURL(for video: VideoRecord) -> URL? {
        resolvedVideoURLs[video.id]
    }

    func displayPath(for video: VideoRecord) -> String? {
        resolvedVideoURLs[video.id]?.path ?? lastKnownVideoPaths[video.id]
    }

    func offlineSourceName(for video: VideoRecord) -> String? {
        offlineSourceNameByVideoID[video.id]
    }

    func thumbnailURL(for video: VideoRecord) -> URL? {
        guard let thumbnailID = video.thumbnailID else { return nil }
        return mediaService?.thumbnailURL(for: thumbnailID)
    }

    func createTag(name: String, parentID: String?) {
        mutateTags(actionName: String(localized: .tagActionCreate)) { database in
            _ = try await database.createTag(libraryID: LibraryRecord.primaryID, name: name, parentID: parentID)
        }
    }

    func renameTag(_ tag: TagRecord, name: String) {
        mutateTags(actionName: String(localized: .tagActionRename)) { database in
            try await database.renameTag(id: tag.id, name: name)
        }
    }

    func deleteTag(_ tag: TagRecord) {
        mutateTags(actionName: String(localized: .tagActionDelete)) { database in
            try await database.deleteTag(id: tag.id)
        }
    }

    func moveTags(_ tags: [TagRecord], parentID: String?, sortOrder: Int) {
        let tagIDs = tags.map(\.id)
        let actionName = tags.count > 1
            ? String(localized: .tagActionMoveMultiple)
            : String(localized: .tagActionMove)
        mutateTags(actionName: actionName) { database in
            try await database.moveTags(ids: tagIDs, parentID: parentID, sortOrder: sortOrder)
        }
    }

    func setTagColor(_ tag: TagRecord, color: String?) {
        mutateTags(actionName: String(localized: .tagActionSetColor)) { database in
            try await database.setTagColor(id: tag.id, color: color)
        }
    }

    func mergeTag(_ source: TagRecord, into target: TagRecord) {
        mutateTags(actionName: String(localized: .tagActionMerge)) { database in
            try await database.mergeTag(sourceID: source.id, targetID: target.id)
        }
    }

    func setTagAssignment(
        _ tag: TagRecord,
        videoIDs: [String],
        enabled: Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        let actionName = enabled
            ? String(localized: .tagActionAdd)
            : String(localized: .tagActionRemove)
        mutateTags(actionName: actionName) { database in
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
        mutateTags(actionName: String(localized: .tagActionApply)) { database in
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
        mutateTags(actionName: String(localized: .tagActionApply)) { database in
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
                    onOperationError?(String(localized: .errorRemoveRefresh))
                }
                completion?(true)
            } catch {
                completion?(false)
                AppLogger.database.error("Video removal failed with category: \(String(describing: type(of: error)), privacy: .public)")
                onOperationError?(String(localized: .errorRemove))
            }
        }
    }

    func relinkVideo(_ video: VideoRecord, completion: ((Bool) -> Void)? = nil) {
        guard video.availability == .unavailable,
              relinkTask == nil else {
            completion?(false)
            return
        }

        relinkingVideoID = video.id
        onRelinkingVideoChanged?(video.id)
        let previousImportTask = importTask
        relinkTask = Task { [weak self] in
            _ = await previousImportTask?.value
            guard let self else { return }
            let succeeded = await performRelink(video)
            relinkingVideoID = nil
            relinkTask = nil
            onRelinkingVideoChanged?(nil)
            completion?(succeeded)
        }
    }

    func retryRelinkVideo(id videoID: String) {
        guard relinkTask == nil else { return }
        Task { [weak self] in
            guard let self, let video = try? await database.fetchVideo(id: videoID) else { return }
            relinkVideo(presentedVideo(video))
        }
    }

    private func performRelink(_ video: VideoRecord) async -> Bool {
        while true {
            guard let url = picker.chooseVideoForRelinking(filename: video.filename),
                  let root = VideoFileDiscovery.importRoot(for: url),
                  root.kind == .videoFile else {
                onOperationStatusChanged?(nil)
                return false
            }

            onOperationStatusChanged?(nil)
            var preparedSource: PendingImportSource?
            var sourceWasPersisted = false
            do {
                let source = try prepareImportSource(
                    for: root,
                    requestIndex: 0,
                    forceNewSource: true
                )
                preparedSource = source
                let discovery = self.discovery
                let candidate: DiscoveredVideo
                do {
                    let discoveryResult = try await Task.detached(priority: .utility) {
                        try discovery.discoverVideoResult(at: source.url)
                    }.value
                    guard discoveryResult.failedCount == 0,
                          discoveryResult.videos.count == 1,
                          let discoveredCandidate = discoveryResult.videos.first else {
                        throw RelinkFlowError.invalidVideo
                    }
                    candidate = discoveredCandidate
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw RelinkFlowError.invalidVideo
                }

                let allowAvailableRecord = video.unavailableReason == .accessLost
                if let existingVideoID = try await database.existingRelinkVideoID(
                    id: video.id,
                    sourceID: source.id,
                    discoveredVideo: candidate,
                    allowAvailableRecord: allowAvailableRecord
                ) {
                    disconnectSource(source.id)
                    await showExistingRelinkResult(existingVideoID: existingVideoID)
                    return false
                }

                let discoveredVideo: DiscoveredVideo
                do {
                    let fingerprint = try await Task.detached(priority: .utility) {
                        try contentFingerprint(for: source.url)
                    }.value
                    discoveredVideo = candidate.withContentFingerprint(fingerprint)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw RelinkFlowError.invalidVideo
                }

                let assessment = try await database.assessRelinkVideo(
                    id: video.id,
                    sourceID: source.id,
                    discoveredVideo: discoveredVideo,
                    allowAvailableRecord: allowAvailableRecord
                )
                if case let .existingRecord(existingVideoID) = assessment {
                    disconnectSource(source.id)
                    await showExistingRelinkResult(existingVideoID: existingVideoID)
                    return false
                }

                let inspection: VideoMediaInspection
                do {
                    guard let mediaService else {
                        throw RelinkFlowError.invalidVideo
                    }
                    inspection = try await mediaService.inspectVideo(fileURL: source.url)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw RelinkFlowError.invalidVideo
                }

                var allowContentMismatch = false
                if assessment == .needsConfirmation {
                    let choice = await presentRelinkConfirmation(
                        original: video,
                        candidate: discoveredVideo,
                        inspection: inspection
                    )
                    switch choice {
                    case .cancel:
                        disconnectSource(source.id)
                        onOperationStatusChanged?(nil)
                        return false
                    case .reselect:
                        disconnectSource(source.id)
                        onOperationStatusChanged?(nil)
                        continue
                    case .connect:
                        allowContentMismatch = true
                    }
                }

                let confirmedFingerprint: Data
                do {
                    confirmedFingerprint = try await Task.detached(priority: .utility) {
                        try contentFingerprint(for: source.url)
                    }.value
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw RelinkFlowError.fileChangedDuringReview
                }
                guard let assessedFingerprint = discoveredVideo.contentFingerprint,
                      confirmedFingerprint == assessedFingerprint else {
                    throw RelinkFlowError.fileChangedDuringReview
                }

                try await database.saveSourceAuthorization(SourceAuthorizationRecord(
                    id: source.id,
                    libraryID: LibraryRecord.primaryID,
                    displayName: source.url.lastPathComponent,
                    rootBookmarkData: source.bookmark,
                    createdAt: Date()
                ))
                sourceWasPersisted = true
                sourceDisplayNames[source.id] = source.url.lastPathComponent
                let restored = try await database.relinkVideo(
                    id: video.id,
                    sourceID: source.id,
                    discoveredVideo: discoveredVideo,
                    allowAvailableRecord: allowAvailableRecord,
                    allowContentMismatch: allowContentMismatch
                )
                resolvedVideoURLs[restored.id] = source.url
                lastKnownVideoPaths[restored.id] = source.url.standardizedFileURL.path
                do {
                    try await refreshResolvedVideoURLs()
                    try await refreshTags(libraryID: LibraryRecord.primaryID)
                    try await refreshVisibleVideosNow()
                    onTagAssignmentsChanged?()
                } catch {
                    AppLogger.database.error(
                        "Video relink refresh failed with category: \(String(describing: type(of: error)), privacy: .public)"
                    )
                    onVideoChanged?(presentedVideo(restored))
                }
                startMediaProcessing(videos: [restored])
                onOperationStatusChanged?(.relinkSucceeded(filename: restored.filename))
                return true
            } catch is CancellationError {
                await cleanupRelinkSource(preparedSource, wasPersisted: sourceWasPersisted)
                onOperationStatusChanged?(nil)
                return false
            } catch let DatabaseError.relinkExistingRecord(existingVideoID) {
                await cleanupRelinkSource(preparedSource, wasPersisted: sourceWasPersisted)
                await showExistingRelinkResult(existingVideoID: existingVideoID)
                return false
            } catch {
                await cleanupRelinkSource(preparedSource, wasPersisted: sourceWasPersisted)
                let nsError = error as NSError
                AppLogger.library.error(
                    "Video relink failed with domain: \(nsError.domain, privacy: .public), code: \(nsError.code, privacy: .public), category: \(String(describing: type(of: error)), privacy: .public)"
                )
                let message: String
                switch error {
                case RelinkFlowError.invalidVideo:
                    message = String(
                        localized: "unavailable.relink.invalidFile",
                        defaultValue: "The selected file could not be read completely or parsed as a valid video."
                    )
                case RelinkFlowError.fileChangedDuringReview:
                    message = String(
                        localized: "unavailable.relink.fileChanged",
                        defaultValue: "The selected file changed while it was being reviewed. Choose it again and retry."
                    )
                default:
                    message = String(
                        localized: "error.relinkVideo",
                        defaultValue: "The video could not be relinked. Choose the matching video and try again."
                    )
                }
                onOperationStatusChanged?(.relinkFailed(videoID: video.id, message: message))
                return false
            }
        }
    }

    private func showExistingRelinkResult(existingVideoID: String) async {
        let existingVideo = try? await database.fetchVideo(id: existingVideoID)
        let isUnavailable = existingVideo.map {
            presentedVideo($0).availability != .available
        } ?? false
        onOperationStatusChanged?(.relinkExisting(
            existingVideoID: existingVideoID,
            isUnavailable: isUnavailable
        ))
    }

    private func cleanupRelinkSource(
        _ source: PendingImportSource?,
        wasPersisted: Bool
    ) async {
        guard let source else { return }
        if wasPersisted {
            _ = try? await database.removeUnreferencedSourceAuthorizations(candidateIDs: [source.id])
        }
        disconnectSource(source.id)
    }

    private func presentRelinkConfirmation(
        original: VideoRecord,
        candidate: DiscoveredVideo,
        inspection: VideoMediaInspection
    ) async -> RelinkConfirmationChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "unavailable.relink.confirmation.title",
            defaultValue: "The selected file does not completely match the original record"
        )
        alert.informativeText = String(
            localized: "unavailable.relink.confirmation.detail",
            defaultValue: "FileFacet cannot confirm that these are the same video. Review the differences below."
        )

        let fieldTitle = String(
            localized: "unavailable.relink.confirmation.field",
            defaultValue: "Field"
        )
        let originalTitle = String(
            localized: "unavailable.relink.confirmation.original",
            defaultValue: "Original Record"
        )
        let selectedTitle = String(
            localized: "unavailable.relink.confirmation.selected",
            defaultValue: "Selected File"
        )
        var rows: [[NSView]] = [[
            relinkDifferenceLabel(fieldTitle, emphasized: true),
            relinkDifferenceLabel(originalTitle, emphasized: true),
            relinkDifferenceLabel(selectedTitle, emphasized: true),
        ]]

        let comparisons: [(String, String, String)] = [
            (
                String(localized: "unavailable.relink.confirmation.filename", defaultValue: "Filename"),
                original.filename,
                candidate.filename
            ),
            (
                String(localized: "unavailable.relink.confirmation.duration", defaultValue: "Duration"),
                relinkDuration(original.duration),
                relinkDuration(inspection.duration)
            ),
            (
                String(localized: "unavailable.relink.confirmation.resolution", defaultValue: "Resolution"),
                relinkResolution(width: original.width, height: original.height),
                relinkResolution(width: inspection.width, height: inspection.height)
            ),
            (
                String(localized: "unavailable.relink.confirmation.size", defaultValue: "Size"),
                relinkFileSize(original.fileSize),
                relinkFileSize(candidate.fileSize)
            ),
        ]
        for comparison in comparisons where comparison.1 != comparison.2 {
            rows.append([
                relinkDifferenceLabel(comparison.0, emphasized: false),
                relinkDifferenceLabel(comparison.1, emphasized: false),
                relinkDifferenceLabel(comparison.2, emphasized: false),
            ])
        }

        let accessoryStack = NSStackView()
        accessoryStack.orientation = .vertical
        accessoryStack.alignment = .leading
        accessoryStack.spacing = 12
        if rows.count > 1 {
            let grid = NSGridView(views: rows)
            grid.rowSpacing = 7
            grid.columnSpacing = 18
            for columnIndex in 0..<3 {
                grid.column(at: columnIndex).xPlacement = .leading
            }
            accessoryStack.addArrangedSubview(grid)
        } else {
            let message = NSTextField(wrappingLabelWithString: String(
                localized: "unavailable.relink.confirmation.noVisibleDifference",
                defaultValue: "The available information shows no obvious difference, but the video content still cannot be confirmed."
            ))
            message.textColor = .secondaryLabelColor
            accessoryStack.addArrangedSubview(message)
            message.widthAnchor.constraint(equalToConstant: 500).isActive = true
        }
        let promise = NSTextField(wrappingLabelWithString: String(
            localized: "unavailable.relink.confirmation.promise",
            defaultValue: "If you continue, original tags and the first-added date are preserved. Media information, thumbnail, file identity, and location are updated from the selected file."
        ))
        promise.textColor = .secondaryLabelColor
        accessoryStack.addArrangedSubview(promise)
        promise.widthAnchor.constraint(equalToConstant: 500).isActive = true
        alert.accessoryView = accessoryStack

        alert.addButton(withTitle: String(
            localized: "unavailable.relink.confirmation.reselect",
            defaultValue: "Choose Again"
        ))
        alert.addButton(withTitle: String(
            localized: "unavailable.relink.confirmation.connect",
            defaultValue: "Connect Anyway"
        ))
        alert.addButton(withTitle: String(localized: .actionCancel))
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[2].keyEquivalent = "\u{1b}"

        let mapResponse: (NSApplication.ModalResponse) -> RelinkConfirmationChoice = { response in
            switch response {
            case .alertFirstButtonReturn: .reselect
            case .alertSecondButtonReturn: .connect
            default: .cancel
            }
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return mapResponse(alert.runModal())
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: mapResponse(response))
            }
        }
    }

    private func relinkDifferenceLabel(_ value: String, emphasized: Bool) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = emphasized ? .systemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 11)
        label.textColor = emphasized ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 2
        return label
    }

    private func relinkDuration(_ duration: Double?) -> String {
        guard let duration else {
            return String(localized: "unavailable.relink.confirmation.unknown", defaultValue: "Unknown")
        }
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func relinkResolution(width: Int?, height: Int?) -> String {
        guard let width, let height else {
            return String(localized: "unavailable.relink.confirmation.unknown", defaultValue: "Unknown")
        }
        return "\(width) × \(height)"
    }

    private func relinkFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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

    func discardVideoRemovalUndo() {
        guard case .videoRemoval = lastUndoMutation else { return }
        invalidateUndoHistory()
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
                    onOperationError?(String(localized: .errorRestoreRefresh))
                }
                undoManager.removeAllActions()
                lastUndoMutation = nil
                onVideoRemovalRestored?(restoredVideoIDs)
            } catch {
                undoManager.removeAllActions()
                installVideoRemovalUndo(snapshot)
                AppLogger.database.error("Video removal undo failed with category: \(String(describing: type(of: error)), privacy: .public)")
                onOperationError?(String(localized: .errorRestore))
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
        undoManager.setActionName(
            snapshot.videos.count > 1
                ? String(localized: .videoUndoActionMultiple)
                : String(localized: .videoUndoActionSingle)
        )
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
        resources.removeValue(forKey: sourceID)
        sourceURLs.removeValue(forKey: sourceID)
        guard let resource = SecurityScopedResource(url: url) else {
            throw CocoaError(.fileReadNoPermission)
        }
        resources[sourceID] = resource
        sourceURLs[sourceID] = url
        knownSourceURLs[sourceID] = url
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
        knownSourceURLs.removeValue(forKey: sourceID)
        sourceBookmarks.removeValue(forKey: sourceID)
        sourceDisplayNames.removeValue(forKey: sourceID)
        guard let watchPath = sourceWatchPaths.removeValue(forKey: sourceID),
              sourceWatchPaths.values.contains(watchPath) == false else { return }
        watchersByPath.removeValue(forKey: watchPath)?.stop()
    }

    private func resetRuntimeSourceConnections() {
        resources.removeAll()
        sourceURLs.removeAll()
        for watcher in watchersByPath.values {
            watcher.stop()
        }
        watchersByPath.removeAll()
        sourceWatchPaths.removeAll()
    }

    private func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func prepareImportSource(
        for root: VideoImportRoot,
        requestIndex: Int,
        forceNewSource: Bool = false
    ) throws -> PendingImportSource {
        let url = root.url
        let existingSourceID = forceNewSource
            ? nil
            : knownSourceURLs.first {
                $0.value.standardizedFileURL == url.standardizedFileURL
            }?.key
        let sourceID = existingSourceID ?? UUID().uuidString

        let isTemporarilyAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isTemporarilyAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let bookmark: Data
        do {
            bookmark = try makeBookmark(for: url)
        } catch {
            let nsError = error as NSError
            AppLogger.library.error(
                "Import bookmark creation failed with domain: \(nsError.domain, privacy: .public), code: \(nsError.code, privacy: .public), temporary access: \(isTemporarilyAccessing, privacy: .public)"
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
            isNew: existingSourceID == nil,
            kind: root.kind,
            requestIndex: requestIndex
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
        maintenanceTask?.cancel()
        let discovery = self.discovery
        let database = self.database
        maintenanceTask = Task(priority: .utility) { [weak self] in
            do {
                guard let self else { return }
                await refreshSourceURLsFromBookmarks()
                try await refreshResolvedVideoURLs()
                let sources = sourceURLs.filter { reachableSourceIDs.contains($0.key) }
                guard sources.isEmpty == false else {
                    try await refreshTags(libraryID: LibraryRecord.primaryID)
                    try await refreshVisibleVideosNow()
                    return
                }
                var discoveredVideosBySource: [String: [DiscoveredVideo]] = [:]
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
                        if discoveryResult.failedCount == 0 {
                            discoveredVideosBySource[sourceID] = discoveryResult.videos
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        AppLogger.library.error(
                            "Source maintenance discovery failed with category: \(String(describing: type(of: error)), privacy: .public)"
                        )
                    }
                }
                try Task.checkCancellation()
                let result = try await database.reconcileSources(
                    discoveredVideosBySource: discoveredVideosBySource
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
                    options: [.withSecurityScope, .withoutUI, .withoutMounting],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                let locationChanged = knownSourceURLs[sourceID]?.standardizedFileURL != resolvedURL.standardizedFileURL
                let needsConnection = resources[sourceID] == nil
                guard locationChanged || isStale || needsConnection else { continue }
                knownSourceURLs[sourceID] = resolvedURL
                try connect(sourceID: sourceID, url: resolvedURL)
                let refreshedBookmark = isStale ? try makeBookmark(for: resolvedURL) : bookmark
                sourceBookmarks[sourceID] = refreshedBookmark
                sourceDisplayNames[sourceID] = resolvedURL.lastPathComponent
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
        let allLocations = try await database.fetchVideoLocations(includeUnavailable: true)
        let knownURLs = knownSourceURLs
        let activeSourceIDs = Set(resources.keys)
        let authorizedSourceIDs = Set(sourceBookmarks.keys)
        let displayNames = sourceDisplayNames
        let resolution = await Task.detached(priority: .utility) {
            Self.resolveVideoAccess(
                locations: locations,
                sourceURLs: knownURLs,
                activeSourceIDs: activeSourceIDs,
                authorizedSourceIDs: authorizedSourceIDs,
                sourceDisplayNames: displayNames
            )
        }.value
        try Task.checkCancellation()
        try await database.backfillVideoLocationFallbackKeys(resolution.fallbackUpdates)
        try await database.confirmMissingLocations(resolution.confirmedMissingLocations)
        try Task.checkCancellation()
        resolvedVideoURLs = resolution.resolvedURLs
        let lastKnownResolution = Self.resolveLastKnownVideoPaths(
            locations: allLocations,
            sourceURLs: knownURLs
        )
        try await database.updateVideoLocationLastKnownPaths(lastKnownResolution.updates)
        lastKnownVideoPaths = lastKnownResolution.paths
        offlineSourceNameByVideoID = resolution.offlineSourceNames
        accessLostSourceNameByVideoID = resolution.accessLostSourceNames
        reachableSourceIDs = resolution.reachableSourceIDs
    }

    nonisolated private static func resolveLastKnownVideoPaths(
        locations: [VideoLocationRecord],
        sourceURLs: [String: URL]
    ) -> (paths: [String: String], updates: [VideoLocationLastKnownPathUpdate]) {
        var paths: [String: String] = [:]
        var updates: [VideoLocationLastKnownPathUpdate] = []
        for location in locations {
            let components = location.relativePath.split(separator: "/")
            guard components.contains("..") == false else { continue }
            let sourceURL = sourceURLs[location.sourceID]?.standardizedFileURL
            if let sourceURL, isURLInTrash(sourceURL) == false {
                let fileURL = components.reduce(sourceURL) { partialURL, component in
                    partialURL.appendingPathComponent(String(component))
                }
                let path = fileURL.standardizedFileURL.path
                if paths[location.videoID] == nil { paths[location.videoID] = path }
                if location.lastKnownPath != path {
                    updates.append(VideoLocationLastKnownPathUpdate(
                        videoID: location.videoID,
                        sourceID: location.sourceID,
                        relativePath: location.relativePath,
                        lastKnownPath: path
                    ))
                }
            } else if paths[location.videoID] == nil,
                      let lastKnownPath = location.lastKnownPath,
                      lastKnownPath.isEmpty == false,
                      isURLInTrash(URL(fileURLWithPath: lastKnownPath)) == false {
                paths[location.videoID] = lastKnownPath
            }
        }
        return (paths, updates)
    }

    nonisolated private static func resolveVideoAccess(
        locations: [VideoLocationRecord],
        sourceURLs: [String: URL],
        activeSourceIDs: Set<String>,
        authorizedSourceIDs: Set<String>,
        sourceDisplayNames: [String: String]
    ) -> VideoAccessResolution {
        let mountedVolumeIdentifiers = mountedVolumeIdentifiers()
        var resolvedURLs: [String: URL] = [:]
        var offlineCandidates: [String: String] = [:]
        var accessLostCandidates: [String: String] = [:]
        var fallbackUpdates: [VideoLocationFallbackUpdate] = []
        var missingCandidates: [VideoLocationRecord] = []
        var reachableSourceIDs = Set<String>()
        for (sourceID, sourceURL) in sourceURLs
            where activeSourceIDs.contains(sourceID)
                && FileManager.default.fileExists(atPath: sourceURL.path)
                && isURLInTrash(sourceURL) == false {
            reachableSourceIDs.insert(sourceID)
        }

        for location in locations {
            let rootURL = sourceURLs[location.sourceID]
            let components = location.relativePath.split(separator: "/")
            guard components.contains("..") == false else { continue }
            let fileURL = rootURL.map { root in
                components.reduce(root) { partialURL, component in
                    partialURL.appendingPathComponent(String(component))
                }
            }

            if let fileURL, location.fallbackPathKey == nil {
                fallbackUpdates.append(VideoLocationFallbackUpdate(
                    videoID: location.videoID,
                    sourceID: location.sourceID,
                    relativePath: location.relativePath,
                    fallbackPathKey: fallbackPathKey(for: fileURL)
                ))
            }

            let sourceIsInTrash = rootURL.map(isURLInTrash) ?? false
            let volumeIsOffline: Bool
            if let volumeIdentifier = location.volumeIdentifier {
                volumeIsOffline = mountedVolumeIdentifiers.contains(volumeIdentifier) == false
            } else {
                volumeIsOffline = rootURL.map(isOnUnmountedExternalVolume) ?? false
            }
            if let fileURL,
               activeSourceIDs.contains(location.sourceID),
               sourceIsInTrash == false,
               FileManager.default.fileExists(atPath: fileURL.path),
               isURLInTrash(fileURL) == false {
                if resolvedURLs[location.videoID] == nil {
                    resolvedURLs[location.videoID] = fileURL
                }
                continue
            }

            if volumeIsOffline == false,
               (sourceIsInTrash && authorizedSourceIDs.contains(location.sourceID))
                || (activeSourceIDs.contains(location.sourceID)
                    && fileURL.map(isURLInTrash) == true) {
                missingCandidates.append(location)
                continue
            }

            if volumeIsOffline == false,
               location.relativePath.isEmpty,
               activeSourceIDs.contains(location.sourceID),
               rootURL != nil {
                missingCandidates.append(location)
                continue
            }
            if volumeIsOffline == false,
               authorizedSourceIDs.contains(location.sourceID),
               activeSourceIDs.contains(location.sourceID) == false {
                accessLostCandidates[location.videoID] =
                    accessLostCandidates[location.videoID]
                    ?? sourceDisplayNames[location.sourceID]
                    ?? rootURL?.lastPathComponent
                    ?? ""
                continue
            }
            guard volumeIsOffline else { continue }
            offlineCandidates[location.videoID] = offlineCandidates[location.videoID]
                ?? sourceDisplayNames[location.sourceID]
                ?? rootURL?.lastPathComponent
                ?? ""
        }

        let offlineSourceNames = offlineCandidates.filter { resolvedURLs[$0.key] == nil }
        let accessLostSourceNames = accessLostCandidates.filter {
            resolvedURLs[$0.key] == nil
        }
        let confirmedMissingLocations = missingCandidates.filter {
            resolvedURLs[$0.videoID] == nil
        }
        return VideoAccessResolution(
            resolvedURLs: resolvedURLs,
            offlineSourceNames: offlineSourceNames,
            accessLostSourceNames: accessLostSourceNames,
            reachableSourceIDs: reachableSourceIDs,
            fallbackUpdates: fallbackUpdates,
            confirmedMissingLocations: confirmedMissingLocations
        )
    }

    nonisolated private static func mountedVolumeIdentifiers() -> Set<Data> {
        let keys: [URLResourceKey] = [.volumeIdentifierKey]
        let volumeURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: []
        ) ?? []
        return Set(volumeURLs.compactMap { url in
            guard let value = try? url.resourceValues(forKeys: Set(keys)).volumeIdentifier else {
                return nil
            }
            return encodedIdentifier(value)
        })
    }

    nonisolated private static func encodedIdentifier(_ value: Any?) -> Data? {
        if let data = value as? Data { return data }
        if let data = value as? NSData { return data as Data }
        if let string = value as? String { return Data(string.utf8) }
        if let number = value as? NSNumber { return Data(number.stringValue.utf8) }
        return nil
    }

    nonisolated private static func isOnUnmountedExternalVolume(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3,
              components[0] == "/",
              components[1] == "Volumes" else { return false }
        let volumeURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
            .appendingPathComponent(components[2], isDirectory: true)
        return FileManager.default.fileExists(atPath: volumeURL.path) == false
    }

    nonisolated private static func isURLInTrash(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL
        if let trashURL = try? FileManager.default.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: candidate,
            create: false
        ), isURL(candidate, inside: trashURL.standardizedFileURL) {
            return true
        }

        let homeTrashURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL
        if isURL(candidate, inside: homeTrashURL) {
            return true
        }

        let components = candidate.pathComponents
        if components.count >= 2, components[0] == "/", components[1] == ".Trashes" {
            return true
        }
        return components.count >= 4
            && components[0] == "/"
            && components[1] == "Volumes"
            && components[3] == ".Trashes"
    }

    nonisolated private static func isURL(_ candidate: URL, inside directory: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let directoryComponents = directory.pathComponents
        guard candidateComponents.count >= directoryComponents.count else { return false }
        return Array(candidateComponents.prefix(directoryComponents.count)) == directoryComponents
    }

    private func startMediaProcessing(videos: [VideoRecord]) {
        guard let mediaService else { return }
        let pendingVideos = videos.filter { video in
            if video.contentFingerprint == nil { return true }
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
                        onVideoChanged?(presentedVideo(updated))
                        scheduleMediaFactsRefresh()
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

    private func scheduleMediaFactsRefresh() {
        mediaFactsRefreshTask?.cancel()
        mediaFactsRefreshRevision += 1
        let revision = mediaFactsRefreshRevision
        mediaFactsRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                guard let self, mediaFactsRefreshRevision == revision else { return }
                try await refreshVisibleVideosNow()
            } catch is CancellationError {
                return
            } catch {
                AppLogger.database.error(
                    "Media fact refresh failed with category: \(String(describing: type(of: error)), privacy: .public)"
                )
            }
            guard let self, mediaFactsRefreshRevision == revision else { return }
            mediaFactsRefreshTask = nil
        }
    }

    private func refreshTags(libraryID: String) async throws {
        tags = try await database.fetchTags(libraryID: libraryID)
        onTagsChanged?(tags)
    }

    private func refreshSmartCollections(libraryID: String) async throws {
        smartCollections = try await database.fetchSmartCollections(libraryID: libraryID)
        for index in smartCollections.indices {
            let videos = try await database.fetchVideos(
                libraryID: libraryID,
                query: LibraryQueryRequest(
                    baseFilter: .all,
                    temporaryFilenameSearch: "",
                    rule: smartCollections[index].rule
                )
            )
            smartCollections[index].videoCount = videos.count
        }
        onSmartCollectionsChanged?(smartCollections)
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
                onOperationError?(String(localized: .errorTagOperation))
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
                onOperationError?(String(localized: .errorUndo))
            }
        }
    }

    private func refreshVisibleVideos(debounceNanoseconds: UInt64 = 0) {
        queryTask?.cancel()
        let database = self.database
        let filter = currentFilter
        let search = currentSearch
        let rule = currentRule
        queryTask = Task {
            do {
                if debounceNanoseconds > 0 { try await Task.sleep(nanoseconds: debounceNanoseconds) }
                let records = try await database.fetchVideos(
                    libraryID: LibraryRecord.primaryID,
                    query: LibraryQueryRequest(
                        baseFilter: filter,
                        temporaryFilenameSearch: search,
                        rule: rule
                    )
                )
                try Task.checkCancellation()
                let videos = presentedVideos(records)
                onVideosChanged?(
                    filter == .unavailable
                        ? orderedUnavailableVideos(videos)
                        : videos
                )
            } catch is CancellationError {
                return
            } catch {
                AppLogger.database.error("Video query failed with category: \(String(describing: type(of: error)), privacy: .public)")
                onOperationError?(String(localized: .errorFilter))
            }
        }
    }

    private func refreshVisibleVideosNow() async throws {
        queryTask?.cancel()
        let filter = currentFilter
        let records = try await database.fetchVideos(
            libraryID: LibraryRecord.primaryID,
            query: LibraryQueryRequest(
                baseFilter: filter,
                temporaryFilenameSearch: currentSearch,
                rule: currentRule
            )
        )
        let videos = presentedVideos(records)
        onVideosChanged?(
            filter == .unavailable
                ? orderedUnavailableVideos(videos)
                : videos
        )
        try await refreshSidebarFilterCounts()
        try await refreshSmartCollections(libraryID: LibraryRecord.primaryID)
    }

    private func refreshSidebarFilterCounts() async throws {
        let databaseCounts = try await database.fetchSidebarFilterCounts(libraryID: LibraryRecord.primaryID)
        let missingVideoIDs = try await database.fetchMissingVideoIDs(
            libraryID: LibraryRecord.primaryID
        )
        let unavailableVideoIDs = missingVideoIDs
            .union(accessLostSourceNameByVideoID.keys)
            .union(offlineSourceNameByVideoID.keys)
        onSidebarFilterCountsChanged?(SidebarFilterCounts(
            all: databaseCounts.all,
            untagged: databaseCounts.untagged,
            recent: databaseCounts.recent,
            unavailable: unavailableVideoIDs.count
        ))
    }

    private func presentedVideos(_ videos: [VideoRecord]) -> [VideoRecord] {
        videos.map(presentedVideo)
    }

    private func orderedUnavailableVideos(_ videos: [VideoRecord]) -> [VideoRecord] {
        videos.enumerated()
            .filter { $0.element.availability != .available }
            .sorted { left, right in
                let leftPriority = left.element.availability == .unavailable ? 0 : 1
                let rightPriority = right.element.availability == .unavailable ? 0 : 1
                return leftPriority == rightPriority
                    ? left.offset < right.offset
                    : leftPriority < rightPriority
            }
            .map(\.element)
    }

    private func presentedVideo(_ video: VideoRecord) -> VideoRecord {
        if video.availability == .unavailable { return video }
        if accessLostSourceNameByVideoID[video.id] != nil {
            return video.withAvailability(.unavailable, unavailableReason: .accessLost)
        }
        if offlineSourceNameByVideoID[video.id] != nil {
            return video.withAvailability(.offline)
        }
        return video
    }
}
