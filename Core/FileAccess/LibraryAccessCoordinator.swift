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

struct LibraryScanNotice: Equatable, Sendable {
    let title: String
    let detail: String
}

struct LibraryScanResults: Equatable, Sendable {
    let candidates: [ScannedVideoCandidate]
    let checkedFolderCount: Int
    let uncheckedFolderCount: Int
    let failedFolderCount: Int
    let notice: LibraryScanNotice?
}

struct LibraryScanCompletion: Equatable, Sendable {
    let addedVideoIDs: [String]
    let existingVideoIDs: [String]
}

enum LibraryScanState: Equatable, Sendable {
    case idle
    case scanning(title: String, detail: String)
    case results(LibraryScanResults)
    case importing(title: String, detail: String, results: LibraryScanResults)
    case completed(LibraryScanCompletion)
    case failed(message: String)
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

private struct RecoveryFileObservation: Equatable, Sendable {
    let sourceID: String
    let path: String
    let size: Int?
    let modified: Date?
    let originalFingerprint: Data
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
    private var sourceScansDescendants: [String: Bool] = [:]
    private var sourceScanPolicyExplicit: [String: Bool] = [:]
    private var watchersByPath: [String: FSEventsWatcher] = [:]
    private var sourceWatchPaths: [String: String] = [:]
    private var resolvedVideoURLs: [String: URL] = [:]
    private var lastKnownVideoPaths: [String: String] = [:]
    private var offlineSourceNameByVideoID: [String: String] = [:]
    private var accessLostSourceNameByVideoID: [String: String] = [:]
    private var reachableSourceIDs = Set<String>()
    private var recoveryTask: Task<Void, Never>?
    private var recoveryCandidates: [VideoRecord] = []
    private var recoveryStatus = RecoveryStatus()
    var onRecoveryChanged: ((RecoveryStatus) -> Void)?
    private var importTask: Task<Void, Never>? { didSet { publishRecoveryStatus() } }
    private var scanTask: Task<Void, Never>? { didSet { publishRecoveryStatus() } }
    private var scanRevision = 0
    private var scanResults: LibraryScanResults?
    private var scanSessionAddedVideoIDs: [String] = []
    private var scanSessionExistingVideoIDs: [String] = []
    private var relinkTask: Task<Void, Never>? { didSet { publishRecoveryStatus() } }
    private var relinkingVideoID: String?
    private var importRevision = 0
    private var isRestoringLibrary = false
    private var automaticRecoveryObservations: [String: RecoveryFileObservation] = [:]
    private var maintenanceTask: Task<Void, Never>?
    private var maintenanceDebounceTask: Task<Void, Never>?
    private var volumeAvailabilityTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    private var mediaFactsRefreshTask: Task<Void, Never>?
    private var mediaFactsRefreshRevision = 0
    private var artifactCleanupTask: Task<Void, Never>?
    var mediaPriorityVideoIDs: (() -> [String])?
    private var pendingMediaVideos: [String: VideoRecord] = [:]
    private var deferredMediaVideos = DeferredMediaVideos()
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
    var onScanStateChanged: ((LibraryScanState) -> Void)?
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

    private func publishRecoveryStatus() {
        recoveryStatus.showEntry = currentFilter == .unavailable
        recoveryStatus.canStart = recoveryTask == nil && importTask == nil && scanTask == nil && relinkTask == nil
        onRecoveryChanged?(recoveryStatus)
    }

    func dismissRecoveryResult() {
        guard recoveryTask == nil else { return }
        recoveryStatus.message = nil
        publishRecoveryStatus()
    }

    func stopAccessRecovery() { recoveryTask?.cancel() }

