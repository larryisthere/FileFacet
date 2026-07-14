import Foundation
import SQLite3

actor DatabaseStore {
    static let currentSchemaVersion = 1

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
        let statement = try prepare(sql, operation: "保存资料库")
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
            throw DatabaseError.statementFailed("保存资料库")
        }
    }

    func replaceLibrary(_ record: LibraryRecord) throws {
        try prepareIfNeeded()
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("DELETE FROM libraries WHERE id = ?", operation: "更换资料库")
            bindText(record.id, to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_finalize(statement)
                throw DatabaseError.statementFailed("更换资料库")
            }
            sqlite3_finalize(statement)
            try saveLibrary(record)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func fetchPrimaryLibrary() throws -> LibraryRecord? {
        try prepareIfNeeded()
        let statement = try prepare(
            "SELECT id, name, root_bookmark_data, created_at, last_scan_at FROM libraries WHERE id = ? LIMIT 1",
            operation: "读取资料库"
        )
        defer { sqlite3_finalize(statement) }
        bindText(LibraryRecord.primaryID, to: 1, in: statement)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard
            let idText = sqlite3_column_text(statement, 0),
            let nameText = sqlite3_column_text(statement, 1),
            let bookmarkBytes = sqlite3_column_blob(statement, 2)
        else {
            throw DatabaseError.statementFailed("读取资料库")
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

    func fetchVideos(libraryID: String, includeMissing: Bool = false) throws -> [VideoRecord] {
        try prepareIfNeeded()
        let availabilityClause = includeMissing ? "" : "AND availability_status = 'available'"
        let statement = try prepare(
            """
            SELECT id, library_id, relative_path, filename, file_extension, file_size,
                   creation_date, modification_date, duration, width, height, thumbnail_id,
                   metadata_status, thumbnail_status, first_indexed_at, availability_status
            FROM videos
            WHERE library_id = ? \(availabilityClause)
            ORDER BY filename COLLATE NOCASE, relative_path COLLATE NOCASE
            """,
            operation: "读取视频索引"
        )
        defer { sqlite3_finalize(statement) }
        bindText(libraryID, to: 1, in: statement)

        var records: [VideoRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            records.append(try videoRecord(from: statement))
        }
        return records
    }

    func fetchVideo(id: String) throws -> VideoRecord? {
        try prepareIfNeeded()
        let statement = try prepare(
            """
            SELECT id, library_id, relative_path, filename, file_extension, file_size,
                   creation_date, modification_date, duration, width, height, thumbnail_id,
                   metadata_status, thumbnail_status, first_indexed_at, availability_status
            FROM videos WHERE id = ? LIMIT 1
            """,
            operation: "读取视频索引"
        )
        defer { sqlite3_finalize(statement) }
        bindText(id, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try videoRecord(from: statement)
    }

    func updateMediaInfo(videoID: String, result: MediaProcessingResult) throws -> VideoRecord? {
        try prepareIfNeeded()
        let statement = try prepare(
            """
            UPDATE videos SET duration = ?, width = ?, height = ?, thumbnail_id = ?,
                metadata_status = ?, thumbnail_status = ?, updated_at = ?
            WHERE id = ?
            """,
            operation: "更新媒体信息"
        )
        defer { sqlite3_finalize(statement) }
        bindDouble(result.duration, to: 1, in: statement)
        bindInt(result.width, to: 2, in: statement)
        bindInt(result.height, to: 3, in: statement)
        bindOptionalText(result.thumbnailID, to: 4, in: statement)
        bindText(result.metadataStatus.rawValue, to: 5, in: statement)
        bindText(result.thumbnailStatus.rawValue, to: 6, in: statement)
        sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
        bindText(videoID, to: 8, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.statementFailed("更新媒体信息")
        }
        return try fetchVideo(id: videoID)
    }

    func applyScan(
        libraryID: String,
        discoveredVideos: [DiscoveredVideo],
        completedAt: Date = Date()
    ) throws -> [VideoRecord] {
        try prepareIfNeeded()
        let scanID = UUID().uuidString
        try execute("BEGIN IMMEDIATE")

        do {
            let scanStatement = try prepare(
                "INSERT INTO scan_runs (id, library_id, started_at, status) VALUES (?, ?, ?, 'running')",
                operation: "开始扫描"
            )
            bindText(scanID, to: 1, in: scanStatement)
            bindText(libraryID, to: 2, in: scanStatement)
            sqlite3_bind_double(scanStatement, 3, completedAt.timeIntervalSince1970)
            guard sqlite3_step(scanStatement) == SQLITE_DONE else {
                sqlite3_finalize(scanStatement)
                throw DatabaseError.statementFailed("开始扫描")
            }
            sqlite3_finalize(scanStatement)

            let upsertStatement = try prepare(
                """
                INSERT INTO videos (
                    id, library_id, relative_path, volume_identifier, file_resource_identifier,
                    filename, file_extension, file_size, creation_date, modification_date,
                    first_indexed_at, updated_at, last_seen_scan_id, availability_status
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'available')
                ON CONFLICT(library_id, relative_path) DO UPDATE SET
                    volume_identifier = excluded.volume_identifier,
                    file_resource_identifier = excluded.file_resource_identifier,
                    filename = excluded.filename,
                    file_extension = excluded.file_extension,
                    file_size = excluded.file_size,
                    creation_date = excluded.creation_date,
                    modification_date = excluded.modification_date,
                    updated_at = excluded.updated_at,
                    last_seen_scan_id = excluded.last_seen_scan_id,
                    availability_status = 'available'
                """,
                operation: "写入视频索引"
            )
            defer { sqlite3_finalize(upsertStatement) }
            for video in discoveredVideos {
                try upsert(
                    video,
                    libraryID: libraryID,
                    scanID: scanID,
                    indexedAt: completedAt,
                    statement: upsertStatement
                )
            }

            let missingStatement = try prepare(
                """
                UPDATE videos
                SET availability_status = 'missing', updated_at = ?
                WHERE library_id = ? AND (last_seen_scan_id IS NULL OR last_seen_scan_id != ?)
                """,
                operation: "更新失效视频"
            )
            sqlite3_bind_double(missingStatement, 1, completedAt.timeIntervalSince1970)
            bindText(libraryID, to: 2, in: missingStatement)
            bindText(scanID, to: 3, in: missingStatement)
            guard sqlite3_step(missingStatement) == SQLITE_DONE else {
                sqlite3_finalize(missingStatement)
                throw DatabaseError.statementFailed("更新失效视频")
            }
            sqlite3_finalize(missingStatement)

            let finishStatement = try prepare(
                "UPDATE scan_runs SET completed_at = ?, status = 'completed' WHERE id = ?",
                operation: "完成扫描"
            )
            sqlite3_bind_double(finishStatement, 1, completedAt.timeIntervalSince1970)
            bindText(scanID, to: 2, in: finishStatement)
            guard sqlite3_step(finishStatement) == SQLITE_DONE else {
                sqlite3_finalize(finishStatement)
                throw DatabaseError.statementFailed("完成扫描")
            }
            sqlite3_finalize(finishStatement)

            let libraryStatement = try prepare(
                "UPDATE libraries SET last_scan_at = ? WHERE id = ?",
                operation: "更新扫描时间"
            )
            sqlite3_bind_double(libraryStatement, 1, completedAt.timeIntervalSince1970)
            bindText(libraryID, to: 2, in: libraryStatement)
            guard sqlite3_step(libraryStatement) == SQLITE_DONE else {
                sqlite3_finalize(libraryStatement)
                throw DatabaseError.statementFailed("更新扫描时间")
            }
            sqlite3_finalize(libraryStatement)

            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }

        return try fetchVideos(libraryID: libraryID)
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
            do {
                try execute("BEGIN IMMEDIATE")
                try applyMigration(version)
                let statement = try prepare(
                    "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
                    operation: "记录数据库迁移"
                )
                sqlite3_bind_int(statement, 1, Int32(version))
                sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    sqlite3_finalize(statement)
                    throw DatabaseError.migrationFailed(version)
                }
                sqlite3_finalize(statement)
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw DatabaseError.migrationFailed(version)
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
        guard version == 1 else { throw DatabaseError.migrationFailed(version) }

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

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection.handle, sql, nil, nil, &errorMessage)
        sqlite3_free(errorMessage)
        guard result == SQLITE_OK else {
            throw DatabaseError.statementFailed("执行语句")
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql, operation: "读取数据库版本")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.statementFailed("读取数据库版本")
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func prepare(_ sql: String, operation: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.statementFailed(operation)
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
            let availabilityText = text(at: 15, in: statement),
            let availability = VideoRecord.Availability(rawValue: availabilityText)
        else {
            throw DatabaseError.statementFailed("读取视频索引")
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
            availability: availability
        )
    }

    private func upsert(
        _ video: DiscoveredVideo,
        libraryID: String,
        scanID: String,
        indexedAt: Date,
        statement: OpaquePointer
    ) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)

        bindText(UUID().uuidString, to: 1, in: statement)
        bindText(libraryID, to: 2, in: statement)
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
        bindText(scanID, to: 13, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.statementFailed("写入视频索引")
        }
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
