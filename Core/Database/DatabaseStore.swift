import Foundation
import SQLite3

struct SourceAuthorizationRecord: Equatable, Sendable {
    let id: String
    let libraryID: String
    let displayName: String
    let rootBookmarkData: Data
    let createdAt: Date
    let scansDescendants: Bool
    let scanPolicyExplicit: Bool

    init(
        id: String,
        libraryID: String,
        displayName: String,
        rootBookmarkData: Data,
        createdAt: Date,
        scansDescendants: Bool = false,
        scanPolicyExplicit: Bool = true
    ) {
        self.id = id
        self.libraryID = libraryID
        self.displayName = displayName
        self.rootBookmarkData = rootBookmarkData
        self.createdAt = createdAt
        self.scansDescendants = scansDescendants
        self.scanPolicyExplicit = scanPolicyExplicit
    }
}

struct VideoLocationRecord: Equatable, Sendable {
    let videoID: String
    let sourceID: String
    let relativePath: String
    let fallbackPathKey: Data?
    let volumeIdentifier: Data?
    let lastKnownPath: String?
    let requiresRecoveryVerification: Bool

    init(
        videoID: String,
        sourceID: String,
        relativePath: String,
        fallbackPathKey: Data? = nil,
        volumeIdentifier: Data? = nil,
        lastKnownPath: String? = nil,
        requiresRecoveryVerification: Bool = false
    ) {
        self.videoID = videoID
        self.sourceID = sourceID
        self.relativePath = relativePath
        self.fallbackPathKey = fallbackPathKey
        self.volumeIdentifier = volumeIdentifier
        self.lastKnownPath = lastKnownPath
        self.requiresRecoveryVerification = requiresRecoveryVerification
    }
}

struct VideoLocationFallbackUpdate: Equatable, Sendable {
    let videoID: String
    let sourceID: String
    let relativePath: String
    let fallbackPathKey: Data
}

struct VideoLocationLastKnownPathUpdate: Equatable, Sendable {
    let videoID: String
    let sourceID: String
    let relativePath: String
    let lastKnownPath: String
}

struct VideoImportResult: Equatable, Sendable {
    let addedCount: Int
    let existingCount: Int
    let failedCount: Int
    let addedVideoIDs: [String]
    let existingVideoIDs: [String]
    let importedVideos: [VideoRecord]
    let createdFolderTagIDs: Set<String>
}

struct FolderTagImportOptions: Equatable, Sendable {
    let selectedRootName: String?
}

private struct FolderTagLookupKey: Hashable {
    let parentID: String?
    let normalizedName: String
}

private enum LibraryQueryBinding {
    case text(String)
    case integer(Int64)
    case double(Double)
}

struct LibraryMaintenanceResult: Equatable, Sendable {
    let updatedVideoIDs: [String]
    let deletedThumbnailIDs: [String]
}

enum VideoRelinkAssessment: Equatable, Sendable {
    case exactMatch
    case needsConfirmation
    case existingRecord(videoID: String)
}

