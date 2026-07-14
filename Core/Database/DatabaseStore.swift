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