    func recoverVideoAccess() {
        guard !isRestoringLibrary, recoveryTask == nil, importTask == nil, relinkTask == nil, scanTask == nil,
              pendingTagMutationCount == 0, !recoveryCandidates.isEmpty else { return }
        let candidates = recoveryCandidates
        discardVideoRemovalUndo()
        recoveryStatus = RecoveryStatus(candidateCount: candidates.count, running: true, total: candidates.count)
        publishRecoveryStatus()
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            let maintenance = maintenanceTask
            maintenanceDebounceTask?.cancel()
            maintenance?.cancel()
            let media = mediaTask
            media?.cancel()
            await maintenance?.value
            await media?.value
            mediaTask = nil
            pendingMediaVideos.removeAll()
            deferredMediaVideos.removeAll()
            var succeeded = 0
            var checked = 0
            var failures = 0
            var needsReview = 0
            var stopped = false
            var localSources: [URL: SourceAuthorizationRecord] = [:]
            var localResources: [URL: SecurityScopedResource] = [:]
            do {
                try Task.checkCancellation()
                try await database.protectRecoveryLocations(videoIDs: candidates.map(\.id))
                try await refreshResolvedVideoURLs()
                let locations = try await database.fetchVideoLocations(includeUnavailable: true)
                for video in candidates {
                    try Task.checkCancellation()
                    var restored = false
                    var requiresReview = false
                    let paths = Set(locations.filter { $0.videoID == video.id }.compactMap { location -> String? in
                        location.lastKnownPath ?? knownSourceURLs[location.sourceID].flatMap { Self.fileURL(sourceURL: $0, relativePath: location.relativePath)?.path }
                    }).filter { $0.hasPrefix("/") }
                    for path in paths.sorted() {
                        try Task.checkCancellation()
                        let file = URL(fileURLWithPath: path).standardizedFileURL
                        guard !Self.isURLInTrash(file), !Self.isOnUnmountedExternalVolume(file) else { continue }
                        let directory = file.deletingLastPathComponent()
                        do {
                            let source: SourceAuthorizationRecord
                            if let cached = localSources[directory] { source = cached }
                            else {
                                // Existing scopes may already cover the exact original parent.
                                let canAccess = sourceURLs.values.contains { root in
                                    directory == root.standardizedFileURL || Self.isURL(file, inside: root.standardizedFileURL)
                                }
                                let authorizedURL: URL
                                if canAccess { authorizedURL = directory }
                                else {
                                    guard let selected = picker.authorizeRecoveryDirectory(directory) else {
                                        throw CancellationError()
                                    }
                                    authorizedURL = selected
                                }
                                if let resource = SecurityScopedResource(url: authorizedURL) {
                                    localResources[directory] = resource
                                } else if !canAccess { throw CocoaError(.fileReadNoPermission) }
                                let bookmark = try makeBookmark(for: authorizedURL)
                                let priorDirectoryID = locations.first { location in
                                    guard !location.relativePath.isEmpty, let previousPath = location.lastKnownPath else { return false }
                                    let components = location.relativePath.split(separator: "/")
                                    guard !components.contains("..") else { return false }
                                    let previousRoot = components.reduce(URL(fileURLWithPath: previousPath)) { root, _ in root.deletingLastPathComponent() }
                                    return previousRoot.standardizedFileURL == directory
                                }?.sourceID
                                let id = knownSourceURLs.first { $0.value.standardizedFileURL == directory }?.key
                                    ?? priorDirectoryID ?? UUID().uuidString
                                source = SourceAuthorizationRecord(id: id, libraryID: LibraryRecord.primaryID,
                                    displayName: directory.lastPathComponent, rootBookmarkData: bookmark,
                                    createdAt: Date(), scansDescendants: sourceScansDescendants[id] ?? false)
                                localSources[directory] = source
                            }
                            guard let positioned = try await verifiedRecoveryCandidate(
                                videoID: video.id, file: file, sourceID: source.id, relativePath: file.lastPathComponent
                            ) else { requiresReview = true; continue }
                            try Task.checkCancellation()
                            _ = try await database.relinkVideo(id: video.id, sourceID: source.id, discoveredVideo: positioned,
                                allowAvailableRecord: true, sourceAuthorization: source)
                            // Count the committed result before any cancellable refresh.
                            succeeded += 1
                            restored = true
                            sourceBookmarks[source.id] = source.rootBookmarkData
                            sourceDisplayNames[source.id] = source.displayName
                            sourceScansDescendants[source.id] = source.scansDescendants
                            sourceScanPolicyExplicit[source.id] = true
                            try connect(sourceID: source.id, url: directory)
                            break
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            if restored { break }
                            // A readable parent listing provides positive absence evidence.
                            let absence = Task.detached(priority: .utility) {
                                guard let entries = try? FileManager.default.contentsOfDirectory(at: directory,
                                    includingPropertiesForKeys: nil) else { return false }
                                return !entries.contains { $0.lastPathComponent == file.lastPathComponent }
                            }
                            if await absence.value {
                                try? await database.confirmRecoveryPathMissing(videoID: video.id, path: file.path)
                            }
                        }
                    }
                    checked += 1
                    if !restored {
                        failures += 1
                        if requiresReview { needsReview += 1 }
                    }
                    recoveryStatus.completed = checked
                    publishRecoveryStatus()
                    try await refreshResolvedVideoURLs()
                    try await refreshVisibleVideosNow()
                }
            } catch is CancellationError { stopped = true }
            catch { failures += 1 }
            // Task cancellation must not suppress the final state refresh.
            let finalSucceeded = succeeded
            let finalChecked = checked
            let finalStopped = stopped
            let finalFailures = failures
            recoveryStatus.running = false
            recoveryStatus.message = String(localized: "recovery.result", defaultValue: "Restored \(finalSucceeded); not restored \(max(0, finalChecked - finalSucceeded)); unchecked \(max(0, candidates.count - finalChecked)).")
            if finalStopped {
                recoveryStatus.message = String(localized: "recovery.stopped", defaultValue: "Recovery stopped.") + " " + (recoveryStatus.message ?? "")
            }
            if needsReview > 0 {
                recoveryStatus.message = (recoveryStatus.message ?? "") + " " + String(localized: "recovery.reviewCount", defaultValue: "\(needsReview) videos require individual relinking to confirm their original files.")
            } else if finalFailures > 0 {
                recoveryStatus.message = (recoveryStatus.message ?? "") + " " + String(localized: "recovery.remaining", defaultValue: "Remaining videos can be relinked individually or retried.")
            }
            publishRecoveryStatus()
            _ = localResources
            Task { [weak self] in
                guard let self else { return }
                try? await refreshResolvedVideoURLs()
                recoveryTask = nil
                try? await refreshVisibleVideosNow()
                if let videos = try? await database.fetchVideos(libraryID: LibraryRecord.primaryID) {
                    startMediaProcessing(videos: videos)
                }
                scheduleMaintenance()
            }
        }
    }

