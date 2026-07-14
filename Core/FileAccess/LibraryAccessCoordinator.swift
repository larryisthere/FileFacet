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
    private var activeResource: SecurityScopedResource?
    private var scanTask: Task<Void, Never>?

    var onLibraryChanged: ((LibrarySummary) -> Void)?
    var onVideosChanged: (([VideoRecord]) -> Void)?
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
                AppLogger.library.notice("Library scan completed with \(videos.count, privacy: .public) videos")
            } catch is CancellationError {
                AppLogger.library.notice("Library scan cancelled")
            } catch {
                AppLogger.library.error("Library scan failed with category: \(String(describing: type(of: error)), privacy: .public)")
                onScanStateChanged?(.failed(message: "扫描未完成，仍显示上一次成功建立的索引。"))
            }
        }
    }
}
