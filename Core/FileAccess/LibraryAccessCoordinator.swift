import Foundation

struct LibrarySummary: Equatable, Sendable {
    let name: String
}

@MainActor
final class LibraryAccessCoordinator {
    private let database: DatabaseStore
    private let picker: LibraryPicker
    private var activeResource: SecurityScopedResource?

    var onLibraryChanged: ((LibrarySummary) -> Void)?
    var onError: ((String) -> Void)?

    init(database: DatabaseStore, picker: LibraryPicker = LibraryPicker()) {
        self.database = database
        self.picker = picker
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
                    try await database.saveLibrary(record)
                    AppLogger.library.notice("Library authorization saved")
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

    private func connect(url: URL) throws {
        guard let resource = SecurityScopedResource(url: url) else {
            throw CocoaError(.fileReadNoPermission)
        }
        activeResource = resource
        onLibraryChanged?(LibrarySummary(name: url.lastPathComponent))
    }

    private func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}