    func restoreLibrary() {
        isRestoringLibrary = true
        Task { [self] in
            defer {
                isRestoringLibrary = false
                scheduleMaintenance()
            }
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
                    sourceScansDescendants[source.id] = source.scansDescendants
                    sourceScanPolicyExplicit[source.id] = source.scanPolicyExplicit
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
                        let isDirectory = Self.isDirectoryURL(url)
                        let scansDescendants = source.scansDescendants || (!source.scanPolicyExplicit && isDirectory)
                        sourceScansDescendants[source.id] = scansDescendants
                        if isStale || scansDescendants != source.scansDescendants {
                            let refreshedBookmark = isStale
                                ? try makeBookmark(for: url)
                                : source.rootBookmarkData
                            sourceBookmarks[source.id] = refreshedBookmark
                            sourceDisplayNames[source.id] = url.lastPathComponent
                            try await database.saveSourceAuthorization(SourceAuthorizationRecord(
                                id: source.id,
                                libraryID: source.libraryID,
                                displayName: url.lastPathComponent,
                                rootBookmarkData: refreshedBookmark,
                                createdAt: source.createdAt,
                                scansDescendants: scansDescendants
                            ))
                            sourceScanPolicyExplicit[source.id] = true
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
        guard recoveryTask == nil else { return }
        guard let urls = picker.chooseImportItems() else { return }
        Task { [weak self] in
            await self?.importItems(urls, entryPoint: .picker)
        }
    }

    func importDroppedItems(_ urls: [URL]) {
        guard recoveryTask == nil else { return }
        Task { [weak self] in
            await self?.importItems(urls, entryPoint: .drop)
        }
    }

    func scanForNewVideos() {
        guard recoveryTask == nil, importTask == nil else { return }
        beginScanForNewVideos(resetImportedHistory: true)
    }

    func clearScanResults() {
        guard recoveryTask == nil, importTask == nil else { return }
        scanTask?.cancel()
        scanTask = nil
        scanRevision += 1
        scanResults = nil
        scanSessionAddedVideoIDs = []
        scanSessionExistingVideoIDs = []
        onScanStateChanged?(.idle)
    }

    func chooseAdditionalScanFolders() {
        guard recoveryTask == nil, importTask == nil,
              let urls = picker.chooseScanFolders() else { return }
        let roots = VideoFileDiscovery.importPlan(for: urls).roots.filter {
            $0.kind == .directory
        }
        guard roots.isEmpty == false else { return }
        scanTask?.cancel()
        scanRevision += 1
        let revision = scanRevision
        onScanStateChanged?(.scanning(
            title: String(
                localized: "scan.progress.addingFolders",
                defaultValue: "Adding folders to scan"
            ),
            detail: String(
                localized: "scan.progress.preparingFolders",
                defaultValue: "Preparing the selected folders…"
            )
        ))
        scanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if scanRevision == revision { scanTask = nil }
            }
            var addedFolderCount = 0
            for (index, root) in roots.enumerated() {
                var preparedSource: PendingImportSource?
                do {
                    try Task.checkCancellation()
                    let source = try prepareImportSource(for: root, requestIndex: index)
                    preparedSource = source
                    try await database.saveSourceAuthorization(SourceAuthorizationRecord(
                        id: source.id,
                        libraryID: LibraryRecord.primaryID,
                        displayName: source.url.lastPathComponent,
                        rootBookmarkData: source.bookmark,
                        createdAt: Date(),
                        scansDescendants: true
                    ))
                    sourceDisplayNames[source.id] = source.url.lastPathComponent
                    sourceScansDescendants[source.id] = true
                    sourceScanPolicyExplicit[source.id] = true
                    addedFolderCount += 1
                } catch is CancellationError {
                    if let preparedSource, preparedSource.isNew {
                        disconnectSource(preparedSource.id)
                    }
                    return
                } catch {
                    if let preparedSource, preparedSource.isNew {
                        disconnectSource(preparedSource.id)
                    }
                    AppLogger.library.error(
                        "Scan folder setup failed with category: \(String(describing: type(of: error)), privacy: .public)"
                    )
                }
            }
            guard scanRevision == revision, importTask == nil else { return }
            guard addedFolderCount > 0 else {
                if let scanResults {
                    let restoredResults = LibraryScanResults(
                        candidates: scanResults.candidates,
                        checkedFolderCount: scanResults.checkedFolderCount,
                        uncheckedFolderCount: scanResults.uncheckedFolderCount,
                        failedFolderCount: scanResults.failedFolderCount,
                        notice: LibraryScanNotice(
                            title: String(
                                localized: "scan.folderSetup.failed.title",
                                defaultValue: "Could Not Add Selected Folders"
                            ),
                            detail: String(
                                localized: "scan.folderSetup.failed.detail",
                                defaultValue: "The previous scan results are unchanged."
                            )
                        )
                    )
                    self.scanResults = restoredResults
                    onScanStateChanged?(.results(restoredResults))
                } else {
                    onScanStateChanged?(.failed(message: String(
                        localized: "scan.error.noFolderAccess",
                        defaultValue: "The selected folders could not be checked."
                    )))
                }
                return
            }
            scanTask = nil
            beginScanForNewVideos(resetImportedHistory: false)
        }
    }

    func importScannedVideos(ids: [String]) {
        guard recoveryTask == nil, importTask == nil,
              let scanResults else { return }
        let requestedIDs = Set(ids)
        let candidates = scanResults.candidates.filter { requestedIDs.contains($0.id) }
        guard candidates.isEmpty == false else { return }
        let expectedRevision = scanRevision
        Task { [weak self] in
            guard let self,
                  let method = await resolveFolderImportMethod(),
                  scanRevision == expectedRevision else { return }
            runScannedVideoImport(candidates: candidates, method: method)
        }
    }

