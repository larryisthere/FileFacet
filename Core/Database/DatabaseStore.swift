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
                   tags.sort_order, tags.source, COUNT(DISTINCT video_tags.video_id)
            FROM tags
            LEFT JOIN descendants ON descendants.root_id = tags.id
            LEFT JOIN video_tags ON video_tags.tag_id = descendants.id
            WHERE tags.library_id = ?
            GROUP BY tags.id
            ORDER BY tags.sort_order, tags.name COLLATE NOCASE
            """,
            operation: "读取标签"
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
            else { throw DatabaseError.statementFailed("读取标签") }
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

    @discardableResult
    func createTag(libraryID: String, name: String, parentID: String?, source: String = "user") throws -> String {
        try prepareIfNeeded()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanName.isEmpty == false else { throw DatabaseError.statementFailed("创建标签") }
        try ensureUniqueTagName(cleanName, libraryID: libraryID, parentID: parentID, excludingID: nil)
        let orderStatement = try prepare(
            "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM tags WHERE library_id = ? AND parent_id IS ?",
            operation: "创建标签"
        )
        bindText(libraryID, to: 1, in: orderStatement)
        bindOptionalText(parentID, to: 2, in: orderStatement)
        guard sqlite3_step(orderStatement) == SQLITE_ROW else {
            sqlite3_finalize(orderStatement)
            throw DatabaseError.statementFailed("创建标签")
        }
        let sortOrder = sqlite3_column_int(orderStatement, 0)
        sqlite3_finalize(orderStatement)

        let statement = try prepare(
            """
            INSERT INTO tags (id, library_id, name, normalized_name, parent_id, color,
                              sort_order, source, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, ?)
            """,
            operation: "创建标签"
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
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.statementFailed("创建标签") }
        return id
    }

    func renameTag(id: String, name: String) throws {
        try prepareIfNeeded()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanName.isEmpty == false else { throw DatabaseError.statementFailed("重命名标签") }
        let lookup = try prepare("SELECT library_id, parent_id FROM tags WHERE id = ?", operation: "重命名标签")
        bindText(id, to: 1, in: lookup)
        guard sqlite3_step(lookup) == SQLITE_ROW, let libraryID = text(at: 0, in: lookup) else {
            sqlite3_finalize(lookup)
            throw DatabaseError.statementFailed("重命名标签")
        }
        let parentID = text(at: 1, in: lookup)
        sqlite3_finalize(lookup)
        try ensureUniqueTagName(cleanName, libraryID: libraryID, parentID: parentID, excludingID: id)
        let statement = try prepare(
            "UPDATE tags SET name = ?, normalized_name = ?, updated_at = ? WHERE id = ?",
            operation: "重命名标签"
        )
        defer { sqlite3_finalize(statement) }
        bindText(cleanName, to: 1, in: statement)
        bindText(normalizedTagName(cleanName), to: 2, in: statement)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        bindText(id, to: 4, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.statementFailed("重命名标签") }
    }

    func setTagColor(id: String, color: String?) throws {
        try prepareIfNeeded()
        let statement = try prepare("UPDATE tags SET color = ?, updated_at = ? WHERE id = ?", operation: "设置标签颜色")
        defer { sqlite3_finalize(statement) }
        bindOptionalText(color, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        bindText(id, to: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.statementFailed("设置标签颜色") }
    }

    func deleteTag(id: String) throws {
        try prepareIfNeeded()
        let statement = try prepare("DELETE FROM tags WHERE id = ?", operation: "删除标签")
        defer { sqlite3_finalize(statement) }
        bindText(id, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.statementFailed("删除标签") }
    }

    func moveTag(id: String, parentID: String?, sortOrder: Int) throws {
        try prepareIfNeeded()
        guard id != parentID else { throw DatabaseError.statementFailed("移动标签") }
        if let parentID {
            let cycle = try prepare(
                """
                WITH RECURSIVE descendants(id) AS (
                    SELECT id FROM tags WHERE parent_id = ?
                    UNION ALL SELECT tags.id FROM tags JOIN descendants ON tags.parent_id = descendants.id
                ) SELECT 1 FROM descendants WHERE id = ? LIMIT 1
                """,
                operation: "移动标签"
            )
            bindText(id, to: 1, in: cycle)
            bindText(parentID, to: 2, in: cycle)
            let createsCycle = sqlite3_step(cycle) == SQLITE_ROW
            sqlite3_finalize(cycle)
            guard createsCycle == false else { throw DatabaseError.statementFailed("移动标签") }
        }
        let statement = try prepare(
            "UPDATE tags SET parent_id = ?, sort_order = ?, updated_at = ? WHERE id = ?",
            operation: "移动标签"
        )
        defer { sqlite3_finalize(statement) }
        bindOptionalText(parentID, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, Int64(sortOrder))
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        bindText(id, to: 4, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.statementFailed("移动标签") }
    }

    func mergeTag(sourceID: String, targetID: String) throws {
        try prepareIfNeeded()
        guard sourceID != targetID else { return }
        guard try isTag(targetID, descendantOf: sourceID) == false else {
            throw DatabaseError.statementFailed("合并标签")
        }
        try execute("BEGIN IMMEDIATE")
        do {
            let relations = try prepare(
                "INSERT OR IGNORE INTO video_tags (video_id, tag_id, created_at) SELECT video_id, ?, created_at FROM video_tags WHERE tag_id = ?",
                operation: "合并标签"
            )
            bindText(targetID, to: 1, in: relations)
            bindText(sourceID, to: 2, in: relations)
            guard sqlite3_step(relations) == SQLITE_DONE else { sqlite3_finalize(relations); throw DatabaseError.statementFailed("合并标签") }
            sqlite3_finalize(relations)
            let children = try prepare("UPDATE tags SET parent_id = ? WHERE parent_id = ?", operation: "合并标签")
            bindText(targetID, to: 1, in: children)
            bindText(sourceID, to: 2, in: children)
            guard sqlite3_step(children) == SQLITE_DONE else { sqlite3_finalize(children); throw DatabaseError.statementFailed("合并标签") }
            sqlite3_finalize(children)
            let mappings = try prepare("UPDATE finder_tag_import_mappings SET tag_id = ? WHERE tag_id = ?", operation: "合并标签")
            bindText(targetID, to: 1, in: mappings)
            bindText(sourceID, to: 2, in: mappings)
            guard sqlite3_step(mappings) == SQLITE_DONE else { sqlite3_finalize(mappings); throw DatabaseError.statementFailed("合并标签") }
            sqlite3_finalize(mappings)
            try deleteTag(id: sourceID)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func setTagAssignment(tagID: String, videoIDs: [String], enabled: Bool) throws {
        try prepareIfNeeded()
        guard videoIDs.isEmpty == false else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            if enabled {
                let statement = try prepare(
                    "INSERT OR IGNORE INTO video_tags (video_id, tag_id, created_at) VALUES (?, ?, ?)",
                    operation: "添加标签"
                )
                defer { sqlite3_finalize(statement) }
                for videoID in videoIDs {
                    sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                    bindText(videoID, to: 1, in: statement)
                    bindText(tagID, to: 2, in: statement)
                    sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.statementFailed("添加标签") }
                }
            } else {
                let placeholders = Array(repeating: "?", count: videoIDs.count).joined(separator: ",")
                let statement = try prepare(
                    "DELETE FROM video_tags WHERE tag_id = ? AND video_id IN (\(placeholders))",
                    operation: "移除标签"
                )
                defer { sqlite3_finalize(statement) }
                bindText(tagID, to: 1, in: statement)
                for (index, videoID) in videoIDs.enumerated() { bindText(videoID, to: Int32(index + 2), in: statement) }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.statementFailed("移除标签") }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func tagAssignmentStates(videoIDs: [String], tags: [TagRecord]) throws -> [String: TagAssignmentState] {
        try prepareIfNeeded()
        guard videoIDs.isEmpty == false else { return [:] }
        let placeholders = Array(repeating: "?", count: videoIDs.count).joined(separator: ",")
        let statement = try prepare(
            "SELECT tag_id, COUNT(DISTINCT video_id) FROM video_tags WHERE video_id IN (\(placeholders)) GROUP BY tag_id",
            operation: "读取视频标签"
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
            """,
            operation: "读取标签状态"
        )
        defer { sqlite3_finalize(statement) }
        bindText(libraryID, to: 1, in: statement)
        var relations: [VideoTagRelation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let videoID = text(at: 0, in: statement), let tagID = text(at: 1, in: statement) {
                relations.append(VideoTagRelation(videoID: videoID, tagID: tagID))
            }
        }
        return TagStateSnapshot(libraryID: libraryID, tags: tags, relations: relations)
    }

    func restoreTagState(_ snapshot: TagStateSnapshot) throws {
        try prepareIfNeeded()
        try execute("BEGIN IMMEDIATE")
        do {
            let delete = try prepare("DELETE FROM tags WHERE library_id = ?", operation: "恢复标签状态")
            bindText(snapshot.libraryID, to: 1, in: delete)
            guard sqlite3_step(delete) == SQLITE_DONE else { sqlite3_finalize(delete); throw DatabaseError.statementFailed("恢复标签状态") }
            sqlite3_finalize(delete)

            var pending = snapshot.tags
            var inserted = Set<String>()
            while pending.isEmpty == false {
                let ready = pending.filter { $0.parentID == nil || inserted.contains($0.parentID!) }
                guard ready.isEmpty == false else { throw DatabaseError.statementFailed("恢复标签状态") }
                for tag in ready {
                    let statement = try prepare(
                        """
                        INSERT INTO tags (id, library_id, name, normalized_name, parent_id, color,
                                          sort_order, source, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        operation: "恢复标签状态"
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
                    guard sqlite3_step(statement) == SQLITE_DONE else { sqlite3_finalize(statement); throw DatabaseError.statementFailed("恢复标签状态") }
                    sqlite3_finalize(statement)
                    inserted.insert(tag.id)
                }
                let readyIDs = Set(ready.map(\.id))
                pending.removeAll { readyIDs.contains($0.id) }
            }
            let relationStatement = try prepare(
                "INSERT OR IGNORE INTO video_tags (video_id, tag_id, created_at) VALUES (?, ?, ?)",
                operation: "恢复标签状态"
            )
            defer { sqlite3_finalize(relationStatement) }
            for relation in snapshot.relations {
                sqlite3_reset(relationStatement); sqlite3_clear_bindings(relationStatement)
                bindText(relation.videoID, to: 1, in: relationStatement)
                bindText(relation.tagID, to: 2, in: relationStatement)
                sqlite3_bind_double(relationStatement, 3, Date().timeIntervalSince1970)
                guard sqlite3_step(relationStatement) == SQLITE_DONE else { throw DatabaseError.statementFailed("恢复标签状态") }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
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
            """,
            operation: "检查标签名称"
        )
        defer { sqlite3_finalize(statement) }
        bindText(libraryID, to: 1, in: statement)
        bindOptionalText(parentID, to: 2, in: statement)
        bindText(normalizedTagName(name), to: 3, in: statement)
        bindOptionalText(excludingID, to: 4, in: statement)
        bindOptionalText(excludingID, to: 5, in: statement)
        guard sqlite3_step(statement) != SQLITE_ROW else {
            throw DatabaseError.statementFailed("标签名称重复")
        }
    }

    private func isTag(_ candidateID: String, descendantOf tagID: String) throws -> Bool {
        let statement = try prepare(
            """
            WITH RECURSIVE descendants(id) AS (
                SELECT id FROM tags WHERE parent_id = ?
                UNION ALL SELECT tags.id FROM tags JOIN descendants ON tags.parent_id = descendants.id
            ) SELECT 1 FROM descendants WHERE id = ? LIMIT 1
            """,
            operation: "检查标签层级"
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
