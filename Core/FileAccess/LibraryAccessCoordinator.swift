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

    var onLibraryChanged: ((LibrarySummary) -> Void)?
    var onVideosChanged: (([VideoRecord]) -> Void)?
    var onVideoChanged: ((VideoRecord) -> Void)?
    var onScanStateChanged: ((LibraryScanState) -> Void)?
    var onError: ((String) -> Void)?

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

                let existingVideos = try await database.fetchVideos(libraryID: record.id)
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

    private func connect(url: URL) throws {
        guard let resource = SecurityScopedResource(url: url) else {
            throw CocoaError(.fileReadNoPermission)
        }
        activeResource = resource
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
                onVideosChanged?(videos)
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
}