actor DatabaseStore {
    static let currentSchemaVersion = 14

    private let connection: SQLiteConnection
    private var isPrepared = false

    init(databaseURL: URL) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw DatabaseError.openFailed
        }

        connection = SQLiteConnection(handle: handle)
    }

    static func makeDefault() throws -> DatabaseStore {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(AppConfiguration.bundleIdentifier, isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try DatabaseStore(databaseURL: directory.appendingPathComponent("library.sqlite3"))
    }

    func schemaVersion() throws -> Int {
        try prepareIfNeeded()
        return try scalarInt("SELECT COALESCE(MAX(version), 0) FROM schema_migrations")
    }

    func saveLibrary(_ record: LibraryRecord) throws {
        try prepareIfNeeded()
        let sql = """
        INSERT INTO libraries (id, name, root_bookmark_data, created_at, last_scan_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            root_bookmark_data = excluded.root_bookmark_data,
            last_scan_at = excluded.last_scan_at
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        bindText(record.id, to: 1, in: statement)
        bindText(record.name, to: 2, in: statement)
        _ = record.rootBookmarkData.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
        sqlite3_bind_double(statement, 4, record.createdAt.timeIntervalSince1970)
        if let lastScanAt = record.lastScanAt {
            sqlite3_bind_double(statement, 5, lastScanAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 5)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.statementFailed
        }
    }

    func fetchPrimaryLibrary() throws -> LibraryRecord? {
        try prepareIfNeeded()
        let statement = try prepare(
            "SELECT id, name, root_bookmark_data, created_at, last_scan_at FROM libraries WHERE id = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        bindText(LibraryRecord.primaryID, to: 1, in: statement)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard
            let idText = sqlite3_column_text(statement, 0),
            let nameText = sqlite3_column_text(statement, 1),
            let bookmarkBytes = sqlite3_column_blob(statement, 2)
        else {
            throw DatabaseError.statementFailed
        }

        let bookmarkSize = Int(sqlite3_column_bytes(statement, 2))
        let bookmarkData = Data(bytes: bookmarkBytes, count: bookmarkSize)
        let lastScanAt = sqlite3_column_type(statement, 4) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))

        return LibraryRecord(
            id: String(cString: idText),
            name: String(cString: nameText),
            rootBookmarkData: bookmarkData,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            lastScanAt: lastScanAt
        )
    }

    func saveSourceAuthorization(_ record: SourceAuthorizationRecord) throws {
        try prepareIfNeeded()
        let statement = try prepare(
            """
            INSERT INTO source_authorizations (
                id, library_id, display_name, root_bookmark_data, created_at,
                health_status, scans_descendants, scan_policy_explicit
            ) VALUES (?, ?, ?, ?, ?, 'available', ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                root_bookmark_data = excluded.root_bookmark_data,
                health_status = 'available',
                scans_descendants = excluded.scans_descendants,
                scan_policy_explicit = excluded.scan_policy_explicit
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(record.id, to: 1, in: statement)
        bindText(record.libraryID, to: 2, in: statement)
        bindText(record.displayName, to: 3, in: statement)
        bindData(record.rootBookmarkData, to: 4, in: statement)
        sqlite3_bind_double(statement, 5, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 6, record.scansDescendants ? 1 : 0)
        sqlite3_bind_int(statement, 7, record.scanPolicyExplicit ? 1 : 0)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.statementFailed
        }
    }

    func fetchSourceAuthorizations(libraryID: String = LibraryRecord.primaryID) throws -> [SourceAuthorizationRecord] {
        try prepareIfNeeded()
        let statement = try prepare(
            """
            SELECT id, library_id, display_name, root_bookmark_data, created_at,
                   scans_descendants, scan_policy_explicit
            FROM source_authorizations
            WHERE library_id = ?
            ORDER BY created_at, id
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(libraryID, to: 1, in: statement)
        var records: [SourceAuthorizationRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(at: 0, in: statement),
                  let storedLibraryID = text(at: 1, in: statement),
                  let displayName = text(at: 2, in: statement),
                  let bookmark = data(at: 3, in: statement) else {
                throw DatabaseError.statementFailed
            }
            records.append(SourceAuthorizationRecord(
                id: id,
                libraryID: storedLibraryID,
                displayName: displayName,
                rootBookmarkData: bookmark,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                scansDescendants: sqlite3_column_int(statement, 5) != 0,
                scanPolicyExplicit: sqlite3_column_int(statement, 6) != 0
            ))
        }
        return records
    }

    func removeUnreferencedSourceAuthorizations(candidateIDs: [String]? = nil) throws -> [String] {
        try prepareIfNeeded()
        try execute("BEGIN IMMEDIATE")
        do {
            var restriction = ""
            if let candidateIDs {
                try execute("CREATE TEMP TABLE IF NOT EXISTS pending_source_cleanup_ids (id TEXT PRIMARY KEY)")
                try execute("DELETE FROM pending_source_cleanup_ids")
                let insert = try prepare(
                    "INSERT OR IGNORE INTO pending_source_cleanup_ids (id) VALUES (?)"
                )
                for id in Set(candidateIDs) {
                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                    bindText(id, to: 1, in: insert)
                    guard sqlite3_step(insert) == SQLITE_DONE else {
                        sqlite3_finalize(insert)
                        throw DatabaseError.statementFailed
                    }
                }
                sqlite3_finalize(insert)
                restriction = "AND id IN (SELECT id FROM pending_source_cleanup_ids)"
            }

            let lookup = try prepare(
                """
                SELECT id FROM source_authorizations
                WHERE scans_descendants = 0
                  AND NOT EXISTS (
                    SELECT 1 FROM video_locations
                    WHERE video_locations.source_id = source_authorizations.id
                )
                \(restriction)
                """
            )
            var sourceIDs: [String] = []
            while sqlite3_step(lookup) == SQLITE_ROW {
                if let id = text(at: 0, in: lookup) { sourceIDs.append(id) }
            }
            sqlite3_finalize(lookup)

            if sourceIDs.isEmpty == false {
                try execute("CREATE TEMP TABLE IF NOT EXISTS removable_source_ids (id TEXT PRIMARY KEY)")
                try execute("DELETE FROM removable_source_ids")
                let insert = try prepare(
                    "INSERT OR IGNORE INTO removable_source_ids (id) VALUES (?)"
                )
                for id in sourceIDs {
                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                    bindText(id, to: 1, in: insert)
                    guard sqlite3_step(insert) == SQLITE_DONE else {
                        sqlite3_finalize(insert)
                        throw DatabaseError.statementFailed
                    }
                }
                sqlite3_finalize(insert)
                try execute("DELETE FROM source_authorizations WHERE id IN (SELECT id FROM removable_source_ids)")
                try execute("DELETE FROM removable_source_ids")
            }
            if candidateIDs != nil { try execute("DELETE FROM pending_source_cleanup_ids") }
            try execute("COMMIT")
            return sourceIDs
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func fetchReferencedThumbnailIDs() throws -> Set<String> {
        try prepareIfNeeded()
        let statement = try prepare(
            "SELECT thumbnail_id FROM videos WHERE thumbnail_id IS NOT NULL"
        )
        defer { sqlite3_finalize(statement) }
        var identifiers = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let identifier = text(at: 0, in: statement) { identifiers.insert(identifier) }
        }
        return identifiers
    }

    func fetchVideoLocations(includeUnavailable: Bool = false, videoID: String? = nil) throws -> [VideoLocationRecord] {
        try prepareIfNeeded()
        var locationConditions: [String] = includeUnavailable ? [] : ["video_locations.is_available = 1"]
        if videoID != nil { locationConditions.append("video_locations.video_id = ?") }
        let availabilityClause = locationConditions.isEmpty ? "" : "WHERE " + locationConditions.joined(separator: " AND ")
        let statement = try prepare(
            """
            SELECT video_locations.video_id, video_locations.source_id,
                   video_locations.relative_path, video_locations.fallback_path_key,
                   videos.volume_identifier, video_locations.last_known_path, video_locations.requires_recovery_verification
            FROM video_locations
            JOIN videos ON videos.id = video_locations.video_id
            \(availabilityClause)
            ORDER BY video_locations.last_verified_at DESC, video_locations.source_id, video_locations.relative_path
            """
        )
        defer { sqlite3_finalize(statement) }
        if let videoID { bindText(videoID, to: 1, in: statement) }
        var records: [VideoLocationRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let videoID = text(at: 0, in: statement),
                  let sourceID = text(at: 1, in: statement),
                  let relativePath = text(at: 2, in: statement) else {
                throw DatabaseError.statementFailed
            }
            records.append(VideoLocationRecord(
                videoID: videoID,
                sourceID: sourceID,
                relativePath: relativePath,
                fallbackPathKey: data(at: 3, in: statement),
                volumeIdentifier: data(at: 4, in: statement),
                lastKnownPath: text(at: 5, in: statement),
                requiresRecoveryVerification: sqlite3_column_int(statement, 6) != 0
            ))
        }
        return records
    }

    func backfillVideoLocationFallbackKeys(_ updates: [VideoLocationFallbackUpdate]) async throws {
        try prepareIfNeeded()
        let batchSize = 100
        var batchStart = 0
        while batchStart < updates.count {
            try Task.checkCancellation()
            let batchEnd = min(updates.count, batchStart + batchSize)
            try execute("BEGIN IMMEDIATE")
            do {
                let statement = try prepare(
                    """
                    UPDATE video_locations
                    SET fallback_path_key = ?
                    WHERE video_id = ? AND source_id = ? AND relative_path = ?
                      AND requires_recovery_verification = 0
                      AND fallback_path_key IS NULL
                    """
                )
                defer { sqlite3_finalize(statement) }
                for update in updates[batchStart..<batchEnd] {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bindData(update.fallbackPathKey, to: 1, in: statement)
                    bindText(update.videoID, to: 2, in: statement)
                    bindText(update.sourceID, to: 3, in: statement)
                    bindText(update.relativePath, to: 4, in: statement)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.statementFailed
                    }
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
            batchStart = batchEnd
            await Task.yield()
        }
    }

    func updateVideoLocationLastKnownPaths(
        _ updates: [VideoLocationLastKnownPathUpdate]
    ) async throws {
        try prepareIfNeeded()
        let batchSize = 100
        var batchStart = 0
        while batchStart < updates.count {
            try Task.checkCancellation()
            let batchEnd = min(updates.count, batchStart + batchSize)
            try execute("BEGIN IMMEDIATE")
            do {
                let statement = try prepare(
                    """
                    UPDATE video_locations
                    SET last_known_path = ?
                    WHERE video_id = ? AND source_id = ? AND relative_path = ?
                      AND requires_recovery_verification = 0
                    """
                )
                defer { sqlite3_finalize(statement) }
                for update in updates[batchStart..<batchEnd] {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bindText(update.lastKnownPath, to: 1, in: statement)
                    bindText(update.videoID, to: 2, in: statement)
                    bindText(update.sourceID, to: 3, in: statement)
                    bindText(update.relativePath, to: 4, in: statement)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.statementFailed
                    }
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
            batchStart = batchEnd
            await Task.yield()
        }
    }

    func confirmMissingLocations(_ locations: [VideoLocationRecord]) throws {
        try prepareIfNeeded()
        guard locations.isEmpty == false else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let locationStatement = try prepare(
                """
                UPDATE video_locations
                SET is_available = 0
                WHERE video_id = ? AND source_id = ? AND relative_path = ?
                      AND requires_recovery_verification = 0
                """
            )
            for location in locations {
                sqlite3_reset(locationStatement)
                sqlite3_clear_bindings(locationStatement)
                bindText(location.videoID, to: 1, in: locationStatement)
                bindText(location.sourceID, to: 2, in: locationStatement)
                bindText(location.relativePath, to: 3, in: locationStatement)
                guard sqlite3_step(locationStatement) == SQLITE_DONE else {
                    sqlite3_finalize(locationStatement)
                    throw DatabaseError.statementFailed
                }
            }
            sqlite3_finalize(locationStatement)

            let invalidatedAt = Date().timeIntervalSince1970
            let videoStatement = try prepare(
                """
                UPDATE videos
                SET availability_status = 'missing',
                    invalidated_at = COALESCE(invalidated_at, ?),
                    updated_at = ?
                WHERE id = ?
                  AND availability_status = 'available'
                  AND NOT EXISTS (
                      SELECT 1 FROM video_locations
                      WHERE video_locations.video_id = videos.id
                        AND (video_locations.is_available = 1 OR video_locations.requires_recovery_verification = 1)
                  )
                """
            )
            for videoID in Set(locations.map(\.videoID)) {
                sqlite3_reset(videoStatement)
                sqlite3_clear_bindings(videoStatement)
                sqlite3_bind_double(videoStatement, 1, invalidatedAt)
                sqlite3_bind_double(videoStatement, 2, invalidatedAt)
                bindText(videoID, to: 3, in: videoStatement)
                guard sqlite3_step(videoStatement) == SQLITE_DONE else {
                    sqlite3_finalize(videoStatement)
                    throw DatabaseError.statementFailed
                }
            }
            sqlite3_finalize(videoStatement)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func importVideos(
        sourceID: String,
        discoveredVideos: [DiscoveredVideo],
        discoveryFailedCount: Int = 0,
        folderTagOptions: FolderTagImportOptions? = nil,
        importedAt: Date = Date()
    ) async throws -> VideoImportResult {
        try prepareIfNeeded()
        try Task.checkCancellation()
        let runID = UUID().uuidString
        var recoveryBlockedCount = 0
        var addedCount = 0
        var existingCount = 0
        var addedVideoIDs: [String] = []
        var existingVideoIDs: [String] = []
        var createdFolderTagIDs = Set<String>()
        var folderTagCache: [FolderTagLookupKey: String] = [:]
        let start = try prepare(
            "INSERT INTO import_runs (id, source_id, started_at, status) VALUES (?, ?, ?, 'running')"
        )
        bindText(runID, to: 1, in: start)
        bindText(sourceID, to: 2, in: start)
        sqlite3_bind_double(start, 3, importedAt.timeIntervalSince1970)
        guard sqlite3_step(start) == SQLITE_DONE else {
            sqlite3_finalize(start)
            throw DatabaseError.statementFailed
        }
        sqlite3_finalize(start)

        do {
            let batchSize = 100
            var batchStart = 0
            while batchStart < discoveredVideos.count {
                try Task.checkCancellation()
                let batchEnd = min(discoveredVideos.count, batchStart + batchSize)
                var batchAddedCount = 0
                var batchExistingCount = 0
                var batchAddedVideoIDs: [String] = []
                var batchExistingVideoIDs: [String] = []
                var batchCreatedFolderTagIDs = Set<String>()
                try execute("BEGIN IMMEDIATE")
                do {
                    for video in discoveredVideos[batchStart..<batchEnd] {
                        try Task.checkCancellation()
                        let videoID: String
                        if let existingID = try existingVideoID(for: video, sourceID: sourceID) {
                            videoID = existingID
                            guard try permitsAutomaticUpdate(videoID: existingID, pathKey: video.fallbackPathKey) else {
                                recoveryBlockedCount += 1
                                continue
                            }
                            try updateVideo(videoID: existingID, from: video, updatedAt: importedAt)
                            try upsertLocation(videoID: existingID, sourceID: sourceID, video: video, verifiedAt: importedAt)
                            batchExistingCount += 1
                            batchExistingVideoIDs.append(existingID)
                        } else {
                            videoID = UUID().uuidString
                            try insertVideo(videoID: videoID, video: video, indexedAt: importedAt)
                            try upsertLocation(videoID: videoID, sourceID: sourceID, video: video, verifiedAt: importedAt)
                            try importFinderTags(videoID: videoID, finderTags: video.finderTags, importedAt: importedAt)
                            batchAddedCount += 1
                            batchAddedVideoIDs.append(videoID)
                        }
                        if let folderTagOptions {
                            batchCreatedFolderTagIDs.formUnion(try importFolderTags(
                                videoID: videoID,
                                relativePath: video.relativePath,
                                options: folderTagOptions,
                                importedAt: importedAt,
                                cache: &folderTagCache
                            ))
                        }
                    }
                    try execute("COMMIT")
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
                addedCount += batchAddedCount
                existingCount += batchExistingCount
                addedVideoIDs.append(contentsOf: batchAddedVideoIDs)
                existingVideoIDs.append(contentsOf: batchExistingVideoIDs)
                createdFolderTagIDs.formUnion(batchCreatedFolderTagIDs)
                batchStart = batchEnd
                await Task.yield()
            }
            try updateImportRun(
                id: runID,
                status: "completed",
                addedCount: addedCount,
                existingCount: existingCount,
                failedCount: discoveryFailedCount + recoveryBlockedCount
            )
        } catch is CancellationError {
            try? updateImportRun(
                id: runID,
                status: "cancelled",
                addedCount: addedCount,
                existingCount: existingCount,
                failedCount: discoveryFailedCount + recoveryBlockedCount
            )
            throw CancellationError()
        } catch {
            try? updateImportRun(
                id: runID,
                status: "failed",
                addedCount: addedCount,
                existingCount: existingCount,
                failedCount: discoveryFailedCount + recoveryBlockedCount + 1
            )
            throw error
        }

        let importedIDSet = Set(addedVideoIDs + existingVideoIDs)
        let imported = try fetchVideos(libraryID: LibraryRecord.primaryID, includeMissing: true)
            .filter { importedIDSet.contains($0.id) }
        return VideoImportResult(
            addedCount: addedCount,
            existingCount: existingCount,
            failedCount: discoveryFailedCount + recoveryBlockedCount,
            addedVideoIDs: addedVideoIDs,
            existingVideoIDs: existingVideoIDs,
            importedVideos: imported,
            createdFolderTagIDs: createdFolderTagIDs
        )
    }

    func unimportedVideos(
        sourceID: String,
        discoveredVideos: [DiscoveredVideo]
    ) throws -> [DiscoveredVideo] {
        try prepareIfNeeded()
        var result: [DiscoveredVideo] = []
        result.reserveCapacity(discoveredVideos.count)
        for video in discoveredVideos {
            try Task.checkCancellation()
            if try existingVideoID(for: video, sourceID: sourceID) == nil {
                result.append(video)
            }
        }
        return result
    }

    private func updateImportRun(
        id: String,
        status: String,
        addedCount: Int,
        existingCount: Int,
        failedCount: Int
    ) throws {
        let statement = try prepare(
            """
            UPDATE import_runs
            SET completed_at = ?, status = ?, added_count = ?, existing_count = ?, failed_count = ?
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        bindText(status, to: 2, in: statement)
        sqlite3_bind_int64(statement, 3, Int64(addedCount))
        sqlite3_bind_int64(statement, 4, Int64(existingCount))
        sqlite3_bind_int64(statement, 5, Int64(failedCount))
        bindText(id, to: 6, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.statementFailed
        }
    }

    func reconcileSource(
        sourceID: String,
        discoveredVideos: [DiscoveredVideo],
        verifiedAt: Date = Date()
    ) async throws -> LibraryMaintenanceResult {
        try await reconcileSources(
            discoveredVideosBySource: [sourceID: discoveredVideos],
            verifiedAt: verifiedAt
        )
    }

    func reconcileSources(
        discoveredVideosBySource: [String: [DiscoveredVideo]],
        confirmDeletions: Bool = true,
        verifiedAt: Date = Date()
    ) async throws -> LibraryMaintenanceResult {
        try prepareIfNeeded()
        try Task.checkCancellation()
        var updatedVideoIDs = Set<String>()

        for sourceID in discoveredVideosBySource.keys.sorted() {
            guard let discoveredVideos = discoveredVideosBySource[sourceID] else { continue }
            let existingLocations = try sourceLocationRows(sourceID: sourceID)
            var seenVideoIDs = Set<String>()
            let batchSize = 100
            var batchStart = 0

            while batchStart < discoveredVideos.count {
                try Task.checkCancellation()
                let batchEnd = min(discoveredVideos.count, batchStart + batchSize)
                var batchSeenVideoIDs = Set<String>()
                var batchUpdatedVideoIDs = Set<String>()
                try execute("BEGIN IMMEDIATE")
                do {
                    for video in discoveredVideos[batchStart..<batchEnd] {
                        try Task.checkCancellation()
                        guard let videoID = try existingVideoID(for: video, sourceID: sourceID) else { continue }
                        batchSeenVideoIDs.insert(videoID)
                        guard try permitsAutomaticUpdate(videoID: videoID, pathKey: video.fallbackPathKey) else { continue }
                        let mediaContentChanged = try mediaContentChanged(videoID: videoID, comparedWith: video)
                        try updateVideo(videoID: videoID, from: video, updatedAt: verifiedAt)
                        try removeOtherLocations(videoID: videoID, sourceID: sourceID, keepingPath: video.relativePath)
                        try upsertLocation(videoID: videoID, sourceID: sourceID, video: video, verifiedAt: verifiedAt)
                        if mediaContentChanged { batchUpdatedVideoIDs.insert(videoID) }
                    }
                    try execute("COMMIT")
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
                seenVideoIDs.formUnion(batchSeenVideoIDs)
                updatedVideoIDs.formUnion(batchUpdatedVideoIDs)
                batchStart = batchEnd
                await Task.yield()
            }

            let staleLocations = existingLocations.filter { seenVideoIDs.contains($0.videoID) == false }
            var staleBatchStart = 0
            while staleBatchStart < staleLocations.count {
                try Task.checkCancellation()
                let staleBatchEnd = min(staleLocations.count, staleBatchStart + batchSize)
                try execute("BEGIN IMMEDIATE")
                do {
                    for location in staleLocations[staleBatchStart..<staleBatchEnd] {
                        let statement = try prepare(
                            """
                            UPDATE video_locations
                            SET is_available = 0
                            WHERE video_id = ? AND source_id = ? AND relative_path = ?
                              AND requires_recovery_verification = 0
                            """
                        )
                        bindText(location.videoID, to: 1, in: statement)
                        bindText(sourceID, to: 2, in: statement)
                        bindText(location.relativePath, to: 3, in: statement)
                        guard sqlite3_step(statement) == SQLITE_DONE else {
                            sqlite3_finalize(statement)
                            throw DatabaseError.statementFailed
                        }
                        sqlite3_finalize(statement)
                    }
                    try execute("COMMIT")
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
                staleBatchStart = staleBatchEnd
                await Task.yield()
            }

            await Task.yield()
        }

        try Task.checkCancellation()
        try execute("BEGIN IMMEDIATE")
        do {
            let refreshRemainingPaths = try prepare(
                """
                UPDATE videos
                SET relative_path = (
                    SELECT video_locations.relative_path
                    FROM video_locations
                    WHERE video_locations.video_id = videos.id
                    ORDER BY video_locations.last_verified_at DESC
                    LIMIT 1
                )
                WHERE videos.library_id = ?
                  AND EXISTS (SELECT 1 FROM video_locations WHERE video_locations.video_id = videos.id)
                """
            )
            bindText(LibraryRecord.primaryID, to: 1, in: refreshRemainingPaths)
            guard sqlite3_step(refreshRemainingPaths) == SQLITE_DONE else {
                sqlite3_finalize(refreshRemainingPaths)
                throw DatabaseError.statementFailed
            }
            sqlite3_finalize(refreshRemainingPaths)

            let confirmedSourceIDs = discoveredVideosBySource.keys.sorted()
            guard confirmDeletions, confirmedSourceIDs.isEmpty == false else {
                try execute("COMMIT")
                return LibraryMaintenanceResult(
                    updatedVideoIDs: Array(updatedVideoIDs),
                    deletedThumbnailIDs: []
                )
            }

            let confirmedSourcePlaceholders = Array(
                repeating: "?",
                count: confirmedSourceIDs.count
            ).joined(separator: ", ")
            let invalidLookup = try prepare(
                """
                SELECT videos.id
                FROM videos
                WHERE videos.library_id = ?
                  AND videos.availability_status = 'available'
                  AND EXISTS (
                      SELECT 1 FROM video_locations
                      WHERE video_locations.video_id = videos.id
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM video_locations
                      WHERE video_locations.video_id = videos.id
                        AND (video_locations.is_available = 1 OR video_locations.requires_recovery_verification = 1)
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM video_locations
                      WHERE video_locations.video_id = videos.id
                        AND video_locations.source_id NOT IN (\(confirmedSourcePlaceholders))
                  )
                """
            )
            bindText(LibraryRecord.primaryID, to: 1, in: invalidLookup)
            for (offset, sourceID) in confirmedSourceIDs.enumerated() {
                bindText(sourceID, to: Int32(offset + 2), in: invalidLookup)
            }
            var invalidVideoIDs: [String] = []
            while sqlite3_step(invalidLookup) == SQLITE_ROW {
                if let id = text(at: 0, in: invalidLookup) { invalidVideoIDs.append(id) }
            }
            sqlite3_finalize(invalidLookup)

            let invalidatedAt = verifiedAt
            let markInvalid = try prepare(
                """
                UPDATE videos
                SET availability_status = 'missing', invalidated_at = ?, updated_at = ?
                WHERE id = ? AND availability_status = 'available'
                """
            )
            for videoID in invalidVideoIDs {
                sqlite3_reset(markInvalid)
                sqlite3_clear_bindings(markInvalid)
                sqlite3_bind_double(markInvalid, 1, invalidatedAt.timeIntervalSince1970)
                sqlite3_bind_double(markInvalid, 2, invalidatedAt.timeIntervalSince1970)
                bindText(videoID, to: 3, in: markInvalid)
                guard sqlite3_step(markInvalid) == SQLITE_DONE else {
                    sqlite3_finalize(markInvalid)
                    throw DatabaseError.statementFailed
                }
            }
            sqlite3_finalize(markInvalid)
            updatedVideoIDs.formUnion(invalidVideoIDs)
            try execute("COMMIT")
            return LibraryMaintenanceResult(
                updatedVideoIDs: Array(updatedVideoIDs),
                deletedThumbnailIDs: []
            )
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func existingVideoID(for video: DiscoveredVideo, sourceID: String) throws -> String? {
        if let volumeIdentifier = video.volumeIdentifier,
           let fileResourceIdentifier = video.fileResourceIdentifier {
            let identityLookup = try prepare(
                """
                SELECT id FROM videos
                WHERE library_id = ? AND volume_identifier = ? AND file_resource_identifier = ?
                ORDER BY first_indexed_at
                LIMIT 1
                """
            )
            bindText(LibraryRecord.primaryID, to: 1, in: identityLookup)
            bindData(volumeIdentifier, to: 2, in: identityLookup)
            bindData(fileResourceIdentifier, to: 3, in: identityLookup)
            if sqlite3_step(identityLookup) == SQLITE_ROW, let id = text(at: 0, in: identityLookup) {
                sqlite3_finalize(identityLookup)
                return id
            }
            sqlite3_finalize(identityLookup)
        }

        if let fallbackPathKey = video.fallbackPathKey {
            let urlLookup = try prepare(
                """
                SELECT video_id FROM video_locations
                WHERE fallback_path_key = ?
                ORDER BY last_verified_at DESC
                LIMIT 1
                """
            )
            bindData(fallbackPathKey, to: 1, in: urlLookup)
            if sqlite3_step(urlLookup) == SQLITE_ROW, let id = text(at: 0, in: urlLookup) {
                sqlite3_finalize(urlLookup)
                return id
            }
            sqlite3_finalize(urlLookup)
        }

        let pathLookup = try prepare(
            """
            SELECT video_locations.video_id, videos.volume_identifier, videos.file_resource_identifier
            FROM video_locations
            JOIN videos ON videos.id = video_locations.video_id
            WHERE video_locations.source_id = ? AND video_locations.relative_path = ?
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(pathLookup) }
        bindText(sourceID, to: 1, in: pathLookup)
        bindText(video.relativePath, to: 2, in: pathLookup)
        guard sqlite3_step(pathLookup) == SQLITE_ROW else { return nil }
        if let newVolume = video.volumeIdentifier,
           let newResource = video.fileResourceIdentifier,
           let oldVolume = data(at: 1, in: pathLookup),
           let oldResource = data(at: 2, in: pathLookup),
           oldVolume != newVolume || oldResource != newResource {
            return nil
        }
        return text(at: 0, in: pathLookup)
    }

    private func insertVideo(videoID: String, video: DiscoveredVideo, indexedAt: Date) throws {
        let statement = try prepare(
            """
            INSERT INTO videos (
                id, library_id, relative_path, volume_identifier, file_resource_identifier,
                filename, file_extension, file_size, creation_date, modification_date,
                metadata_status, thumbnail_status, availability_status,
                first_indexed_at, updated_at, finder_tags_imported_at, content_fingerprint
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', 'pending', 'available', ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(videoID, to: 1, in: statement)
        bindText(LibraryRecord.primaryID, to: 2, in: statement)
        bindText(video.relativePath, to: 3, in: statement)
        bindData(video.volumeIdentifier, to: 4, in: statement)
        bindData(video.fileResourceIdentifier, to: 5, in: statement)
        bindText(video.filename, to: 6, in: statement)
        bindText(video.fileExtension, to: 7, in: statement)
        sqlite3_bind_int64(statement, 8, video.fileSize)
        bindDate(video.creationDate, to: 9, in: statement)
        bindDate(video.modificationDate, to: 10, in: statement)
        sqlite3_bind_double(statement, 11, indexedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 12, indexedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 13, indexedAt.timeIntervalSince1970)
        bindData(video.contentFingerprint, to: 14, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.statementFailed
        }
    }

    private func updateVideo(videoID: String, from video: DiscoveredVideo, updatedAt: Date) throws {
        let statement = try prepare(
            """
            UPDATE videos SET
                relative_path = ?, volume_identifier = ?, file_resource_identifier = ?,
                filename = ?, file_extension = ?,
                duration = CASE WHEN file_size != ? OR modification_date IS NOT ? THEN NULL ELSE duration END,
                width = CASE WHEN file_size != ? OR modification_date IS NOT ? THEN NULL ELSE width END,
                height = CASE WHEN file_size != ? OR modification_date IS NOT ? THEN NULL ELSE height END,
                thumbnail_id = CASE WHEN file_size != ? OR modification_date IS NOT ? THEN NULL ELSE thumbnail_id END,
                metadata_status = CASE WHEN file_size != ? OR modification_date IS NOT ? THEN 'pending' ELSE metadata_status END,
                thumbnail_status = CASE WHEN file_size != ? OR modification_date IS NOT ? THEN 'pending' ELSE thumbnail_status END,
                media_source_info = CASE
                    WHEN file_size != ? OR modification_date IS NOT ? THEN NULL
                    ELSE media_source_info
                END,
                content_fingerprint = CASE
                    WHEN ? IS NOT NULL THEN ?
                    WHEN file_size != ? OR modification_date IS NOT ? THEN NULL
                    ELSE content_fingerprint
                END,
                file_size = ?, creation_date = ?, modification_date = ?,
                availability_status = 'available', invalidated_at = NULL, updated_at = ?
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(video.relativePath, to: 1, in: statement)
        bindData(video.volumeIdentifier, to: 2, in: statement)
        bindData(video.fileResourceIdentifier, to: 3, in: statement)
        bindText(video.filename, to: 4, in: statement)
        bindText(video.fileExtension, to: 5, in: statement)
        var index: Int32 = 6
        for _ in 0..<7 {
            sqlite3_bind_int64(statement, index, video.fileSize)
            bindDate(video.modificationDate, to: index + 1, in: statement)
            index += 2
        }
        bindData(video.contentFingerprint, to: index, in: statement)
        bindData(video.contentFingerprint, to: index + 1, in: statement)
        sqlite3_bind_int64(statement, index + 2, video.fileSize)
        bindDate(video.modificationDate, to: index + 3, in: statement)
        index += 4
        sqlite3_bind_int64(statement, index, video.fileSize)
        bindDate(video.creationDate, to: index + 1, in: statement)
        bindDate(video.modificationDate, to: index + 2, in: statement)
        sqlite3_bind_double(statement, index + 3, updatedAt.timeIntervalSince1970)
        bindText(videoID, to: index + 4, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.statementFailed
        }
    }

    private func mediaContentChanged(videoID: String, comparedWith video: DiscoveredVideo) throws -> Bool {
        let statement = try prepare(
            "SELECT file_size, modification_date FROM videos WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        bindText(videoID, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        let storedFileSize = sqlite3_column_int64(statement, 0)
        let storedModificationDate = date(at: 1, in: statement)
        return storedFileSize != video.fileSize || storedModificationDate != video.modificationDate
    }

    private func upsertLocation(
        videoID: String,
        sourceID: String,
        video: DiscoveredVideo,
        verifiedAt: Date
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO video_locations (
                video_id, source_id, relative_path, fallback_path_key, last_known_path,
                last_verified_at, is_available
            )
            VALUES (?, ?, ?, ?, ?, ?, 1)
            ON CONFLICT(source_id, relative_path) DO UPDATE SET
                video_id = excluded.video_id,
                fallback_path_key = excluded.fallback_path_key,
                last_known_path = COALESCE(excluded.last_known_path, video_locations.last_known_path),
                last_verified_at = excluded.last_verified_at,
                is_available = 1
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(videoID, to: 1, in: statement)
        bindText(sourceID, to: 2, in: statement)
        bindText(video.relativePath, to: 3, in: statement)
        bindData(video.fallbackPathKey, to: 4, in: statement)
        bindOptionalText(video.lastKnownPath, to: 5, in: statement)
        sqlite3_bind_double(statement, 6, verifiedAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.statementFailed
        }
    }

    private func removeOtherLocations(videoID: String, sourceID: String, keepingPath: String) throws {
        let statement = try prepare(
            "DELETE FROM video_locations WHERE video_id = ? AND source_id = ? AND relative_path != ? AND requires_recovery_verification = 0"
        )
        defer { sqlite3_finalize(statement) }
        bindText(videoID, to: 1, in: statement)
        bindText(sourceID, to: 2, in: statement)
        bindText(keepingPath, to: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.statementFailed
        }
    }

    private func sourceLocationRows(sourceID: String) throws -> [VideoLocationRecord] {
        let statement = try prepare(
            """
            SELECT video_id, source_id, relative_path, fallback_path_key, last_known_path
            FROM video_locations WHERE source_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(sourceID, to: 1, in: statement)
        var rows: [VideoLocationRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let videoID = text(at: 0, in: statement),
                  let storedSourceID = text(at: 1, in: statement),
                  let relativePath = text(at: 2, in: statement) else {
                throw DatabaseError.statementFailed
            }
            rows.append(VideoLocationRecord(
                videoID: videoID,
                sourceID: storedSourceID,
                relativePath: relativePath,
                fallbackPathKey: data(at: 3, in: statement),
                lastKnownPath: text(at: 4, in: statement)
            ))
        }
        return rows
    }

    private func importFinderTags(videoID: String, finderTags: [String], importedAt: Date) throws {
        guard finderTags.isEmpty == false else { return }
        for rawName in Set(finderTags) {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false else { continue }
            let tagID = try finderTagID(
                libraryID: LibraryRecord.primaryID,
                externalKey: normalizedTagName(name),
                displayName: name,
                importedAt: importedAt
            )
            let relation = try prepare(
                "INSERT OR IGNORE INTO video_tags (video_id, tag_id, created_at) VALUES (?, ?, ?)"
            )
            bindText(videoID, to: 1, in: relation)
            bindText(tagID, to: 2, in: relation)
            sqlite3_bind_double(relation, 3, importedAt.timeIntervalSince1970)
            guard sqlite3_step(relation) == SQLITE_DONE else {
                sqlite3_finalize(relation)
                throw DatabaseError.statementFailed
            }
            sqlite3_finalize(relation)
        }
    }

    private func importFolderTags(
        videoID: String,
        relativePath: String,
        options: FolderTagImportOptions,
        importedAt: Date,
        cache: inout [FolderTagLookupKey: String]
    ) throws -> Set<String> {
        var pathComponents = NSString(string: relativePath).pathComponents
        if pathComponents.isEmpty == false {
            pathComponents.removeLast()
        }
        if let selectedRootName = options.selectedRootName {
            pathComponents.insert(selectedRootName, at: 0)
        }
        let tagNames = pathComponents.compactMap { component -> String? in
            let name = component.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        guard tagNames.isEmpty == false else { return [] }

        var parentID: String?
        var createdTagIDs = Set<String>()
        for name in tagNames {
            let key = FolderTagLookupKey(
                parentID: parentID,
                normalizedName: normalizedTagName(name)
            )
            let tagID: String
            if let cachedID = cache[key] {
                tagID = cachedID
            } else if let existingID = try folderTagID(
                libraryID: LibraryRecord.primaryID,
                parentID: parentID,
                normalizedName: key.normalizedName
            ) {
                tagID = existingID
                cache[key] = existingID
            } else {
                tagID = try createTag(
                    libraryID: LibraryRecord.primaryID,
                    name: name,
                    parentID: parentID
                )
                cache[key] = tagID
                createdTagIDs.insert(tagID)
            }
            parentID = tagID
        }

        guard let leafTagID = parentID else { return createdTagIDs }
        let relation = try prepare(
            "INSERT OR IGNORE INTO video_tags (video_id, tag_id, created_at) VALUES (?, ?, ?)"
        )
        defer { sqlite3_finalize(relation) }
        bindText(videoID, to: 1, in: relation)
        bindText(leafTagID, to: 2, in: relation)
        sqlite3_bind_double(relation, 3, importedAt.timeIntervalSince1970)
        guard sqlite3_step(relation) == SQLITE_DONE else {
            throw DatabaseError.statementFailed
        }
        return createdTagIDs
    }

    private func folderTagID(
        libraryID: String,
        parentID: String?,
        normalizedName: String
    ) throws -> String? {
        let statement = try prepare(
            """
            SELECT id FROM tags
            WHERE library_id = ? AND parent_id IS ? AND normalized_name = ?
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(libraryID, to: 1, in: statement)
        bindOptionalText(parentID, to: 2, in: statement)
        bindText(normalizedName, to: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(at: 0, in: statement)
    }

    func fetchVideos(libraryID: String, includeMissing: Bool = false) throws -> [VideoRecord] {
        try prepareIfNeeded()
        let availabilityClause = includeMissing ? "" : "AND availability_status = 'available'"
        let statement = try prepare(
            """
            SELECT id, library_id, relative_path, filename, file_extension, file_size,
                   creation_date, modification_date, duration, width, height, thumbnail_id,
                   metadata_status, thumbnail_status, first_indexed_at, availability_status,
                   media_source_info, invalidated_at, content_fingerprint
            FROM videos
            WHERE library_id = ? \(availabilityClause)
            ORDER BY filename COLLATE NOCASE, relative_path COLLATE NOCASE
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(libraryID, to: 1, in: statement)

        var records: [VideoRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            records.append(try videoRecord(from: statement))
        }
        return records
    }

    func fetchVideos(
        libraryID: String,
        query: LibraryQueryRequest,
        now: Date = Date()
    ) throws -> [VideoRecord] {
        try prepareIfNeeded()
        let rule = query.rule.normalized()
        var conditions = ["videos.library_id = ?"]
        var bindings: [LibraryQueryBinding] = [.text(libraryID)]

        conditions.append(
            query.baseFilter == .unavailable
                ? "videos.availability_status IN ('available', 'missing')"
                : "videos.availability_status = 'available'"
        )
        switch query.baseFilter {
        case .all, .unavailable:
            break
        case .untagged:
            conditions.append(
                "NOT EXISTS (SELECT 1 FROM video_tags WHERE video_tags.video_id = videos.id)"
            )
        case .recent:
            conditions.append("videos.first_indexed_at >= ?")
            bindings.append(.double(now.addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970))
        case let .tag(tagID):
            conditions.append(tagMatchPredicate(tagID: tagID, bindings: &bindings))
        case let .tags(tagIDs):
            conditions.append(contentsOf: tagIDs.map {
                tagMatchPredicate(tagID: $0, bindings: &bindings)
            })
        }

        let temporarySearch = query.temporaryFilenameSearch
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if temporarySearch.isEmpty == false {
            conditions.append("instr(lower(videos.filename), lower(?)) > 0")
            bindings.append(.text(temporarySearch))
        }
        for filenameRule in rule.filenameContains {
            conditions.append("instr(lower(videos.filename), lower(?)) > 0")
            bindings.append(.text(filenameRule))
        }

        conditions.append(contentsOf: rule.requiredTagIDs.map {
            tagMatchPredicate(tagID: $0, bindings: &bindings)
        })

        let referencedTagIDs = Array(Set(rule.referencedTagIDs)).sorted()
        conditions.append(contentsOf: referencedTagIDs.map { tagID in
            bindings.append(.text(tagID))
            return "EXISTS (SELECT 1 FROM tags WHERE tags.id = ? AND tags.library_id = videos.library_id)"
        })

        conditions.append(contentsOf: rule.requiredConditions.map {
            filterConditionPredicate($0, now: now, bindings: &bindings)
        })

        if rule.conditions.isEmpty == false {
            let conditionSQL = rule.conditions.map {
                filterConditionPredicate($0, now: now, bindings: &bindings)
            }
            let separator = rule.matchMode == .all ? " AND " : " OR "
            conditions.append("(\(conditionSQL.joined(separator: separator)))")
        }

        let effectiveSort = query.baseFilter.presetSort ?? rule.sort
        let sortColumn: String
        switch effectiveSort.key {
        case .filename: sortColumn = "videos.filename COLLATE NOCASE"
        case .added: sortColumn = "videos.first_indexed_at"
        case .created: sortColumn = "videos.creation_date"
        case .modified: sortColumn = "videos.modification_date"
        case .duration: sortColumn = "videos.duration"
        case .fileSize: sortColumn = "videos.file_size"
        case .resolution: sortColumn = "videos.width"
        }
        let sortDirection = effectiveSort.direction == .ascending ? "ASC" : "DESC"
        let nullOrdering = effectiveSort.key == .filename ? "" : "\(sortColumn) IS NULL, "
        let availabilityOrdering = query.baseFilter == .unavailable
            ? "CASE videos.availability_status WHEN 'missing' THEN 0 ELSE 1 END, "
            : ""
        let statement = try prepare(
            """
            SELECT videos.id, videos.library_id, videos.relative_path, videos.filename,
                   videos.file_extension, videos.file_size, videos.creation_date,
                   videos.modification_date, videos.duration, videos.width, videos.height,
                   videos.thumbnail_id, videos.metadata_status, videos.thumbnail_status,
                   videos.first_indexed_at, videos.availability_status,
                   videos.media_source_info, videos.invalidated_at, videos.content_fingerprint
            FROM videos
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY \(availabilityOrdering)\(nullOrdering)\(sortColumn) \(sortDirection),
                     videos.filename COLLATE NOCASE,
                     videos.relative_path COLLATE NOCASE
            """
        )
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case let .text(value):
                bindText(value, to: index, in: statement)
            case let .integer(value):
                sqlite3_bind_int64(statement, index, value)
            case let .double(value):
                sqlite3_bind_double(statement, index, value)
            }
        }

        var records: [VideoRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            records.append(try videoRecord(from: statement))
        }
        return records
    }

    private func tagMatchPredicate(
        tagID: String,
        bindings: inout [LibraryQueryBinding]
    ) -> String {
        bindings.append(.text(tagID))
        return """
        EXISTS (
            WITH RECURSIVE descendants(id) AS (
                SELECT ?
                UNION ALL
                SELECT tags.id
                FROM tags JOIN descendants ON tags.parent_id = descendants.id
            )
            SELECT 1
            FROM video_tags
            JOIN descendants ON descendants.id = video_tags.tag_id
            WHERE video_tags.video_id = videos.id
            LIMIT 1
        )
        """
    }

    private func filterConditionPredicate(
        _ condition: LibraryFilterCondition,
        now: Date,
        bindings: inout [LibraryQueryBinding]
    ) -> String {
        switch condition {
        case let .tags(tagOperator, tagIDs):
            guard tagIDs.isEmpty == false else {
                return tagOperator == .any ? "0" : "1"
            }
            let matches = tagIDs.map { tagMatchPredicate(tagID: $0, bindings: &bindings) }
            switch tagOperator {
            case .all:
                return "(\(matches.joined(separator: " AND ")))"
            case .any:
                return "(\(matches.joined(separator: " OR ")))"
            case .exclude:
                return "NOT (\(matches.joined(separator: " OR ")))"
            }
        case .untagged:
            return "NOT EXISTS (SELECT 1 FROM video_tags WHERE video_tags.video_id = videos.id)"
        case let .addedWithinDays(days):
            bindings.append(.double(
                now.addingTimeInterval(-Double(max(1, days)) * 24 * 60 * 60).timeIntervalSince1970
            ))
            return "videos.first_indexed_at >= ?"
        case let .createdWithinDays(days):
            bindings.append(.double(
                now.addingTimeInterval(-Double(max(1, days)) * 24 * 60 * 60).timeIntervalSince1970
            ))
            return "videos.creation_date >= ?"
        case let .durationAtLeast(seconds):
            bindings.append(.double(max(0, seconds)))
            return "videos.duration >= ?"
        case let .fileSizeAtLeast(bytes):
            bindings.append(.integer(max(0, bytes)))
            return "videos.file_size >= ?"
        case let .resolutionWidthAtLeast(width):
            bindings.append(.integer(Int64(max(0, width))))
            return "videos.width >= ?"
        }
    }

    func fetchSidebarFilterCounts(
        libraryID: String,
        now: Date = Date()
    ) throws -> SidebarFilterCounts {
        try prepareIfNeeded()
        let statement = try prepare(
            """
            SELECT COUNT(*),
                   COALESCE(SUM(NOT EXISTS (
                       SELECT 1 FROM video_tags WHERE video_tags.video_id = videos.id
                   )), 0),
                   COALESCE(SUM(videos.first_indexed_at >= ?), 0),
                   (SELECT COUNT(*) FROM videos AS missing_videos
                    WHERE missing_videos.library_id = ?
                      AND missing_videos.availability_status = 'missing')
            FROM videos
            WHERE videos.library_id = ?
              AND videos.availability_status = 'available'
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(
            statement,
            1,
            now.addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970
        )
        bindText(libraryID, to: 2, in: statement)
        bindText(libraryID, to: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.statementFailed
        }
        return SidebarFilterCounts(
            all: Int(sqlite3_column_int(statement, 0)),
            untagged: Int(sqlite3_column_int(statement, 1)),
            recent: Int(sqlite3_column_int(statement, 2)),
            unavailable: Int(sqlite3_column_int(statement, 3))
        )
    }

    func fetchMissingVideoIDs(libraryID: String) throws -> Set<String> {
        try prepareIfNeeded()
        let statement = try prepare(
            "SELECT id FROM videos WHERE library_id = ? AND availability_status = 'missing'"
        )
        defer { sqlite3_finalize(statement) }
        bindText(libraryID, to: 1, in: statement)
        var ids = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = text(at: 0, in: statement) { ids.insert(id) }
        }
        return ids
    }

    func fetchVideo(id: String) throws -> VideoRecord? {
        try prepareIfNeeded()
        let statement = try prepare(
            """
            SELECT id, library_id, relative_path, filename, file_extension, file_size,
                   creation_date, modification_date, duration, width, height, thumbnail_id,
                   metadata_status, thumbnail_status, first_indexed_at, availability_status,
                   media_source_info, invalidated_at, content_fingerprint
            FROM videos WHERE id = ? LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(id, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try videoRecord(from: statement)
    }

    // A path match can identify an existing record without authorizing a write to it.
    private func permitsAutomaticUpdate(videoID: String, pathKey: Data?) throws -> Bool {
        let statement = try prepare("""
            SELECT NOT EXISTS (SELECT 1 FROM video_locations WHERE video_id = ? AND requires_recovery_verification = 1)
                OR EXISTS (SELECT 1 FROM video_locations WHERE video_id = ? AND requires_recovery_verification = 0
                    AND is_available = 1 AND fallback_path_key = ?)
            """)
        defer { sqlite3_finalize(statement) }
        bindText(videoID, to: 1, in: statement)
        bindText(videoID, to: 2, in: statement)
        bindData(pathKey, to: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw DatabaseError.statementFailed }
        return sqlite3_column_int(statement, 0) != 0
    }

    func confirmRecoveryPathMissing(videoID: String, path: String) throws {
        try prepareIfNeeded()
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("""
                UPDATE video_locations SET requires_recovery_verification = 0, is_available = 0
                WHERE video_id = ? AND last_known_path = ? AND requires_recovery_verification = 1
                """)
            defer { sqlite3_finalize(statement) }
            bindText(videoID, to: 1, in: statement)
            bindText(path, to: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.statementFailed }
            let mark = try prepare("""
                UPDATE videos SET availability_status = 'missing', invalidated_at = COALESCE(invalidated_at, ?)
                WHERE id = ? AND NOT EXISTS (SELECT 1 FROM video_locations WHERE video_id = ?
                    AND (is_available = 1 OR requires_recovery_verification = 1))
                """)
            defer { sqlite3_finalize(mark) }
            sqlite3_bind_double(mark, 1, Date().timeIntervalSince1970)
            bindText(videoID, to: 2, in: mark)
            bindText(videoID, to: 3, in: mark)
            guard sqlite3_step(mark) == SQLITE_DONE else { throw DatabaseError.statementFailed }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }


    func protectLostLocations(_ locations: [VideoLocationRecord]) throws {
        guard !locations.isEmpty else { return }
        try prepareIfNeeded()
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("""
                UPDATE video_locations SET requires_recovery_verification = 1
                WHERE video_id = ? AND source_id = ? AND relative_path = ? AND is_available = 1
                """)
            defer { sqlite3_finalize(statement) }
            for location in locations {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bindText(location.videoID, to: 1, in: statement)
                bindText(location.sourceID, to: 2, in: statement)
                bindText(location.relativePath, to: 3, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.statementFailed }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func protectRecoveryLocations(videoIDs: [String]) throws {
        try prepareIfNeeded()
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("UPDATE video_locations SET requires_recovery_verification = 1 WHERE video_id = ?")
            defer { sqlite3_finalize(statement) }
            for id in videoIDs {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bindText(id, to: 1, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.statementFailed }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func relinkVideo(
        id videoID: String,
        sourceID: String,
        discoveredVideo: DiscoveredVideo,
        allowAvailableRecord: Bool = false,
        allowContentMismatch: Bool = false,
        sourceAuthorization: SourceAuthorizationRecord? = nil,
        verifiedAt: Date = Date()
    ) throws -> VideoRecord {
        try prepareIfNeeded()
        try execute("BEGIN IMMEDIATE")
        do {
            let assessment = try relinkAssessment(
                id: videoID,
                sourceID: sourceID,
                discoveredVideo: discoveredVideo,
                allowAvailableRecord: allowAvailableRecord
            )
            switch assessment {
            case .exactMatch:
                break
            case .needsConfirmation where allowContentMismatch:
                break
            case .needsConfirmation:
                throw DatabaseError.relinkConfirmationRequired
            case let .existingRecord(existingVideoID):
                throw DatabaseError.relinkExistingRecord(videoID: existingVideoID)
            }
            if let sourceAuthorization { try saveSourceAuthorization(sourceAuthorization) }
            try updateRelinkedVideo(
                videoID: videoID,
                from: discoveredVideo,
                refreshMedia: assessment == .needsConfirmation,
                updatedAt: verifiedAt
            )
            try upsertLocation(
                videoID: videoID,
                sourceID: sourceID,
                video: discoveredVideo,
                verifiedAt: verifiedAt
            )
            let clear = try prepare("UPDATE video_locations SET requires_recovery_verification = 0 WHERE video_id = ? AND source_id = ? AND relative_path = ?")
            defer { sqlite3_finalize(clear) }
            bindText(videoID, to: 1, in: clear)
            bindText(sourceID, to: 2, in: clear)
            bindText(discoveredVideo.relativePath, to: 3, in: clear)
            guard sqlite3_step(clear) == SQLITE_DONE else { throw DatabaseError.statementFailed }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        guard let restored = try fetchVideo(id: videoID) else {
            throw DatabaseError.statementFailed
        }
        return restored
    }

    func assessRelinkVideo(
        id videoID: String,
        sourceID: String,
        discoveredVideo: DiscoveredVideo,
        allowAvailableRecord: Bool = false
    ) throws -> VideoRelinkAssessment {
        try prepareIfNeeded()
        return try relinkAssessment(
            id: videoID,
            sourceID: sourceID,
            discoveredVideo: discoveredVideo,
            allowAvailableRecord: allowAvailableRecord
        )
    }

    func existingRelinkVideoID(
        id videoID: String,
        sourceID: String,
        discoveredVideo: DiscoveredVideo,
        allowAvailableRecord: Bool = false
    ) throws -> String? {
        try prepareIfNeeded()
        guard let selected = try fetchVideo(id: videoID),
              selected.availability == .unavailable
                || (allowAvailableRecord && selected.availability == .available) else {
            throw DatabaseError.statementFailed
        }
        guard let matchedVideoID = try existingVideoID(
            for: discoveredVideo,
            sourceID: sourceID
        ), matchedVideoID != videoID else {
            return nil
        }
        return matchedVideoID
    }

    private func relinkAssessment(
        id videoID: String,
        sourceID: String,
        discoveredVideo: DiscoveredVideo,
        allowAvailableRecord: Bool
    ) throws -> VideoRelinkAssessment {
        guard let selected = try fetchVideo(id: videoID),
              selected.availability == .unavailable
                || (allowAvailableRecord && selected.availability == .available),
              let candidateFingerprint = discoveredVideo.contentFingerprint else {
            throw DatabaseError.statementFailed
        }
        if let matchedVideoID = try existingVideoID(for: discoveredVideo, sourceID: sourceID),
           matchedVideoID != videoID {
            return .existingRecord(videoID: matchedVideoID)
        }

        let fingerprintLookup = try prepare(
            """
            SELECT id FROM videos
            WHERE library_id = ? AND id != ? AND content_fingerprint = ?
            ORDER BY first_indexed_at
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(fingerprintLookup) }
        bindText(selected.libraryID, to: 1, in: fingerprintLookup)
        bindText(videoID, to: 2, in: fingerprintLookup)
        bindData(candidateFingerprint, to: 3, in: fingerprintLookup)
        if sqlite3_step(fingerprintLookup) == SQLITE_ROW,
           let existingVideoID = text(at: 0, in: fingerprintLookup) {
            return .existingRecord(videoID: existingVideoID)
        }
        guard let originalFingerprint = selected.contentFingerprint else {
            return .needsConfirmation
        }
        return originalFingerprint == candidateFingerprint ? .exactMatch : .needsConfirmation
    }

    private func updateRelinkedVideo(
        videoID: String,
        from video: DiscoveredVideo,
        refreshMedia: Bool,
        updatedAt: Date
    ) throws {
        let statement = try prepare(
            """
            UPDATE videos SET
                relative_path = ?, volume_identifier = ?, file_resource_identifier = ?,
                filename = ?, file_extension = ?, file_size = ?,
                creation_date = ?, modification_date = ?, content_fingerprint = ?,
                duration = CASE WHEN ? THEN NULL ELSE duration END,
                width = CASE WHEN ? THEN NULL ELSE width END,
                height = CASE WHEN ? THEN NULL ELSE height END,
                thumbnail_id = CASE WHEN ? THEN NULL ELSE thumbnail_id END,
                metadata_status = CASE WHEN ? THEN 'pending' ELSE metadata_status END,
                thumbnail_status = CASE WHEN ? THEN 'pending' ELSE thumbnail_status END,
                media_source_info = CASE WHEN ? THEN NULL ELSE media_source_info END,
                availability_status = 'available', invalidated_at = NULL, updated_at = ?
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(video.relativePath, to: 1, in: statement)
        bindData(video.volumeIdentifier, to: 2, in: statement)
        bindData(video.fileResourceIdentifier, to: 3, in: statement)
        bindText(video.filename, to: 4, in: statement)
        bindText(video.fileExtension, to: 5, in: statement)
        sqlite3_bind_int64(statement, 6, video.fileSize)
        bindDate(video.creationDate, to: 7, in: statement)
        bindDate(video.modificationDate, to: 8, in: statement)
        bindData(video.contentFingerprint, to: 9, in: statement)
        for index in 10...16 {
            sqlite3_bind_int(statement, Int32(index), refreshMedia ? 1 : 0)
        }
        sqlite3_bind_double(statement, 17, updatedAt.timeIntervalSince1970)
        bindText(videoID, to: 18, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.statementFailed
        }
    }

    func removeVideos(ids: [String]) throws -> VideoRemovalSnapshot {
        try prepareIfNeeded()
        let uniqueIDs = Array(Set(ids))
        guard uniqueIDs.isEmpty == false else {
            return VideoRemovalSnapshot(videos: [], locations: [], tagRelations: [])
        }

        try execute("BEGIN IMMEDIATE")
        do {
            try execute("CREATE TEMP TABLE IF NOT EXISTS pending_video_removal_ids (id TEXT PRIMARY KEY)")
            try execute("DELETE FROM pending_video_removal_ids")
            let insertID = try prepare(
                "INSERT OR IGNORE INTO pending_video_removal_ids (id) VALUES (?)"
            )
            for id in uniqueIDs {
                sqlite3_reset(insertID)
                sqlite3_clear_bindings(insertID)
                bindText(id, to: 1, in: insertID)
                guard sqlite3_step(insertID) == SQLITE_DONE else {
                    sqlite3_finalize(insertID)
                    throw DatabaseError.statementFailed
                }
            }
            sqlite3_finalize(insertID)

            let videoStatement = try prepare(
                """
                SELECT id, library_id, relative_path, volume_identifier, file_resource_identifier,
                       filename, file_extension, file_size, creation_date, modification_date,
                       duration, width, height, thumbnail_id, metadata_status, thumbnail_status,
                       availability_status, first_indexed_at, updated_at, last_seen_scan_id,
                       finder_tags_imported_at, media_source_info, invalidated_at,
                       content_fingerprint
                FROM videos
                WHERE id IN (SELECT id FROM pending_video_removal_ids)
                ORDER BY first_indexed_at, id
                """
            )
            var videos: [RemovedVideoRecord] = []
            while sqlite3_step(videoStatement) == SQLITE_ROW {
                guard let id = text(at: 0, in: videoStatement),
                      let libraryID = text(at: 1, in: videoStatement),
                      let relativePath = text(at: 2, in: videoStatement),
                      let filename = text(at: 5, in: videoStatement),
                      let fileExtension = text(at: 6, in: videoStatement),
                      let metadataStatus = text(at: 14, in: videoStatement),
                      let thumbnailStatus = text(at: 15, in: videoStatement),
                      let availabilityStatus = text(at: 16, in: videoStatement) else {
                    sqlite3_finalize(videoStatement)
                    throw DatabaseError.statementFailed
                }
                videos.append(RemovedVideoRecord(
                    id: id,
                    libraryID: libraryID,
                    relativePath: relativePath,
                    volumeIdentifier: data(at: 3, in: videoStatement),
                    fileResourceIdentifier: data(at: 4, in: videoStatement),
                    contentFingerprint: data(at: 23, in: videoStatement),
                    filename: filename,
                    fileExtension: fileExtension,
                    fileSize: sqlite3_column_int64(videoStatement, 7),
                    creationDate: date(at: 8, in: videoStatement),
                    modificationDate: date(at: 9, in: videoStatement),
                    duration: sqlite3_column_type(videoStatement, 10) == SQLITE_NULL
                        ? nil : sqlite3_column_double(videoStatement, 10),
                    width: sqlite3_column_type(videoStatement, 11) == SQLITE_NULL
                        ? nil : Int(sqlite3_column_int(videoStatement, 11)),
                    height: sqlite3_column_type(videoStatement, 12) == SQLITE_NULL
                        ? nil : Int(sqlite3_column_int(videoStatement, 12)),
                    thumbnailID: text(at: 13, in: videoStatement),
                    metadataStatus: metadataStatus,
                    thumbnailStatus: thumbnailStatus,
                    availabilityStatus: availabilityStatus,
                    firstIndexedAt: Date(timeIntervalSince1970: sqlite3_column_double(videoStatement, 17)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(videoStatement, 18)),
                    lastSeenScanID: text(at: 19, in: videoStatement),
                    finderTagsImportedAt: date(at: 20, in: videoStatement),
                    mediaSourceInfo: decodedMediaSourceInfo(text(at: 21, in: videoStatement)),
                    invalidatedAt: date(at: 22, in: videoStatement)
                ))
            }
            sqlite3_finalize(videoStatement)

            let locationStatement = try prepare(
                """
                SELECT video_id, source_id, relative_path, last_verified_at, is_available,
                       fallback_path_key, last_known_path, requires_recovery_verification
                FROM video_locations
                WHERE video_id IN (SELECT id FROM pending_video_removal_ids)
                ORDER BY video_id, source_id, relative_path
                """
            )
            var locations: [RemovedVideoLocation] = []
            while sqlite3_step(locationStatement) == SQLITE_ROW {
                guard let videoID = text(at: 0, in: locationStatement),
                      let sourceID = text(at: 1, in: locationStatement),
                      let relativePath = text(at: 2, in: locationStatement) else {
                    sqlite3_finalize(locationStatement)
                    throw DatabaseError.statementFailed
                }
                locations.append(RemovedVideoLocation(
                    videoID: videoID,
                    sourceID: sourceID,
                    relativePath: relativePath,
                    lastVerifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(locationStatement, 3)),
                    isAvailable: sqlite3_column_int(locationStatement, 4) != 0,
                    fallbackPathKey: data(at: 5, in: locationStatement),
                    lastKnownPath: text(at: 6, in: locationStatement),
                    requiresRecoveryVerification: sqlite3_column_int(locationStatement, 7) != 0
                ))
            }
            sqlite3_finalize(locationStatement)

            let tagStatement = try prepare(
                """
                SELECT video_id, tag_id, created_at
                FROM video_tags
                WHERE video_id IN (SELECT id FROM pending_video_removal_ids)
                ORDER BY video_id, tag_id
                """
            )
            var tagRelations: [RemovedVideoTagRelation] = []
            while sqlite3_step(tagStatement) == SQLITE_ROW {
                guard let videoID = text(at: 0, in: tagStatement),
                      let tagID = text(at: 1, in: tagStatement) else {
                    sqlite3_finalize(tagStatement)
                    throw DatabaseError.statementFailed
                }
                tagRelations.append(RemovedVideoTagRelation(
                    videoID: videoID,
                    tagID: tagID,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(tagStatement, 2))
                ))
            }
            sqlite3_finalize(tagStatement)

            let deleteStatement = try prepare(
                "DELETE FROM videos WHERE id IN (SELECT id FROM pending_video_removal_ids)"
            )
            guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
                sqlite3_finalize(deleteStatement)
                throw DatabaseError.statementFailed
            }
            sqlite3_finalize(deleteStatement)
            try execute("DELETE FROM pending_video_removal_ids")
            try execute("COMMIT")
            return VideoRemovalSnapshot(videos: videos, locations: locations, tagRelations: tagRelations)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func restoreVideos(_ snapshot: VideoRemovalSnapshot) throws -> [String] {
        try prepareIfNeeded()
        guard snapshot.videos.isEmpty == false else { return [] }
        try execute("BEGIN IMMEDIATE")
        do {
            let videoStatement = try prepare(
                """
                INSERT INTO videos (
                    id, library_id, relative_path, volume_identifier, file_resource_identifier,
                    filename, file_extension, file_size, creation_date, modification_date,
                    duration, width, height, thumbnail_id, metadata_status, thumbnail_status,
                    availability_status, first_indexed_at, updated_at, last_seen_scan_id,
                    finder_tags_imported_at, media_source_info, invalidated_at,
                    content_fingerprint
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            )
            var restoredVideoIDs: [String: String] = [:]
            for video in snapshot.videos {
                let locations = snapshot.locations.filter { $0.videoID == video.id }
                if let existingVideoID = try existingVideoID(for: video, locations: locations) {
                    restoredVideoIDs[video.id] = existingVideoID
                    continue
                }
                sqlite3_reset(videoStatement)
                sqlite3_clear_bindings(videoStatement)
                bindText(video.id, to: 1, in: videoStatement)
                bindText(video.libraryID, to: 2, in: videoStatement)
                bindText(video.relativePath, to: 3, in: videoStatement)
                bindData(video.volumeIdentifier, to: 4, in: videoStatement)
                bindData(video.fileResourceIdentifier, to: 5, in: videoStatement)
                bindText(video.filename, to: 6, in: videoStatement)
                bindText(video.fileExtension, to: 7, in: videoStatement)
                sqlite3_bind_int64(videoStatement, 8, video.fileSize)
                bindDate(video.creationDate, to: 9, in: videoStatement)
                bindDate(video.modificationDate, to: 10, in: videoStatement)
                bindDouble(video.duration, to: 11, in: videoStatement)
                bindInt(video.width, to: 12, in: videoStatement)
                bindInt(video.height, to: 13, in: videoStatement)
                bindOptionalText(video.thumbnailID, to: 14, in: videoStatement)
                bindText(video.metadataStatus, to: 15, in: videoStatement)
                bindText(video.thumbnailStatus, to: 16, in: videoStatement)
                bindText(video.availabilityStatus, to: 17, in: videoStatement)
                sqlite3_bind_double(videoStatement, 18, video.firstIndexedAt.timeIntervalSince1970)
                sqlite3_bind_double(videoStatement, 19, video.updatedAt.timeIntervalSince1970)
                bindOptionalText(video.lastSeenScanID, to: 20, in: videoStatement)
                bindDate(video.finderTagsImportedAt, to: 21, in: videoStatement)
                bindOptionalText(try encodedMediaSourceInfo(video.mediaSourceInfo), to: 22, in: videoStatement)
                bindDate(video.invalidatedAt, to: 23, in: videoStatement)
                bindData(video.contentFingerprint, to: 24, in: videoStatement)
                guard sqlite3_step(videoStatement) == SQLITE_DONE else {
                    sqlite3_finalize(videoStatement)
                    throw DatabaseError.statementFailed
                }
                restoredVideoIDs[video.id] = video.id
            }
            sqlite3_finalize(videoStatement)

            let locationStatement = try prepare(
                """
                INSERT OR IGNORE INTO video_locations (
                    video_id, source_id, relative_path, last_verified_at, is_available,
                    fallback_path_key, last_known_path, requires_recovery_verification
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """
            )
            for location in snapshot.locations {
                guard let restoredVideoID = restoredVideoIDs[location.videoID] else { continue }
                sqlite3_reset(locationStatement)
                sqlite3_clear_bindings(locationStatement)
                bindText(restoredVideoID, to: 1, in: locationStatement)
                bindText(location.sourceID, to: 2, in: locationStatement)
                bindText(location.relativePath, to: 3, in: locationStatement)
                sqlite3_bind_double(locationStatement, 4, location.lastVerifiedAt.timeIntervalSince1970)
                sqlite3_bind_int(locationStatement, 5, location.isAvailable ? 1 : 0)
                bindData(location.fallbackPathKey, to: 6, in: locationStatement)
                bindOptionalText(location.lastKnownPath, to: 7, in: locationStatement)
                sqlite3_bind_int(locationStatement, 8, location.requiresRecoveryVerification ? 1 : 0)
                guard sqlite3_step(locationStatement) == SQLITE_DONE else {
                    sqlite3_finalize(locationStatement)
                    throw DatabaseError.statementFailed
                }
            }
            sqlite3_finalize(locationStatement)

            let tagStatement = try prepare(
                "INSERT OR IGNORE INTO video_tags (video_id, tag_id, created_at) VALUES (?, ?, ?)"
            )
            for relation in snapshot.tagRelations {
                guard let restoredVideoID = restoredVideoIDs[relation.videoID] else { continue }
                sqlite3_reset(tagStatement)
                sqlite3_clear_bindings(tagStatement)
                bindText(restoredVideoID, to: 1, in: tagStatement)
                bindText(relation.tagID, to: 2, in: tagStatement)
                sqlite3_bind_double(tagStatement, 3, relation.createdAt.timeIntervalSince1970)
                guard sqlite3_step(tagStatement) == SQLITE_DONE else {
                    sqlite3_finalize(tagStatement)
                    throw DatabaseError.statementFailed
                }
            }
            sqlite3_finalize(tagStatement)
            try execute("COMMIT")
            return snapshot.videos.compactMap { restoredVideoIDs[$0.id] }
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func existingVideoID(
        for removedVideo: RemovedVideoRecord,
        locations: [RemovedVideoLocation]
    ) throws -> String? {
        if let volumeIdentifier = removedVideo.volumeIdentifier,
           let fileResourceIdentifier = removedVideo.fileResourceIdentifier {
            let statement = try prepare(
                """
                SELECT id FROM videos
                WHERE library_id = ? AND volume_identifier = ? AND file_resource_identifier = ?
                ORDER BY first_indexed_at
                LIMIT 1
                """
            )
            bindText(removedVideo.libraryID, to: 1, in: statement)
            bindData(volumeIdentifier, to: 2, in: statement)
            bindData(fileResourceIdentifier, to: 3, in: statement)
            let videoID = sqlite3_step(statement) == SQLITE_ROW ? text(at: 0, in: statement) : nil
            sqlite3_finalize(statement)
            if let videoID { return videoID }
            return nil
        }

        for location in locations {
            let statement: OpaquePointer
            if let fallbackPathKey = location.fallbackPathKey {
                statement = try prepare(
                    "SELECT video_id FROM video_locations WHERE fallback_path_key = ? LIMIT 1"
                )
                bindData(fallbackPathKey, to: 1, in: statement)
            } else {
                statement = try prepare(
                    "SELECT video_id FROM video_locations WHERE source_id = ? AND relative_path = ? LIMIT 1"
                )
                bindText(location.sourceID, to: 1, in: statement)
                bindText(location.relativePath, to: 2, in: statement)
            }
            let videoID = sqlite3_step(statement) == SQLITE_ROW ? text(at: 0, in: statement) : nil
            sqlite3_finalize(statement)
            if let videoID { return videoID }
        }
        return nil
    }

    struct MediaProcessingSnapshot: Equatable, Sendable {
        let video: VideoRecord
        let volumeIdentifier: Data?
        let fileResourceIdentifier: Data?
        let pathKey: Data
        let locations: [VideoLocationRecord]
    }

    func mediaProcessingSnapshot(videoID: String, pathKey: Data) throws -> MediaProcessingSnapshot? {
        try prepareIfNeeded()
        guard try permitsAutomaticUpdate(videoID: videoID, pathKey: pathKey),
              let video = try fetchVideo(id: videoID), video.availability == .available else { return nil }
        let statement = try prepare("SELECT volume_identifier, file_resource_identifier FROM videos WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bindText(videoID, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        // Playback lookup orders locations by observation time, which is not a media revision.
        let locations = try fetchVideoLocations(videoID: videoID).sorted {
            ($0.sourceID, $0.relativePath) < ($1.sourceID, $1.relativePath)
        }
        guard locations.contains(where: { $0.fallbackPathKey == pathKey && !$0.requiresRecoveryVerification }) else { return nil }
        // Source scans update observational timestamps even if the media and authorization are unchanged.
        return MediaProcessingSnapshot(video: video, volumeIdentifier: data(at: 0, in: statement),
            fileResourceIdentifier: data(at: 1, in: statement), pathKey: pathKey, locations: locations)
    }

    func commitMediaProcessing(_ result: MediaProcessingResult, expected: MediaProcessingSnapshot) throws -> VideoRecord? {
        try prepareIfNeeded()
        try execute("BEGIN IMMEDIATE")
        do {
            // Compare and write atomically; stale work cannot overwrite a later mutation.
            guard try mediaProcessingSnapshot(videoID: expected.video.id, pathKey: expected.pathKey) == expected else {
                try execute("COMMIT")
                return nil
            }
            let updated = try updateMediaInfo(videoID: expected.video.id, result: result, pathKey: expected.pathKey)
            try execute("COMMIT")
            return updated
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func isThumbnailReferenced(_ id: String) throws -> Bool {
        try prepareIfNeeded()
        let statement = try prepare("SELECT 1 FROM videos WHERE thumbnail_id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bindText(id, to: 1, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func updateMediaInfo(videoID: String, result: MediaProcessingResult, pathKey: Data? = nil) throws -> VideoRecord? {
        try prepareIfNeeded()
        guard try permitsAutomaticUpdate(videoID: videoID, pathKey: pathKey) else { return nil }
        let statement = try prepare(
            """
            UPDATE videos SET duration = ?, width = ?, height = ?, thumbnail_id = ?,
                metadata_status = ?, thumbnail_status = ?, media_source_info = ?,
                content_fingerprint = COALESCE(?, content_fingerprint), updated_at = ?
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        bindDouble(result.duration, to: 1, in: statement)
        bindInt(result.width, to: 2, in: statement)
        bindInt(result.height, to: 3, in: statement)
        bindOptionalText(result.thumbnailID, to: 4, in: statement)
        bindText(result.metadataStatus.rawValue, to: 5, in: statement)
        bindText(result.thumbnailStatus.rawValue, to: 6, in: statement)
        bindOptionalText(try encodedMediaSourceInfo(result.mediaSourceInfo), to: 7, in: statement)
        bindData(result.contentFingerprint, to: 8, in: statement)
        sqlite3_bind_double(statement, 9, Date().timeIntervalSince1970)
        bindText(videoID, to: 10, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.statementFailed
        }
        return try fetchVideo(id: videoID)
    }

    func fetchTags(libraryID: String) throws -> [TagRecord] {
        try prepareIfNeeded()
        let statement = try prepare(
            """
            WITH RECURSIVE descendants(root_id, id) AS (
                SELECT id, id FROM tags WHERE library_id = ?
                UNION ALL
                SELECT descendants.root_id, tags.id
                FROM tags JOIN descendants ON tags.parent_id = descendants.id
            )
            SELECT tags.id, tags.library_id, tags.name, tags.parent_id, tags.color,
                   tags.sort_order, tags.source, COUNT(DISTINCT videos.id)
            FROM tags
            LEFT JOIN descendants ON descendants.root_id = tags.id
            LEFT JOIN video_tags ON video_tags.tag_id = descendants.id
            LEFT JOIN videos ON videos.id = video_tags.video_id
                AND videos.availability_status = 'available'
            WHERE tags.library_id = ?
            GROUP BY tags.id
            ORDER BY tags.sort_order, tags.name COLLATE NOCASE
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(libraryID, to: 1, in: statement)
        bindText(libraryID, to: 2, in: statement)
        var tags: [TagRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let id = text(at: 0, in: statement),
                let storedLibraryID = text(at: 1, in: statement),
                let name = text(at: 2, in: statement),
                let source = text(at: 6, in: statement)
            else { throw DatabaseError.statementFailed }
            tags.append(TagRecord(
                id: id,
                libraryID: storedLibraryID,
                name: name,
                parentID: text(at: 3, in: statement),
                color: text(at: 4, in: statement),
                sortOrder: Int(sqlite3_column_int(statement, 5)),
                source: source,
                videoCount: Int(sqlite3_column_int(statement, 7))
            ))
        }
        return tags
    }

    func fetchSmartCollections(libraryID: String) throws -> [SmartCollectionRecord] {
        try prepareIfNeeded()
        let statement = try prepare(
            """
            SELECT id, library_id, name, rule_json, sort_order, created_at, updated_at
            FROM smart_collections
            WHERE library_id = ?
            ORDER BY sort_order, name COLLATE NOCASE
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(libraryID, to: 1, in: statement)

        var records: [SmartCollectionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let id = text(at: 0, in: statement),
                let storedLibraryID = text(at: 1, in: statement),
                let name = text(at: 2, in: statement),
                let ruleJSON = text(at: 3, in: statement),
                let rule = decodedLibraryQueryRule(ruleJSON)
            else {
                throw DatabaseError.statementFailed
            }
            records.append(SmartCollectionRecord(
                id: id,
                libraryID: storedLibraryID,
                name: name,
                rule: rule,
                sortOrder: Int(sqlite3_column_int64(statement, 4)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            ))
        }
        return records
    }

    func saveSmartCollection(_ record: SmartCollectionRecord) throws {
        try prepareIfNeeded()
        let cleanName = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanName.isEmpty == false else { throw DatabaseError.statementFailed }
        let statement = try prepare(
            """
            INSERT INTO smart_collections (
                id, library_id, name, normalized_name, rule_json,
                sort_order, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                normalized_name = excluded.normalized_name,
                rule_json = excluded.rule_json,
                updated_at = excluded.updated_at
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(record.id, to: 1, in: statement)
        bindText(record.libraryID, to: 2, in: statement)
        bindText(cleanName, to: 3, in: statement)
        bindText(normalizedTagName(cleanName), to: 4, in: statement)
        bindText(try encodedLibraryQueryRule(record.rule.normalized()), to: 5, in: statement)
        sqlite3_bind_int64(statement, 6, Int64(record.sortOrder))
        sqlite3_bind_double(statement, 7, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 8, record.updatedAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.statementFailed
        }
    }

    func deleteSmartCollection(id: String) throws {
        try prepareIfNeeded()
        let statement = try prepare("DELETE FROM smart_collections WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bindText(id, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.statementFailed
        }
    }

    @discardableResult
    func createTag(libraryID: String, name: String, parentID: String?, source: String = "user") throws -> String {
        try prepareIfNeeded()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanName.isEmpty == false else { throw DatabaseError.statementFailed }
        try ensureUniqueTagName(cleanName, libraryID: libraryID, parentID: parentID, excludingID: nil)
        let orderStatement = try prepare(
            "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM tags WHERE library_id = ? AND parent_id IS ?"
        )
        bindText(libraryID, to: 1, in: orderStatement)
        bindOptionalText(parentID, to: 2, in: orderStatement)
        guard sqlite3_step(orderStatement) == SQLITE_ROW else {
            sqlite3_finalize(orderStatement)
            throw DatabaseError.statementFailed
        }
        let sortOrder = sqlite3_column_int(orderStatement, 0)
        sqlite3_finalize(orderStatement)

        let statement = try prepare(
            """
            INSERT INTO tags (id, library_id, name, normalized_name, parent_id, color,
                              sort_order, source, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        let now = Date().timeIntervalSince1970
        let id = UUID().uuidString
        bindText(id, to: 1, in: statement)
        bindText(libraryID, to: 2, in: statement)
        bindText(cleanName, to: 3, in: statement)
        bindText(normalizedTagName(cleanName), to: 4, in: statement)
        bindOptionalText(parentID, to: 5, in: statement)
        sqlite3_bind_int(statement, 6, sortOrder)
        bindText(source, to: 7, in: statement)
        sqlite3_bind_double(statement, 8, now)
        sqlite3_bind_double(statement, 9, now)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.statementFailed }
        return id
    }

    func renameTag(id: String, name: String) throws {
        try prepareIfNeeded()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanName.isEmpty == false else { throw DatabaseError.statementFailed }
        let lookup = try prepare("SELECT library_id, parent_id FROM tags WHERE id = ?")
        bindText(id, to: 1, in: lookup)
        guard sqlite3_step(lookup) == SQLITE_ROW, let libraryID = text(at: 0, in: lookup) else {
            sqlite3_finalize(lookup)
            throw DatabaseError.statementFailed
        }
        let parentID = text(at: 1, in: lookup)
        sqlite3_finalize(lookup)
        try ensureUniqueTagName(cleanName, libraryID: libraryID, parentID: parentID, excludingID: id)
        let statement = try prepare(
            "UPDATE tags SET name = ?, normalized_name = ?, updated_at = ? WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        bindText(cleanName, to: 1, in: statement)
        bindText(normalizedTagName(cleanName), to: 2, in: statement)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        bindText(id, to: 4, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.statementFailed }
    }

    func setTagColor(id: String, color: String?) throws {
        try prepareIfNeeded()
        let statement = try prepare("UPDATE tags SET color = ?, updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bindOptionalText(color, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        bindText(id, to: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.statementFailed }
    }

    func deleteTag(id: String) throws {
        try prepareIfNeeded()
        let statement = try prepare("DELETE FROM tags WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bindText(id, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.statementFailed }
    }

    func moveTag(id: String, parentID: String?, sortOrder: Int) throws {
        try moveTags(ids: [id], parentID: parentID, sortOrder: sortOrder)
    }

    func moveTags(ids: [String], parentID: String?, sortOrder: Int) throws {
        try prepareIfNeeded()
        let uniqueIDs = ids.reduce(into: [String]()) { result, id in
            if result.contains(id) == false { result.append(id) }
        }
        guard uniqueIDs.isEmpty == false else { return }

        let allTags = try fetchTags(libraryID: LibraryRecord.primaryID)
        let tagsByID = Dictionary(uniqueKeysWithValues: allTags.map { ($0.id, $0) })
        guard uniqueIDs.allSatisfy({ tagsByID[$0] != nil }) else {
            throw DatabaseError.statementFailed
        }

        let requestedIDSet = Set(uniqueIDs)
        let topLevelIDs = uniqueIDs.filter { id in
            var ancestorID = tagsByID[id]?.parentID
            while let currentID = ancestorID {
                if requestedIDSet.contains(currentID) { return false }
                ancestorID = tagsByID[currentID]?.parentID
            }
            return true
        }
        let movingIDSet = Set(topLevelIDs)
        guard movingIDSet.isEmpty == false else { return }

        if let parentID {
            guard tagsByID[parentID] != nil else { throw DatabaseError.statementFailed }
            var ancestorID: String? = parentID
            while let currentID = ancestorID {
                if movingIDSet.contains(currentID) { throw DatabaseError.statementFailed }
                ancestorID = tagsByID[currentID]?.parentID
            }
        }

        let movingTags = topLevelIDs.compactMap { tagsByID[$0] }
        let removedBeforeTarget = movingTags.filter {
            $0.parentID == parentID && $0.sortOrder < sortOrder
        }.count
        let destinationSiblings = allTags
            .filter { $0.parentID == parentID && movingIDSet.contains($0.id) == false }
            .sorted { lhs, rhs in
                lhs.sortOrder == rhs.sortOrder
                    ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    : lhs.sortOrder < rhs.sortOrder
            }
        let insertionIndex = min(
            destinationSiblings.count,
            max(0, sortOrder - removedBeforeTarget)
        )
        var destinationIDs = destinationSiblings.map(\.id)
        destinationIDs.insert(contentsOf: topLevelIDs, at: insertionIndex)

        var affectedOldParents: [String?] = []
        for oldParentID in movingTags.map(\.parentID) where oldParentID != parentID {
            if affectedOldParents.contains(where: { $0 == oldParentID }) == false {
                affectedOldParents.append(oldParentID)
            }
        }

        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare(
                "UPDATE tags SET parent_id = ?, sort_order = ?, updated_at = ? WHERE id = ?"
            )
            defer { sqlite3_finalize(statement) }

            func updateTag(id: String, parentID: String?, sortOrder: Int) throws {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bindOptionalText(parentID, to: 1, in: statement)
                sqlite3_bind_int64(statement, 2, Int64(sortOrder))
                sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
                bindText(id, to: 4, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw DatabaseError.statementFailed
                }
            }

            for oldParentID in affectedOldParents {
                let siblingIDs = allTags
                    .filter { $0.parentID == oldParentID && movingIDSet.contains($0.id) == false }
                    .sorted { lhs, rhs in
                        lhs.sortOrder == rhs.sortOrder
                            ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                            : lhs.sortOrder < rhs.sortOrder
                    }
                    .map(\.id)
                for (order, id) in siblingIDs.enumerated() {
                    try updateTag(id: id, parentID: oldParentID, sortOrder: order)
                }
            }
            for (order, id) in destinationIDs.enumerated() {
                try updateTag(id: id, parentID: parentID, sortOrder: order)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func mergeTag(sourceID: String, targetID: String) throws {
        try prepareIfNeeded()
        guard sourceID != targetID else { return }
        guard try isTag(targetID, descendantOf: sourceID) == false else {
            throw DatabaseError.statementFailed
        }
        try execute("BEGIN IMMEDIATE")
        do {
            let relations = try prepare(
                "INSERT OR IGNORE INTO video_tags (video_id, tag_id, created_at) SELECT video_id, ?, created_at FROM video_tags WHERE tag_id = ?"
            )
            bindText(targetID, to: 1, in: relations)
            bindText(sourceID, to: 2, in: relations)
            guard sqlite3_step(relations) == SQLITE_DONE else { sqlite3_finalize(relations); throw DatabaseError.statementFailed }
            sqlite3_finalize(relations)
            let children = try prepare("UPDATE tags SET parent_id = ? WHERE parent_id = ?")
            bindText(targetID, to: 1, in: children)
            bindText(sourceID, to: 2, in: children)
            guard sqlite3_step(children) == SQLITE_DONE else { sqlite3_finalize(children); throw DatabaseError.statementFailed }
            sqlite3_finalize(children)
            let mappings = try prepare("UPDATE finder_tag_import_mappings SET tag_id = ? WHERE tag_id = ?")
            bindText(targetID, to: 1, in: mappings)
            bindText(sourceID, to: 2, in: mappings)
            guard sqlite3_step(mappings) == SQLITE_DONE else { sqlite3_finalize(mappings); throw DatabaseError.statementFailed }
            sqlite3_finalize(mappings)
            try deleteTag(id: sourceID)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func setTagAssignment(tagID: String, videoIDs: [String], enabled: Bool) throws {
        try setTagAssignments([tagID: enabled], videoIDs: videoIDs)
    }

    func setTagAssignments(_ assignments: [String: Bool], videoIDs: [String]) throws {
        try prepareIfNeeded()
        guard videoIDs.isEmpty == false, assignments.isEmpty == false else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            try applyTagAssignments(assignments, videoIDs: videoIDs)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func applyTagDraft(
        libraryID: String,
        creations: [TagCreationDraft],
        assignments: [String: Bool],
        videoIDs: [String]
    ) throws {
        try prepareIfNeeded()
        guard creations.isEmpty == false || assignments.isEmpty == false else { return }
        guard videoIDs.isEmpty == false else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            var resolvedAssignments = assignments
            for creation in creations {
                let tagID = try createTag(
                    libraryID: libraryID,
                    name: creation.name,
                    parentID: creation.parentID
                )
                if let enabled = resolvedAssignments.removeValue(forKey: creation.id) {
                    resolvedAssignments[tagID] = enabled
                }
            }
            try applyTagAssignments(resolvedAssignments, videoIDs: videoIDs)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func applyTagAssignments(_ assignments: [String: Bool], videoIDs: [String]) throws {
        guard assignments.isEmpty == false, videoIDs.isEmpty == false else { return }
        let insertStatement = try prepare(
            "INSERT OR IGNORE INTO video_tags (video_id, tag_id, created_at) VALUES (?, ?, ?)"
        )
        defer { sqlite3_finalize(insertStatement) }
        for (tagID, enabled) in assignments {
            if enabled {
                for videoID in videoIDs {
                    sqlite3_reset(insertStatement)
                    sqlite3_clear_bindings(insertStatement)
                    bindText(videoID, to: 1, in: insertStatement)
                    bindText(tagID, to: 2, in: insertStatement)
                    sqlite3_bind_double(insertStatement, 3, Date().timeIntervalSince1970)
                    guard sqlite3_step(insertStatement) == SQLITE_DONE else {
                        throw DatabaseError.statementFailed
                    }
                }
                continue
            }
            let placeholders = Array(repeating: "?", count: videoIDs.count).joined(separator: ",")
            let deleteStatement = try prepare(
                "DELETE FROM video_tags WHERE tag_id = ? AND video_id IN (\(placeholders))"
            )
            bindText(tagID, to: 1, in: deleteStatement)
            for (index, videoID) in videoIDs.enumerated() {
                bindText(videoID, to: Int32(index + 2), in: deleteStatement)
            }
            let result = sqlite3_step(deleteStatement)
            sqlite3_finalize(deleteStatement)
            guard result == SQLITE_DONE else {
                throw DatabaseError.statementFailed
            }
        }
    }

    func tagAssignmentStates(videoIDs: [String], tags: [TagRecord]) throws -> [String: TagAssignmentState] {
        try prepareIfNeeded()
        guard videoIDs.isEmpty == false else { return [:] }
        let placeholders = Array(repeating: "?", count: videoIDs.count).joined(separator: ",")
        let statement = try prepare(
            "SELECT tag_id, COUNT(DISTINCT video_id) FROM video_tags WHERE video_id IN (\(placeholders)) GROUP BY tag_id"
        )
        defer { sqlite3_finalize(statement) }
        for (index, videoID) in videoIDs.enumerated() { bindText(videoID, to: Int32(index + 1), in: statement) }
        var counts: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            if let tagID = text(at: 0, in: statement) { counts[tagID] = Int(sqlite3_column_int(statement, 1)) }
        }
        return Dictionary(uniqueKeysWithValues: tags.map { tag in
            let count = counts[tag.id] ?? 0
            let state: TagAssignmentState = count == 0 ? .off : (count == videoIDs.count ? .on : .mixed)
            return (tag.id, state)
        })
    }

    func captureTagState(libraryID: String) throws -> TagStateSnapshot {
        let tags = try fetchTags(libraryID: libraryID)
        let statement = try prepare(
            """
            SELECT video_tags.video_id, video_tags.tag_id
            FROM video_tags JOIN tags ON tags.id = video_tags.tag_id
            WHERE tags.library_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(libraryID, to: 1, in: statement)
        var relations: [VideoTagRelation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let videoID = text(at: 0, in: statement), let tagID = text(at: 1, in: statement) {
                relations.append(VideoTagRelation(videoID: videoID, tagID: tagID))
            }
        }
        let mappingStatement = try prepare(
            """
            SELECT external_key, tag_id, first_imported_at, last_seen_at
            FROM finder_tag_import_mappings
            WHERE library_id = ?
            """
        )
        defer { sqlite3_finalize(mappingStatement) }
        bindText(libraryID, to: 1, in: mappingStatement)
        var finderMappings: [FinderTagMapping] = []
        while sqlite3_step(mappingStatement) == SQLITE_ROW {
            guard let externalKey = text(at: 0, in: mappingStatement),
                  let tagID = text(at: 1, in: mappingStatement) else {
                throw DatabaseError.statementFailed
            }
            finderMappings.append(FinderTagMapping(
                externalKey: externalKey,
                tagID: tagID,
                firstImportedAt: Date(timeIntervalSince1970: sqlite3_column_double(mappingStatement, 2)),
                lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(mappingStatement, 3))
            ))
        }
        return TagStateSnapshot(
            libraryID: libraryID,
            tags: tags,
            relations: relations,
            finderMappings: finderMappings
        )
    }

    func restoreTagState(_ snapshot: TagStateSnapshot) throws {
        try prepareIfNeeded()
        try execute("BEGIN IMMEDIATE")
        do {
            let delete = try prepare("DELETE FROM tags WHERE library_id = ?")
            bindText(snapshot.libraryID, to: 1, in: delete)
            guard sqlite3_step(delete) == SQLITE_DONE else { sqlite3_finalize(delete); throw DatabaseError.statementFailed }
            sqlite3_finalize(delete)

            var pending = snapshot.tags
            var inserted = Set<String>()
            while pending.isEmpty == false {
                let ready = pending.filter { $0.parentID == nil || inserted.contains($0.parentID!) }
                guard ready.isEmpty == false else { throw DatabaseError.statementFailed }
                for tag in ready {
                    let statement = try prepare(
                        """
                        INSERT INTO tags (id, library_id, name, normalized_name, parent_id, color,
                                          sort_order, source, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """
                    )
                    bindText(tag.id, to: 1, in: statement)
                    bindText(tag.libraryID, to: 2, in: statement)
                    bindText(tag.name, to: 3, in: statement)
                    bindText(normalizedTagName(tag.name), to: 4, in: statement)
                    bindOptionalText(tag.parentID, to: 5, in: statement)
                    bindOptionalText(tag.color, to: 6, in: statement)
                    sqlite3_bind_int64(statement, 7, Int64(tag.sortOrder))
                    bindText(tag.source, to: 8, in: statement)
                    let now = Date().timeIntervalSince1970
                    sqlite3_bind_double(statement, 9, now)
                    sqlite3_bind_double(statement, 10, now)
                    guard sqlite3_step(statement) == SQLITE_DONE else { sqlite3_finalize(statement); throw DatabaseError.statementFailed }
                    sqlite3_finalize(statement)
                    inserted.insert(tag.id)
                }
                let readyIDs = Set(ready.map(\.id))
                pending.removeAll { readyIDs.contains($0.id) }
            }
            let relationStatement = try prepare(
                "INSERT OR IGNORE INTO video_tags (video_id, tag_id, created_at) VALUES (?, ?, ?)"
            )
            defer { sqlite3_finalize(relationStatement) }
            for relation in snapshot.relations {
                sqlite3_reset(relationStatement); sqlite3_clear_bindings(relationStatement)
                bindText(relation.videoID, to: 1, in: relationStatement)
                bindText(relation.tagID, to: 2, in: relationStatement)
                sqlite3_bind_double(relationStatement, 3, Date().timeIntervalSince1970)
                guard sqlite3_step(relationStatement) == SQLITE_DONE else { throw DatabaseError.statementFailed }
            }
            let mappingStatement = try prepare(
                """
                INSERT INTO finder_tag_import_mappings
                    (library_id, external_key, tag_id, first_imported_at, last_seen_at)
                VALUES (?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(mappingStatement) }
            for mapping in snapshot.finderMappings {
                sqlite3_reset(mappingStatement); sqlite3_clear_bindings(mappingStatement)
                bindText(snapshot.libraryID, to: 1, in: mappingStatement)
                bindText(mapping.externalKey, to: 2, in: mappingStatement)
                bindText(mapping.tagID, to: 3, in: mappingStatement)
                sqlite3_bind_double(mappingStatement, 4, mapping.firstImportedAt.timeIntervalSince1970)
                sqlite3_bind_double(mappingStatement, 5, mapping.lastSeenAt.timeIntervalSince1970)
                guard sqlite3_step(mappingStatement) == SQLITE_DONE else {
                    throw DatabaseError.statementFailed
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func finderTagID(
        libraryID: String,
        externalKey: String,
        displayName: String,
        importedAt: Date
    ) throws -> String {
        let lookup = try prepare(
            "SELECT tag_id FROM finder_tag_import_mappings WHERE library_id = ? AND external_key = ? LIMIT 1"
        )
        bindText(libraryID, to: 1, in: lookup)
        bindText(externalKey, to: 2, in: lookup)
        if sqlite3_step(lookup) == SQLITE_ROW, let id = text(at: 0, in: lookup) {
            sqlite3_finalize(lookup)
            let update = try prepare(
                "UPDATE finder_tag_import_mappings SET last_seen_at = ? WHERE library_id = ? AND external_key = ?"
            )
            sqlite3_bind_double(update, 1, importedAt.timeIntervalSince1970)
            bindText(libraryID, to: 2, in: update)
            bindText(externalKey, to: 3, in: update)
            guard sqlite3_step(update) == SQLITE_DONE else {
                sqlite3_finalize(update)
                throw DatabaseError.statementFailed
            }
            sqlite3_finalize(update)
            return id
        }
        sqlite3_finalize(lookup)

        let existing = try prepare(
            """
            SELECT id FROM tags
            WHERE library_id = ? AND parent_id IS NULL AND normalized_name = ?
            ORDER BY CASE source WHEN 'user' THEN 0 ELSE 1 END, sort_order
            LIMIT 1
            """
        )
        bindText(libraryID, to: 1, in: existing)
        bindText(externalKey, to: 2, in: existing)
        let existingTagID = sqlite3_step(existing) == SQLITE_ROW ? text(at: 0, in: existing) : nil
        sqlite3_finalize(existing)

        let tagID = try existingTagID
            ?? createTag(libraryID: libraryID, name: displayName, parentID: nil, source: "finder")
        let insert = try prepare(
            """
            INSERT INTO finder_tag_import_mappings
                (library_id, external_key, tag_id, first_imported_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?)
            """
        )
        bindText(libraryID, to: 1, in: insert)
        bindText(externalKey, to: 2, in: insert)
        bindText(tagID, to: 3, in: insert)
        sqlite3_bind_double(insert, 4, importedAt.timeIntervalSince1970)
        sqlite3_bind_double(insert, 5, importedAt.timeIntervalSince1970)
        guard sqlite3_step(insert) == SQLITE_DONE else {
            sqlite3_finalize(insert)
            throw DatabaseError.statementFailed
        }
        sqlite3_finalize(insert)
        return tagID
    }

    private func migrateIfNeeded() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at REAL NOT NULL
        )
        """)

        let currentVersion = try scalarInt("SELECT COALESCE(MAX(version), 0) FROM schema_migrations")
        guard currentVersion < Self.currentSchemaVersion else { return }

        for version in (currentVersion + 1)...Self.currentSchemaVersion {
            let rebuildsVideoTable = version == 4
            do {
                if rebuildsVideoTable { try execute("PRAGMA foreign_keys = OFF") }
                try execute("BEGIN IMMEDIATE")
                try applyMigration(version)
                let statement = try prepare(
                    "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)"
                )
                sqlite3_bind_int(statement, 1, Int32(version))
                sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    sqlite3_finalize(statement)
                    throw DatabaseError.migrationFailed
                }
                sqlite3_finalize(statement)
                try execute("COMMIT")
                if rebuildsVideoTable {
                    try execute("PRAGMA foreign_keys = ON")
                    try ensureForeignKeysAreValid()
                }
            } catch {
                try? execute("ROLLBACK")
                if rebuildsVideoTable { try? execute("PRAGMA foreign_keys = ON") }
                throw DatabaseError.migrationFailed
            }
        }
    }

    private func prepareIfNeeded() throws {
        guard isPrepared == false else { return }
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA busy_timeout = 5000")
        try migrateIfNeeded()
        isPrepared = true
    }

    private func applyMigration(_ version: Int) throws {
        if version == 14 {
            try execute("ALTER TABLE source_authorizations ADD COLUMN scan_policy_explicit INTEGER NOT NULL DEFAULT 0")
            try execute("ALTER TABLE video_locations ADD COLUMN requires_recovery_verification INTEGER NOT NULL DEFAULT 0")
            return
        }
        if version == 13 {
            try execute(
                "ALTER TABLE source_authorizations "
                    + "ADD COLUMN scans_descendants INTEGER NOT NULL DEFAULT 0"
            )
            return
        }
        if version == 12 {
            try execute("ALTER TABLE videos ADD COLUMN content_fingerprint BLOB")
            return
        }
        if version == 11 {
            try execute("ALTER TABLE video_locations ADD COLUMN last_known_path TEXT")
            return
        }
        if version == 10 {
            try execute("ALTER TABLE videos ADD COLUMN invalidated_at REAL")
            return
        }
        if version == 9 {
            try execute("""
            CREATE TABLE smart_collections (
                id TEXT PRIMARY KEY,
                library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                normalized_name TEXT NOT NULL,
                rule_json TEXT NOT NULL,
                sort_order INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                UNIQUE(library_id, normalized_name)
            );
            CREATE INDEX smart_collections_sort_idx
                ON smart_collections(library_id, sort_order);
            """)
            return
        }
        if version == 8 {
            try execute("""
            ALTER TABLE videos ADD COLUMN media_source_info TEXT;
            UPDATE videos
            SET metadata_status = 'pending'
            WHERE availability_status = 'available';
            """)
            return
        }
        if version == 7 {
            try execute("""
            ALTER TABLE video_locations ADD COLUMN fallback_path_key BLOB;
            CREATE INDEX video_locations_fallback_path_key_idx
                ON video_locations(fallback_path_key);
            """)
            return
        }
        if version == 6 {
            try migrateFinderTagsToTopLevel()
            return
        }
        if version == 2 {
            try execute("CREATE INDEX IF NOT EXISTS video_tags_tag_idx ON video_tags(tag_id, video_id)")
            return
        }
        if version == 3 {
            try execute("""
            ALTER TABLE videos ADD COLUMN finder_tags_imported_at REAL;
            UPDATE videos SET finder_tags_imported_at = updated_at;
            """)
            return
        }
        if version == 4 {
            try execute("""
            CREATE TABLE videos_rebuilt (
                id TEXT PRIMARY KEY,
                library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
                relative_path TEXT NOT NULL,
                volume_identifier BLOB,
                file_resource_identifier BLOB,
                filename TEXT NOT NULL,
                file_extension TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                creation_date REAL,
                modification_date REAL,
                duration REAL,
                width INTEGER,
                height INTEGER,
                thumbnail_id TEXT,
                metadata_status TEXT NOT NULL DEFAULT 'pending',
                thumbnail_status TEXT NOT NULL DEFAULT 'pending',
                availability_status TEXT NOT NULL DEFAULT 'available',
                first_indexed_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                last_seen_scan_id TEXT REFERENCES scan_runs(id),
                finder_tags_imported_at REAL
            );

            INSERT INTO videos_rebuilt (
                id, library_id, relative_path, volume_identifier, file_resource_identifier,
                filename, file_extension, file_size, creation_date, modification_date,
                duration, width, height, thumbnail_id, metadata_status, thumbnail_status,
                availability_status, first_indexed_at, updated_at, last_seen_scan_id,
                finder_tags_imported_at
            )
            SELECT id, library_id, relative_path, volume_identifier, file_resource_identifier,
                   filename, file_extension, file_size, creation_date, modification_date,
                   duration, width, height, thumbnail_id, metadata_status, thumbnail_status,
                   availability_status, first_indexed_at, updated_at, last_seen_scan_id,
                   finder_tags_imported_at
            FROM videos;

            DROP TABLE videos;
            ALTER TABLE videos_rebuilt RENAME TO videos;

            CREATE UNIQUE INDEX videos_available_path_idx
                ON videos(library_id, relative_path)
                WHERE availability_status = 'available';
            CREATE INDEX videos_file_identity_idx
                ON videos(library_id, volume_identifier, file_resource_identifier);
            CREATE INDEX videos_availability_idx ON videos(library_id, availability_status);
            CREATE INDEX videos_first_indexed_idx ON videos(library_id, first_indexed_at);
            """)
            return
        }
        if version == 5 {
            try execute("""
            CREATE TABLE source_authorizations (
                id TEXT PRIMARY KEY,
                library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
                display_name TEXT NOT NULL,
                root_bookmark_data BLOB NOT NULL,
                created_at REAL NOT NULL,
                last_event_id INTEGER,
                health_status TEXT NOT NULL DEFAULT 'available'
            );

            CREATE TABLE video_locations (
                video_id TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
                source_id TEXT NOT NULL REFERENCES source_authorizations(id) ON DELETE CASCADE,
                relative_path TEXT NOT NULL,
                last_verified_at REAL NOT NULL,
                is_available INTEGER NOT NULL DEFAULT 1,
                PRIMARY KEY(video_id, source_id, relative_path),
                UNIQUE(source_id, relative_path)
            );

            CREATE TABLE import_runs (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES source_authorizations(id) ON DELETE CASCADE,
                started_at REAL NOT NULL,
                completed_at REAL,
                status TEXT NOT NULL,
                added_count INTEGER NOT NULL DEFAULT 0,
                existing_count INTEGER NOT NULL DEFAULT 0,
                failed_count INTEGER NOT NULL DEFAULT 0
            );

            INSERT INTO source_authorizations (
                id, library_id, display_name, root_bookmark_data, created_at, health_status
            )
            SELECT 'legacy-' || id, id, name, root_bookmark_data, created_at, 'available'
            FROM libraries;

            INSERT OR IGNORE INTO video_locations (
                video_id, source_id, relative_path, last_verified_at, is_available
            )
            SELECT videos.id, 'legacy-' || videos.library_id, videos.relative_path,
                   videos.updated_at,
                   CASE videos.availability_status WHEN 'available' THEN 1 ELSE 0 END
            FROM videos
            ORDER BY CASE videos.availability_status WHEN 'available' THEN 0 ELSE 1 END,
                     videos.first_indexed_at;

            DROP INDEX IF EXISTS videos_available_path_idx;
            CREATE INDEX videos_global_file_identity_idx
                ON videos(volume_identifier, file_resource_identifier);
            CREATE INDEX video_locations_video_idx ON video_locations(video_id, is_available);
            CREATE INDEX video_locations_source_idx ON video_locations(source_id, is_available);
            """)
            return
        }
        guard version == 1 else { throw DatabaseError.migrationFailed }

        try execute("""
        CREATE TABLE libraries (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            root_bookmark_data BLOB NOT NULL,
            created_at REAL NOT NULL,
            last_scan_at REAL,
            last_fsevent_id INTEGER
        );

        CREATE TABLE scan_runs (
            id TEXT PRIMARY KEY,
            library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
            started_at REAL NOT NULL,
            completed_at REAL,
            status TEXT NOT NULL
        );

        CREATE TABLE videos (
            id TEXT PRIMARY KEY,
            library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
            relative_path TEXT NOT NULL,
            volume_identifier BLOB,
            file_resource_identifier BLOB,
            filename TEXT NOT NULL,
            file_extension TEXT NOT NULL,
            file_size INTEGER NOT NULL,
            creation_date REAL,
            modification_date REAL,
            duration REAL,
            width INTEGER,
            height INTEGER,
            thumbnail_id TEXT,
            metadata_status TEXT NOT NULL DEFAULT 'pending',
            thumbnail_status TEXT NOT NULL DEFAULT 'pending',
            availability_status TEXT NOT NULL DEFAULT 'available',
            first_indexed_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            last_seen_scan_id TEXT REFERENCES scan_runs(id),
            UNIQUE(library_id, relative_path)
        );

        CREATE TABLE tags (
            id TEXT PRIMARY KEY,
            library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            normalized_name TEXT NOT NULL,
            parent_id TEXT REFERENCES tags(id) ON DELETE CASCADE,
            color TEXT,
            sort_order INTEGER NOT NULL,
            source TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(library_id, parent_id, normalized_name)
        );

        CREATE TABLE video_tags (
            video_id TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
            tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            created_at REAL NOT NULL,
            PRIMARY KEY(video_id, tag_id)
        );

        CREATE TABLE finder_tag_import_mappings (
            library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
            external_key TEXT NOT NULL,
            tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            first_imported_at REAL NOT NULL,
            last_seen_at REAL NOT NULL,
            PRIMARY KEY(library_id, external_key)
        );

        CREATE INDEX videos_file_identity_idx
            ON videos(library_id, volume_identifier, file_resource_identifier);
        CREATE INDEX videos_availability_idx ON videos(library_id, availability_status);
        CREATE INDEX videos_first_indexed_idx ON videos(library_id, first_indexed_at);
        CREATE INDEX tags_parent_sort_idx ON tags(library_id, parent_id, sort_order);
        """)
    }

    private func migrateFinderTagsToTopLevel() throws {
        let rootsStatement = try prepare(
            "SELECT id, library_id FROM tags WHERE source = 'finder-root'"
        )
        var roots: [(id: String, libraryID: String)] = []
        while sqlite3_step(rootsStatement) == SQLITE_ROW {
            guard let id = text(at: 0, in: rootsStatement),
                  let libraryID = text(at: 1, in: rootsStatement) else {
                sqlite3_finalize(rootsStatement)
                throw DatabaseError.statementFailed
            }
            roots.append((id, libraryID))
        }
        sqlite3_finalize(rootsStatement)

        for root in roots {
            let childrenStatement = try prepare(
                "SELECT id, normalized_name FROM tags WHERE parent_id = ? ORDER BY sort_order"
            )
            bindText(root.id, to: 1, in: childrenStatement)
            var children: [(id: String, normalizedName: String)] = []
            while sqlite3_step(childrenStatement) == SQLITE_ROW {
                guard let id = text(at: 0, in: childrenStatement),
                      let normalizedName = text(at: 1, in: childrenStatement) else {
                    sqlite3_finalize(childrenStatement)
                    throw DatabaseError.statementFailed
                }
                children.append((id, normalizedName))
            }
            sqlite3_finalize(childrenStatement)

            for child in children {
                if let targetID = try matchingTagID(
                    libraryID: root.libraryID,
                    parentID: nil,
                    normalizedName: child.normalizedName,
                    excluding: [root.id, child.id]
                ) {
                    try mergeTagDuringMigration(sourceID: child.id, targetID: targetID)
                } else {
                    let move = try prepare(
                        "UPDATE tags SET parent_id = NULL, sort_order = ?, updated_at = ? WHERE id = ?"
                    )
                    sqlite3_bind_int64(move, 1, Int64(try nextTagOrder(libraryID: root.libraryID, parentID: nil)))
                    sqlite3_bind_double(move, 2, Date().timeIntervalSince1970)
                    bindText(child.id, to: 3, in: move)
                    guard sqlite3_step(move) == SQLITE_DONE else {
                        sqlite3_finalize(move)
                        throw DatabaseError.statementFailed
                    }
                    sqlite3_finalize(move)
                }
            }

            let deleteRoot = try prepare("DELETE FROM tags WHERE id = ?")
            bindText(root.id, to: 1, in: deleteRoot)
            guard sqlite3_step(deleteRoot) == SQLITE_DONE else {
                sqlite3_finalize(deleteRoot)
                throw DatabaseError.statementFailed
            }
            sqlite3_finalize(deleteRoot)
        }
    }

    private func mergeTagDuringMigration(sourceID: String, targetID: String) throws {
        let targetLibraryStatement = try prepare(
            "SELECT library_id FROM tags WHERE id = ?"
        )
        bindText(targetID, to: 1, in: targetLibraryStatement)
        guard sqlite3_step(targetLibraryStatement) == SQLITE_ROW,
              let libraryID = text(at: 0, in: targetLibraryStatement) else {
            sqlite3_finalize(targetLibraryStatement)
            throw DatabaseError.statementFailed
        }
        sqlite3_finalize(targetLibraryStatement)

        let childrenStatement = try prepare(
            "SELECT id, normalized_name FROM tags WHERE parent_id = ? ORDER BY sort_order"
        )
        bindText(sourceID, to: 1, in: childrenStatement)
        var children: [(id: String, normalizedName: String)] = []
        while sqlite3_step(childrenStatement) == SQLITE_ROW {
            guard let id = text(at: 0, in: childrenStatement),
                  let normalizedName = text(at: 1, in: childrenStatement) else {
                sqlite3_finalize(childrenStatement)
                throw DatabaseError.statementFailed
            }
            children.append((id, normalizedName))
        }
        sqlite3_finalize(childrenStatement)

        for child in children {
            if let matchingID = try matchingTagID(
                libraryID: libraryID,
                parentID: targetID,
                normalizedName: child.normalizedName,
                excluding: [child.id]
            ) {
                try mergeTagDuringMigration(sourceID: child.id, targetID: matchingID)
            } else {
                let move = try prepare(
                    "UPDATE tags SET parent_id = ?, sort_order = ?, updated_at = ? WHERE id = ?"
                )
                bindText(targetID, to: 1, in: move)
                sqlite3_bind_int64(move, 2, Int64(try nextTagOrder(libraryID: libraryID, parentID: targetID)))
                sqlite3_bind_double(move, 3, Date().timeIntervalSince1970)
                bindText(child.id, to: 4, in: move)
                guard sqlite3_step(move) == SQLITE_DONE else {
                    sqlite3_finalize(move)
                    throw DatabaseError.statementFailed
                }
                sqlite3_finalize(move)
            }
        }

        let relations = try prepare(
            "INSERT OR IGNORE INTO video_tags (video_id, tag_id, created_at) SELECT video_id, ?, created_at FROM video_tags WHERE tag_id = ?"
        )
        bindText(targetID, to: 1, in: relations)
        bindText(sourceID, to: 2, in: relations)
        guard sqlite3_step(relations) == SQLITE_DONE else {
            sqlite3_finalize(relations)
            throw DatabaseError.statementFailed
        }
        sqlite3_finalize(relations)

        let mappings = try prepare(
            "UPDATE finder_tag_import_mappings SET tag_id = ? WHERE tag_id = ?"
        )
        bindText(targetID, to: 1, in: mappings)
        bindText(sourceID, to: 2, in: mappings)
        guard sqlite3_step(mappings) == SQLITE_DONE else {
            sqlite3_finalize(mappings)
            throw DatabaseError.statementFailed
        }
        sqlite3_finalize(mappings)

        let delete = try prepare("DELETE FROM tags WHERE id = ?")
        bindText(sourceID, to: 1, in: delete)
        guard sqlite3_step(delete) == SQLITE_DONE else {
            sqlite3_finalize(delete)
            throw DatabaseError.statementFailed
        }
        sqlite3_finalize(delete)
    }

    private func matchingTagID(
        libraryID: String,
        parentID: String?,
        normalizedName: String,
        excluding excludedIDs: [String]
    ) throws -> String? {
        let placeholders = excludedIDs.map { _ in "?" }.joined(separator: ", ")
        let exclusionClause = excludedIDs.isEmpty ? "" : "AND id NOT IN (\(placeholders))"
        let statement = try prepare(
            """
            SELECT id FROM tags
            WHERE library_id = ? AND parent_id IS ? AND normalized_name = ? \(exclusionClause)
            ORDER BY CASE source WHEN 'user' THEN 0 ELSE 1 END, sort_order
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(libraryID, to: 1, in: statement)
        bindOptionalText(parentID, to: 2, in: statement)
        bindText(normalizedName, to: 3, in: statement)
        for (offset, id) in excludedIDs.enumerated() {
            bindText(id, to: Int32(offset + 4), in: statement)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(at: 0, in: statement)
    }

    private func nextTagOrder(libraryID: String, parentID: String?) throws -> Int {
        let statement = try prepare(
            "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM tags WHERE library_id = ? AND parent_id IS ?"
        )
        defer { sqlite3_finalize(statement) }
        bindText(libraryID, to: 1, in: statement)
        bindOptionalText(parentID, to: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw DatabaseError.statementFailed }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection.handle, sql, nil, nil, &errorMessage)
        sqlite3_free(errorMessage)
        guard result == SQLITE_OK else {
            throw DatabaseError.statementFailed
        }
    }

    private func ensureForeignKeysAreValid() throws {
        let statement = try prepare("PRAGMA foreign_key_check")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) != SQLITE_ROW else {
            throw DatabaseError.statementFailed
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.statementFailed
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.statementFailed
        }
        return statement
    }

    private func bindText(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func bindData(_ value: Data?, to index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
    }

    private func normalizedTagName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensureUniqueTagName(
        _ name: String,
        libraryID: String,
        parentID: String?,
        excludingID: String?
    ) throws {
        let statement = try prepare(
            """
            SELECT 1 FROM tags
            WHERE library_id = ? AND parent_id IS ? AND normalized_name = ?
              AND (? IS NULL OR id != ?)
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(libraryID, to: 1, in: statement)
        bindOptionalText(parentID, to: 2, in: statement)
        bindText(normalizedTagName(name), to: 3, in: statement)
        bindOptionalText(excludingID, to: 4, in: statement)
        bindOptionalText(excludingID, to: 5, in: statement)
        guard sqlite3_step(statement) != SQLITE_ROW else {
            throw DatabaseError.statementFailed
        }
    }

    private func isTag(_ candidateID: String, descendantOf tagID: String) throws -> Bool {
        let statement = try prepare(
            """
            WITH RECURSIVE descendants(id) AS (
                SELECT id FROM tags WHERE parent_id = ?
                UNION ALL SELECT tags.id FROM tags JOIN descendants ON tags.parent_id = descendants.id
            ) SELECT 1 FROM descendants WHERE id = ? LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(tagID, to: 1, in: statement)
        bindText(candidateID, to: 2, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func bindDate(_ value: Date?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindDouble(_ value: Double?, to index: Int32, in statement: OpaquePointer) {
        if let value { sqlite3_bind_double(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func bindInt(_ value: Int?, to index: Int32, in statement: OpaquePointer) {
        if let value { sqlite3_bind_int64(statement, index, Int64(value)) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func bindOptionalText(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        if let value { bindText(value, to: index, in: statement) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func text(at index: Int32, in statement: OpaquePointer) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func data(at index: Int32, in statement: OpaquePointer) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private func date(at index: Int32, in statement: OpaquePointer) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func optionalDouble(at index: Int32, in statement: OpaquePointer) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private func optionalInt(at index: Int32, in statement: OpaquePointer) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    private func encodedMediaSourceInfo(_ info: MediaSourceInfo?) throws -> String? {
        guard let info else { return nil }
        let data = try JSONEncoder().encode(info)
        guard let value = String(data: data, encoding: .utf8) else {
            throw DatabaseError.statementFailed
        }
        return value
    }

    private func decodedMediaSourceInfo(_ value: String?) -> MediaSourceInfo? {
        guard let value, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MediaSourceInfo.self, from: data)
    }

    private func encodedLibraryQueryRule(_ rule: LibraryQueryRule) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(rule)
        guard let value = String(data: data, encoding: .utf8) else {
            throw DatabaseError.statementFailed
        }
        return value
    }

    private func decodedLibraryQueryRule(_ value: String) -> LibraryQueryRule? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LibraryQueryRule.self, from: data).normalized()
    }

    private func videoRecord(from statement: OpaquePointer) throws -> VideoRecord {
        guard
            let id = text(at: 0, in: statement),
            let storedLibraryID = text(at: 1, in: statement),
            let relativePath = text(at: 2, in: statement),
            let filename = text(at: 3, in: statement),
            let fileExtension = text(at: 4, in: statement),
            let metadataText = text(at: 12, in: statement),
            let metadataStatus = VideoRecord.ProcessingStatus(rawValue: metadataText),
            let thumbnailText = text(at: 13, in: statement),
            let thumbnailStatus = VideoRecord.ProcessingStatus(rawValue: thumbnailText),
            let availabilityText = text(at: 15, in: statement)
        else {
            throw DatabaseError.statementFailed
        }
        let availability: VideoRecord.Availability
        let unavailableReason: VideoRecord.UnavailableReason?
        switch availabilityText {
        case "available":
            availability = .available
            unavailableReason = nil
        case "missing":
            availability = .unavailable
            unavailableReason = .missingFromKnownLocation
        default:
            throw DatabaseError.statementFailed
        }
        return VideoRecord(
            id: id,
            libraryID: storedLibraryID,
            relativePath: relativePath,
            filename: filename,
            fileExtension: fileExtension,
            fileSize: sqlite3_column_int64(statement, 5),
            creationDate: date(at: 6, in: statement),
            modificationDate: date(at: 7, in: statement),
            duration: optionalDouble(at: 8, in: statement),
            width: optionalInt(at: 9, in: statement),
            height: optionalInt(at: 10, in: statement),
            thumbnailID: text(at: 11, in: statement),
            metadataStatus: metadataStatus,
            thumbnailStatus: thumbnailStatus,
            firstIndexedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 14)),
            availability: availability,
            unavailableReason: unavailableReason,
            invalidatedAt: date(at: 17, in: statement),
            mediaSourceInfo: decodedMediaSourceInfo(text(at: 16, in: statement)),
            contentFingerprint: data(at: 18, in: statement)
        )
    }

}

private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