    private func beginScanForNewVideos(resetImportedHistory: Bool) {
        scanTask?.cancel()
        scanRevision += 1
        let revision = scanRevision
        scanResults = nil
        if resetImportedHistory {
            scanSessionAddedVideoIDs = []
            scanSessionExistingVideoIDs = []
        }
        discardVideoRemovalUndo()
        onScanStateChanged?(.scanning(
            title: String(localized: "scan.progress.title", defaultValue: "Scanning for New Videos"),
            detail: String(
                localized: "scan.progress.detail",
                defaultValue: "Checking folders that contain imported videos…"
            )
        ))
        let discovery = self.discovery
        let database = self.database
        scanTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                if scanRevision == revision { scanTask = nil }
            }
            do {
                await refreshSourceURLsFromBookmarks()
                try await refreshResolvedVideoURLs()
                try Task.checkCancellation()
                let accessibleDirectorySources = sourceURLs.filter {
                    sourceScansDescendants[$0.key] == true
                        && Self.isDirectoryURL($0.value)
                        && FileManager.default.fileExists(atPath: $0.value.path)
                }
                let directorySources = Self.collapsedDirectorySources(
                    accessibleDirectorySources
                )
                let configuredDirectoryCount = sourceScansDescendants.values.filter { $0 }.count
                let uncheckedFolderCount = Self.uncoveredFileParentCount(
                    sourceURLs: knownSourceURLs,
                    scansDescendants: sourceScansDescendants
                )
                var failedFolderCount = max(
                    0,
                    configuredDirectoryCount - accessibleDirectorySources.count
                )
                var checkedFolderCount = 0
                var candidatesByID: [String: ScannedVideoCandidate] = [:]

                for (sourceID, sourceURL) in directorySources {
                    try Task.checkCancellation()
                    do {
                        let discoveryTask = Task.detached(priority: .utility) {
                            try discovery.discoverVideoResult(at: sourceURL)
                        }
                        let result = try await withTaskCancellationHandler {
                            try await discoveryTask.value
                        } onCancel: {
                            discoveryTask.cancel()
                        }
                        let unimported = try await database.unimportedVideos(
                            sourceID: sourceID,
                            discoveredVideos: result.videos
                        )
                        checkedFolderCount += 1
                        if result.failedCount > 0 { failedFolderCount += 1 }
                        for video in unimported {
                            guard let fileURL = Self.fileURL(
                                sourceURL: sourceURL,
                                relativePath: video.relativePath
                            ) else { continue }
                            let candidate = ScannedVideoCandidate(
                                sourceID: sourceID,
                                sourceName: sourceDisplayNames[sourceID]
                                    ?? sourceURL.lastPathComponent,
                                video: video,
                                fileURL: fileURL
                            )
                            if candidatesByID[candidate.id] == nil {
                                candidatesByID[candidate.id] = candidate
                            }
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failedFolderCount += 1
                        AppLogger.library.error(
                            "Scan folder discovery failed with category: \(String(describing: type(of: error)), privacy: .public)"
                        )
                    }
                }

                try Task.checkCancellation()
                guard scanRevision == revision else { return }
                if configuredDirectoryCount > 0,
                   checkedFolderCount == 0,
                   uncheckedFolderCount == 0 {
                    onScanStateChanged?(.failed(message: String(
                        localized: "scan.error.failed",
                        defaultValue: "The folders could not be scanned."
                    )))
                    return
                }
                let candidates = candidatesByID.values.sorted {
                    let filenameOrder = $0.video.filename.localizedStandardCompare($1.video.filename)
                    if filenameOrder != .orderedSame { return filenameOrder == .orderedAscending }
                    return $0.fileURL.path.localizedStandardCompare($1.fileURL.path) == .orderedAscending
                }
                let results = LibraryScanResults(
                    candidates: candidates,
                    checkedFolderCount: checkedFolderCount,
                    uncheckedFolderCount: uncheckedFolderCount,
                    failedFolderCount: failedFolderCount,
                    notice: nil
                )
                scanResults = results
                onScanStateChanged?(.results(results))
                AppLogger.library.notice(
                    "New video scan completed with \(candidates.count, privacy: .public) candidates"
                )
            } catch is CancellationError {
                return
            } catch {
                guard scanRevision == revision else { return }
                AppLogger.library.error(
                    "New video scan failed with category: \(String(describing: type(of: error)), privacy: .public)"
                )
                onScanStateChanged?(.failed(message: String(
                    localized: "scan.error.failed",
                    defaultValue: "The folders could not be scanned."
                )))
            }
        }
    }

    private func importItems(_ urls: [URL], entryPoint: LibraryImportEntryPoint) async {
        guard recoveryTask == nil else { return }
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
        endScanSessionForManualImport()
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

    private func endScanSessionForManualImport() {
        scanTask?.cancel()
        scanTask = nil
        scanRevision += 1
        scanResults = nil
        scanSessionAddedVideoIDs = []
        scanSessionExistingVideoIDs = []
        onScanStateChanged?(.idle)
    }

    private func runScannedVideoImport(
        candidates: [ScannedVideoCandidate],
        method: FolderImportMethod
    ) {
        guard let currentResults = scanResults else { return }
        scanTask?.cancel()
        scanRevision += 1
        let revision = scanRevision
        let previousMutationTask = tagMutationTask
        let previousCleanupTask = artifactCleanupTask
        discardVideoRemovalUndo()
        let title = String(
            localized: "scan.import.progress.title",
            defaultValue: "Importing Selected Videos"
        )
        let detail = String(
            localized: "scan.import.progress.detail",
            defaultValue: "Saving the selected videos to FileFacet…"
        )
        onScanStateChanged?(.importing(title: title, detail: detail, results: currentResults))
        onImportStateChanged?(.importing(title: title, detail: detail, progress: nil))
        let database = self.database
        let grouped = Dictionary(grouping: candidates, by: \.sourceID)
        importTask = Task { [weak self] in
            _ = await previousMutationTask?.value
            _ = await previousCleanupTask?.value
            guard let self else { return }
            discardVideoRemovalUndo()
            defer {
                if scanRevision == revision { importTask = nil }
            }
            var addedCount = 0
            var existingCount = 0
            var failedInputCount = 0
            var importedVideos: [VideoRecord] = []
            var addedVideoIDs: [String] = []
            var existingVideoIDs: [String] = []
            var completedCandidateIDs = Set<String>()
            var createdFolderTagIDs = Set<String>()

            for sourceID in grouped.keys.sorted() {
                guard let sourceCandidates = grouped[sourceID] else { continue }
                do {
                    try Task.checkCancellation()
                    let folderTagOptions: FolderTagImportOptions?
                    if case let .folderTags(includeSelectedRoot) = method {
                        folderTagOptions = FolderTagImportOptions(
                            selectedRootName: includeSelectedRoot
                                ? sourceDisplayNames[sourceID]
                                : nil
                        )
                    } else {
                        folderTagOptions = nil
                    }
                    let result = try await database.importVideos(
                        sourceID: sourceID,
                        discoveredVideos: sourceCandidates.map(\.video),
                        folderTagOptions: folderTagOptions
                    )
                    addedCount += result.addedCount
                    existingCount += result.existingCount
                    addedVideoIDs.append(contentsOf: result.addedVideoIDs)
                    existingVideoIDs.append(contentsOf: result.existingVideoIDs)
                    importedVideos.append(contentsOf: result.importedVideos)
                    createdFolderTagIDs.formUnion(result.createdFolderTagIDs)
                    completedCandidateIDs.formUnion(sourceCandidates.map(\.id))
                } catch is CancellationError {
                    await refreshAfterInterruptedImportInFreshTask()
                    guard scanRevision == revision else { return }
                    onImportStateChanged?(.cancelled)
                    return
                } catch {
                    failedInputCount += 1
                    AppLogger.library.error(
                        "Scanned video import failed with category: \(String(describing: type(of: error)), privacy: .public)"
                    )
                }
            }

            do {
                try await refreshTags(libraryID: LibraryRecord.primaryID)
                try await refreshResolvedVideoURLs()
                try await refreshVisibleVideosNow()
                onTagAssignmentsChanged?()
                tagStateRevision += 1
                invalidateUndoHistoryUnlessVideoRemoval()
                startMediaProcessing(videos: importedVideos)
            } catch {
                AppLogger.database.error(
                    "Scanned video import refresh failed with category: \(String(describing: type(of: error)), privacy: .public)"
                )
            }
            guard scanRevision == revision else { return }
            let remaining = currentResults.candidates.filter {
                completedCandidateIDs.contains($0.id) == false
            }
            if completedCandidateIDs.isEmpty, failedInputCount > 0 {
                let failedNotice = LibraryScanNotice(
                    title: String(
                        localized: "scan.import.failed.title",
                        defaultValue: "Could Not Import Selected Videos"
                    ),
                    detail: String(
                        localized: "scan.import.failed.detail",
                        defaultValue: "The selected videos remain in the scan results."
                    )
                )
                let failedResults = LibraryScanResults(
                    candidates: currentResults.candidates,
                    checkedFolderCount: currentResults.checkedFolderCount,
                    uncheckedFolderCount: currentResults.uncheckedFolderCount,
                    failedFolderCount: currentResults.failedFolderCount,
                    notice: failedNotice
                )
                scanResults = failedResults
                onScanStateChanged?(.results(failedResults))
                onImportStateChanged?(.failed(message: failedNotice.detail))
                return
            }
            let uniqueAddedIDs = stableUniqueVideoIDs(addedVideoIDs)
            let addedIDSet = Set(uniqueAddedIDs)
            let uniqueExistingIDs = stableUniqueVideoIDs(existingVideoIDs).filter {
                addedIDSet.contains($0) == false
            }
            scanSessionAddedVideoIDs = stableUniqueVideoIDs(
                scanSessionAddedVideoIDs + uniqueAddedIDs
            )
            let sessionAddedIDSet = Set(scanSessionAddedVideoIDs)
            scanSessionExistingVideoIDs = stableUniqueVideoIDs(
                scanSessionExistingVideoIDs + uniqueExistingIDs
            ).filter {
                sessionAddedIDSet.contains($0) == false
            }
            let scanScopeIsComplete = currentResults.uncheckedFolderCount == 0
                && currentResults.failedFolderCount == 0
            if remaining.isEmpty, failedInputCount == 0, scanScopeIsComplete {
                let completion = LibraryScanCompletion(
                    addedVideoIDs: scanSessionAddedVideoIDs,
                    existingVideoIDs: scanSessionExistingVideoIDs
                )
                scanResults = nil
                scanSessionAddedVideoIDs = []
                scanSessionExistingVideoIDs = []
                onImportStateChanged?(.idle)
                onScanStateChanged?(.completed(completion))
                return
            }
            let completedCount = completedCandidateIDs.count
            let notice = LibraryScanNotice(
                title: existingCount == 0
                    ? addedCount == 1
                        ? String(
                            localized: "scan.import.completed.title.one",
                            defaultValue: "Imported 1 Video"
                        )
                        : String(
                            localized: "scan.import.completed.title.many",
                            defaultValue: "Imported \(addedCount) Videos"
                        )
                    : completedCount == 1
                        ? String(
                            localized: "scan.import.completed.processed.one",
                            defaultValue: "Processed 1 Video"
                        )
                        : String(
                            localized: "scan.import.completed.processed.many",
                            defaultValue: "Processed \(completedCount) Videos"
                        ),
                detail: remaining.isEmpty
                    ? String(
                        localized: "scan.import.completed.scopeIncomplete",
                        defaultValue: "All discovered videos were processed."
                    )
                    : remaining.count == 1
                        ? String(
                            localized: "scan.import.completed.remaining.one",
                            defaultValue: "1 video remains to be imported."
                        )
                        : String(
                            localized: "scan.import.completed.remaining.many",
                            defaultValue: "\(remaining.count) videos remain to be imported."
                        )
            )
            let updatedResults = LibraryScanResults(
                candidates: remaining,
                checkedFolderCount: currentResults.checkedFolderCount,
                uncheckedFolderCount: currentResults.uncheckedFolderCount,
                failedFolderCount: currentResults.failedFolderCount,
                notice: notice
            )
            scanResults = updatedResults
            onScanStateChanged?(.results(updatedResults))
            onImportStateChanged?(.completed(LibraryImportSummary(
                title: notice.title,
                addedCount: addedCount,
                existingCount: existingCount,
                failedVideoCount: 0,
                failedInputCount: failedInputCount,
                addedVideoIDs: uniqueAddedIDs,
                existingVideoIDs: uniqueExistingIDs,
                checkedInputCount: candidates.count,
                checkedFolderCount: grouped.count,
                createdFolderTagCount: createdFolderTagIDs.count
            )))
        }
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
                            createdAt: Date(),
                            scansDescendants: source.kind == .directory
                        ))
                        sourceScansDescendants[source.id] = source.kind == .directory
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
        if currentFilter != query.baseFilter && recoveryTask == nil { recoveryStatus.message = nil }
        currentFilter = query.baseFilter
        publishRecoveryStatus()
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
            deferredMediaVideos.removeAll()
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
        guard recoveryTask == nil, videoIDs.isEmpty == false else {
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
                for videoID in videoIDs {
                    pendingMediaVideos.removeValue(forKey: videoID)
                    deferredMediaVideos.remove(id: videoID)
                }
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
        guard recoveryTask == nil, video.availability == .unavailable,
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
                    createdAt: Date(),
                    scansDescendants: false
                ))
                sourceWasPersisted = true
                sourceDisplayNames[source.id] = source.url.lastPathComponent
                sourceScansDescendants[source.id] = false
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
        sourceScansDescendants.removeValue(forKey: sourceID)
        sourceScanPolicyExplicit.removeValue(forKey: sourceID)
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

    private func verifiedRecoveryCandidate(videoID: String, file: URL, sourceID: String,
                                           relativePath: String) async throws -> DiscoveredVideo? {
        let discovery = self.discovery
        let worker = Task.detached(priority: .utility) { () throws -> DiscoveredVideo in
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.isAliasFile != true,
                  file.resolvingSymlinksInPath().standardizedFileURL == file else { throw RelinkFlowError.invalidVideo }
            let result = try discovery.discoverVideoResult(at: file)
            guard result.failedCount == 0, result.videos.count == 1, let candidate = result.videos.first else {
                throw RelinkFlowError.invalidVideo
            }
            return candidate.withContentFingerprint(try contentFingerprint(for: file))
        }
        let candidate = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        let positioned = candidate.relativeToRecoveryDirectory(path: relativePath)
        let assessment = try await database.assessRelinkVideo(id: videoID, sourceID: sourceID,
            discoveredVideo: positioned, allowAvailableRecord: true)
        guard assessment == .exactMatch else { return nil }
        guard let mediaService else { throw RelinkFlowError.invalidVideo }
        _ = try await mediaService.inspectVideo(fileURL: file)
        let recheck = Task.detached(priority: .utility) {
            let fingerprint = try contentFingerprint(for: file)
            let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
            guard fingerprint == positioned.contentFingerprint,
                  Int64(attributes.fileSize ?? -1) == positioned.fileSize,
                  attributes.contentModificationDate == positioned.modificationDate,
                  attributes.isSymbolicLink != true else { throw RelinkFlowError.fileChangedDuringReview }
        }
        try await withTaskCancellationHandler { try await recheck.value } onCancel: { recheck.cancel() }
        try Task.checkCancellation()
        return positioned
    }

    private func restoreAccessibleProtectedVideos() async throws {
        let locations = try await database.fetchVideoLocations(includeUnavailable: true)
        var restoredIDs = Set(resolvedVideoURLs.keys)
        // Only previously lost positions are checked. Healthy positions keep normal startup behavior.
        for location in locations where location.requiresRecoveryVerification {
            try Task.checkCancellation()
            guard !restoredIDs.contains(location.videoID), let path = location.lastKnownPath,
                  let video = try await database.fetchVideo(id: location.videoID),
                  video.availability == .available, video.contentFingerprint != nil else { continue }
            let file = URL(fileURLWithPath: path).standardizedFileURL
            guard !Self.isURLInTrash(file), !Self.isOnUnmountedExternalVolume(file) else { continue }
            let scopes = sourceURLs.filter { id, root in
                let normalizedRoot = root.standardizedFileURL
                return resources[id] != nil && (normalizedRoot == file || Self.isURL(file, inside: normalizedRoot))
            }.sorted { left, right in
                if left.value.pathComponents.count != right.value.pathComponents.count {
                    return left.value.pathComponents.count > right.value.pathComponents.count
                }
                return left.key < right.key
            }
            guard let (sourceID, root) = scopes.first, let originalFingerprint = video.contentFingerprint else { continue }
            let probe = Task.detached(priority: .utility) { () throws -> RecoveryFileObservation in
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return RecoveryFileObservation(sourceID: sourceID, path: file.path, size: values.fileSize,
                    modified: values.contentModificationDate, originalFingerprint: originalFingerprint)
            }
            guard let observation = try? await probe.value else { continue }
            let observationKey = location.videoID + "|" + file.path
            guard automaticRecoveryObservations[observationKey] != observation else { continue }
            let relativePath = file.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count).joined(separator: "/")
            do {
                guard let candidate = try await verifiedRecoveryCandidate(videoID: video.id, file: file,
                    sourceID: sourceID, relativePath: relativePath) else {
                    automaticRecoveryObservations[observationKey] = observation
                    continue
                }
                _ = try await database.relinkVideo(id: video.id, sourceID: sourceID,
                    discoveredVideo: candidate, allowAvailableRecord: true)
                restoredIDs.insert(video.id)
            } catch is CancellationError { throw CancellationError() }
            catch {
                automaticRecoveryObservations[observationKey] = observation
                AppLogger.library.notice("Automatic recovery left a video pending verification")
            }
        }
    }

    private func scheduleMaintenance() {
        guard !isRestoringLibrary, recoveryTask == nil else { return }
        maintenanceDebounceTask?.cancel()
        maintenanceDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                self?.startMaintenance()
            } catch {}
        }
    }

    private func startMaintenance() {
        guard !isRestoringLibrary, recoveryTask == nil, importTask == nil, relinkTask == nil else { return }
        maintenanceTask?.cancel()
        let discovery = self.discovery
        let database = self.database
        maintenanceTask = Task(priority: .utility) { [weak self] in
            do {
                guard let self else { return }
                await refreshSourceURLsFromBookmarks()
                try await refreshResolvedVideoURLs()
                try await restoreAccessibleProtectedVideos()
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
                // Exact-content recovery can preserve all metadata while the JPEG cache is absent.
                // Queue accessible records for the background needsProcessing check as well.
                let videos = try await database.fetchVideos(libraryID: LibraryRecord.primaryID)
                startMediaProcessing(videos: videos)
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
                    createdAt: Date(),
                    scansDescendants: sourceScansDescendants[sourceID] ?? false,
                    scanPolicyExplicit: sourceScanPolicyExplicit[sourceID] ?? true
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
        let lostLocations = locations.filter {
            !$0.requiresRecoveryVerification && !activeSourceIDs.contains($0.sourceID)
                && resolution.accessLostSourceNames[$0.videoID] != nil
        }
        try await database.protectLostLocations(lostLocations)
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
        if recoveryTask == nil {
            let readyVideos = deferredMediaVideos.takeReady(resolvedURLs: resolvedVideoURLs)
            if !readyVideos.isEmpty { startMediaProcessing(videos: readyVideos) }
        }
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
            if location.requiresRecoveryVerification, let path = location.lastKnownPath {
                if paths[location.videoID] == nil { paths[location.videoID] = path }
                continue
            }
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
            if location.requiresRecoveryVerification {
                if let path = location.lastKnownPath, isOnUnmountedExternalVolume(URL(fileURLWithPath: path)) {
                    offlineCandidates[location.videoID] = sourceDisplayNames[location.sourceID] ?? ""
                } else {
                    accessLostCandidates[location.videoID] = sourceDisplayNames[location.sourceID] ?? ""
                }
                continue
            }
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
            if let path = location.lastKnownPath, !path.hasPrefix("/Volumes/") {
                volumeIsOffline = false
            } else if let volumeIdentifier = location.volumeIdentifier {
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
            resolvedURLs[$0.key] == nil && offlineCandidates[$0.key] == nil
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

    nonisolated private static func isDirectoryURL(_ url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
           let isDirectory = values.isDirectory {
            return isDirectory
        }
        return url.hasDirectoryPath
    }

    nonisolated private static func collapsedDirectorySources(
        _ sources: [String: URL]
    ) -> [(String, URL)] {
        let ordered = sources.sorted {
            let leftCount = $0.value.standardizedFileURL.pathComponents.count
            let rightCount = $1.value.standardizedFileURL.pathComponents.count
            if leftCount != rightCount { return leftCount < rightCount }
            return $0.value.path.localizedStandardCompare($1.value.path) == .orderedAscending
        }
        var result: [(String, URL)] = []
        for (sourceID, sourceURL) in ordered {
            let standardizedURL = sourceURL.standardizedFileURL
            if result.contains(where: { isURL(standardizedURL, inside: $0.1) }) {
                continue
            }
            result.append((sourceID, standardizedURL))
        }
        return result
    }

    nonisolated private static func uncoveredFileParentCount(
        sourceURLs: [String: URL],
        scansDescendants: [String: Bool]
    ) -> Int {
        let directoryURLs = sourceURLs.compactMap { sourceID, sourceURL in
            scansDescendants[sourceID] == true && isDirectoryURL(sourceURL)
                ? sourceURL.standardizedFileURL
                : nil
        }
        let parents = sourceURLs.compactMap { sourceID, sourceURL -> URL? in
            guard scansDescendants[sourceID] != true,
                  isDirectoryURL(sourceURL) == false else { return nil }
            let parent = sourceURL.deletingLastPathComponent().standardizedFileURL
            guard directoryURLs.contains(where: { isURL(parent, inside: $0) }) == false else {
                return nil
            }
            return parent
        }
        return Set(parents.map(\.path)).count
    }

    nonisolated private static func fileURL(
        sourceURL: URL,
        relativePath: String
    ) -> URL? {
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.contains("..") == false else { return nil }
        return components.reduce(sourceURL.standardizedFileURL) { url, component in
            url.appendingPathComponent(component)
        }.standardizedFileURL
    }

    private func startMediaProcessing(videos: [VideoRecord]) {
        guard recoveryTask == nil else { return }
        guard let mediaService else { return }
        for video in videos {
            if resolvedVideoURLs[video.id] != nil {
                deferredMediaVideos.remove(id: video.id)
                pendingMediaVideos[video.id] = video
            } else {
                deferredMediaVideos.hold(video)
            }
        }
        guard !pendingMediaVideos.isEmpty else { return }
        guard mediaTask == nil else { return }
        let database = self.database

        mediaTask = Task { [weak self] in
            guard let self else { return }
            defer { mediaTask = nil }
            while !pendingMediaVideos.isEmpty {
                let preferredID = mediaPriorityVideoIDs?().first { pendingMediaVideos[$0] != nil }
                let next = preferredID.flatMap { pendingMediaVideos[$0] } ?? pendingMediaVideos.values.min {
                    if $0.firstIndexedAt != $1.firstIndexedAt { return $0.firstIndexedAt > $1.firstIndexedAt }
                    return $0.id < $1.id
                }
                guard let queued = next else { break }
                pendingMediaVideos.removeValue(forKey: queued.id)
                var generatedThumbnailID: String?
                do {
                    try Task.checkCancellation()
                    guard let fileURL = resolvedVideoURLs[queued.id] else {
                        deferredMediaVideos.hold(queued)
                        continue
                    }
                    let mediaSnapshot = try await database.mediaProcessingSnapshot(videoID: queued.id,
                            pathKey: fallbackPathKey(for: fileURL))
                    guard let snapshot = mediaSnapshot,
                          await mediaService.needsProcessing(snapshot.video) else { continue }
                    let video = snapshot.video
                    let result = await mediaService.process(video: video, fileURL: fileURL)
                    generatedThumbnailID = result.generatedThumbnailID
                    try Task.checkCancellation()
                    let stillSamePath = resolvedVideoURLs[video.id]?.standardizedFileURL == fileURL.standardizedFileURL
                    let updated: VideoRecord?
                    if stillSamePath { updated = try await database.commitMediaProcessing(result, expected: snapshot) }
                    else { updated = nil }
                    if let updated {
                        generatedThumbnailID = nil // The database now owns this artifact.
                        onVideoChanged?(presentedVideo(updated))
                        if video.duration != updated.duration || video.width != updated.width || video.height != updated.height
                            || video.mediaSourceInfo != updated.mediaSourceInfo || video.metadataStatus != updated.metadataStatus {
                            scheduleMediaFactsRefresh()
                        }
                        if let oldID = video.thumbnailID, oldID != updated.thumbnailID,
                           try await database.isThumbnailReferenced(oldID) == false {
                            try? await mediaService.removeThumbnails(identifiers: [oldID])
                        }
                    } else {
                        if let generatedThumbnailID {
                            try? await mediaService.removeThumbnails(identifiers: [generatedThumbnailID])
                        }
                        generatedThumbnailID = nil
                        // Requeue only a changed, still accessible snapshot, never a removed/protected record.
                        if let latestURL = resolvedVideoURLs[video.id],
                           let latest = try await database.mediaProcessingSnapshot(videoID: video.id,
                             pathKey: fallbackPathKey(for: latestURL)), latest != snapshot {
                            pendingMediaVideos[video.id] = latest.video
                        }
                    }
                } catch is CancellationError {
                    if let generatedThumbnailID { try? await mediaService.removeThumbnails(identifiers: [generatedThumbnailID]) }
                    return
                } catch {
                    if let generatedThumbnailID { try? await mediaService.removeThumbnails(identifiers: [generatedThumbnailID]) }
                    AppLogger.library.error("Media processing failed with category: \(String(describing: type(of: error)), privacy: .public)")
                }
            }
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
        if recoveryTask == nil {
            recoveryCandidates = try await database.fetchVideos(libraryID: LibraryRecord.primaryID)
                .map { presentedVideo($0) }.filter { $0.unavailableReason == .accessLost }
            recoveryStatus.candidateCount = recoveryCandidates.count
            publishRecoveryStatus()
        }
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

struct RecoveryStatus: Equatable {
    var candidateCount = 0
    var running = false
    var total = 0
    var completed = 0
    var showEntry = false
    var canStart = true
    var message: String?
}


// Record only unresolved work; permission and identity are rechecked by the worker once resolved.
struct DeferredMediaVideos {
    private var videos: [String: VideoRecord] = [:]

    mutating func hold(_ video: VideoRecord) { videos[video.id] = video }
    mutating func remove(id: String) { videos.removeValue(forKey: id) }
    mutating func removeAll() { videos.removeAll() }

    mutating func takeReady(resolvedURLs: [String: URL]) -> [VideoRecord] {
        let ids = videos.keys.filter { resolvedURLs[$0] != nil }
        return ids.compactMap { videos.removeValue(forKey: $0) }
    }
}
