import XCTest
import SQLite3
@testable import Tagivy

final class DatabaseStoreTests: XCTestCase {
    func testMigrationCreatesCurrentSchema() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }

        let store = try DatabaseStore(databaseURL: fixture.databaseURL)

        let schemaVersion = try await store.schemaVersion()

        XCTAssertEqual(schemaVersion, DatabaseStore.currentSchemaVersion)
    }

    func testVersionTwoMigrationPreservesVideosAndTagRelations() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        try executeSQL(
            at: fixture.databaseURL,
            sql: """
            PRAGMA foreign_keys = ON;
            CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);
            INSERT INTO schema_migrations VALUES (1, 1), (2, 2);
            CREATE TABLE libraries (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, root_bookmark_data BLOB NOT NULL,
                created_at REAL NOT NULL, last_scan_at REAL, last_fsevent_id INTEGER
            );
            CREATE TABLE scan_runs (
                id TEXT PRIMARY KEY, library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
                started_at REAL NOT NULL, completed_at REAL, status TEXT NOT NULL
            );
            CREATE TABLE videos (
                id TEXT PRIMARY KEY, library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
                relative_path TEXT NOT NULL, volume_identifier BLOB, file_resource_identifier BLOB,
                filename TEXT NOT NULL, file_extension TEXT NOT NULL, file_size INTEGER NOT NULL,
                creation_date REAL, modification_date REAL, duration REAL, width INTEGER, height INTEGER,
                thumbnail_id TEXT, metadata_status TEXT NOT NULL DEFAULT 'pending',
                thumbnail_status TEXT NOT NULL DEFAULT 'pending', availability_status TEXT NOT NULL DEFAULT 'available',
                first_indexed_at REAL NOT NULL, updated_at REAL NOT NULL,
                last_seen_scan_id TEXT REFERENCES scan_runs(id), UNIQUE(library_id, relative_path)
            );
            CREATE TABLE tags (
                id TEXT PRIMARY KEY, library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
                name TEXT NOT NULL, normalized_name TEXT NOT NULL, parent_id TEXT REFERENCES tags(id) ON DELETE CASCADE,
                color TEXT, sort_order INTEGER NOT NULL, source TEXT NOT NULL,
                created_at REAL NOT NULL, updated_at REAL NOT NULL,
                UNIQUE(library_id, parent_id, normalized_name)
            );
            CREATE TABLE video_tags (
                video_id TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
                tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                created_at REAL NOT NULL, PRIMARY KEY(video_id, tag_id)
            );
            CREATE TABLE finder_tag_import_mappings (
                library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
                external_key TEXT NOT NULL, tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                first_imported_at REAL NOT NULL, last_seen_at REAL NOT NULL,
                PRIMARY KEY(library_id, external_key)
            );
            INSERT INTO libraries VALUES ('primary', 'Videos', X'01', 1, NULL, NULL);
            INSERT INTO videos (
                id, library_id, relative_path, filename, file_extension, file_size,
                metadata_status, thumbnail_status, availability_status, first_indexed_at, updated_at
            ) VALUES ('video-1', 'primary', 'A.mp4', 'A.mp4', 'mp4', 10, 'completed', 'completed', 'available', 1, 1);
            INSERT INTO tags VALUES ('tag-1', 'primary', '保留', '保留', NULL, NULL, 0, 'user', 1, 1);
            INSERT INTO video_tags VALUES ('video-1', 'tag-1', 1);
            """
        )

        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        let version = try await store.schemaVersion()
        let videos = try await store.fetchVideos(libraryID: LibraryRecord.primaryID)
        let sources = try await store.fetchSourceAuthorizations()
        let locations = try await store.fetchVideoLocations()
        let tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        let states = try await store.tagAssignmentStates(videoIDs: videos.map(\.id), tags: tags)

        XCTAssertEqual(version, DatabaseStore.currentSchemaVersion)
        XCTAssertEqual(videos.map(\.id), ["video-1"])
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(locations.map(\.videoID), ["video-1"])
        XCTAssertEqual(states["tag-1"], .on)
    }

    func testPrimaryLibraryRoundTrip() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        let record = LibraryRecord(
            id: LibraryRecord.primaryID,
            name: "Videos",
            rootBookmarkData: Data([0x01, 0x02, 0x03]),
            createdAt: Date(timeIntervalSince1970: 100),
            lastScanAt: nil
        )

        try await store.saveLibrary(record)

        let savedRecord = try await store.fetchPrimaryLibrary()

        XCTAssertEqual(savedRecord, record)
    }

    func testRepeatedManualImportKeepsVideosOutsideCurrentSelection() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        let firstImportDate = Date(timeIntervalSince1970: 200)

        let firstResult = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [
                makeDiscoveredVideo(path: "A.mp4", size: 10),
                makeDiscoveredVideo(path: "Folder/B.mov", size: 20),
            ],
            completedAt: firstImportDate
        )
        let firstA = try XCTUnwrap(firstResult.first { $0.relativePath == "A.mp4" })

        let secondResult = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [makeDiscoveredVideo(path: "A.mp4", size: 30)],
            completedAt: Date(timeIntervalSince1970: 300)
        )
        let secondA = try XCTUnwrap(secondResult.first { $0.relativePath == "A.mp4" })
        let allRecords = try await store.fetchVideos(
            libraryID: LibraryRecord.primaryID,
            includeMissing: true
        )
        let preservedB = try XCTUnwrap(allRecords.first { $0.relativePath == "Folder/B.mov" })

        XCTAssertEqual(secondResult.count, 2)
        XCTAssertEqual(secondA.id, firstA.id)
        XCTAssertEqual(secondA.firstIndexedAt, firstImportDate)
        XCTAssertEqual(secondA.fileSize, 30)
        XCTAssertEqual(preservedB.availability, .available)
    }

    func testMediaProcessingResultPersists() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        let records = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [makeDiscoveredVideo(path: "A.mp4", size: 10)]
        )
        let video = try XCTUnwrap(records.first)

        let updated = try await store.updateMediaInfo(
            videoID: video.id,
            result: MediaProcessingResult(
                duration: 12.5,
                width: 1920,
                height: 1080,
                thumbnailID: video.id,
                metadataStatus: .completed,
                thumbnailStatus: .completed
            )
        )

        XCTAssertEqual(updated?.duration, 12.5)
        XCTAssertEqual(updated?.width, 1920)
        XCTAssertEqual(updated?.height, 1080)
        XCTAssertEqual(updated?.thumbnailID, video.id)
        XCTAssertEqual(updated?.metadataStatus, .completed)
        XCTAssertEqual(updated?.thumbnailStatus, .completed)
    }

    func testHierarchicalTagsRejectDuplicatesAndCyclesAndCountDescendants() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        let videos = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [makeDiscoveredVideo(path: "A.mp4", size: 10)]
        )
        let parentID = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "工作", parentID: nil)
        let childID = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "客户", parentID: parentID)
        try await store.setTagAssignment(tagID: childID, videoIDs: videos.map(\.id), enabled: true)

        do {
            _ = try await store.createTag(libraryID: LibraryRecord.primaryID, name: " 工作 ", parentID: nil)
            XCTFail("同层级规范化重名应被拒绝")
        } catch {}
        do {
            try await store.moveTag(id: parentID, parentID: childID, sortOrder: 0)
            XCTFail("将父标签移到后代下应被拒绝")
        } catch {}

        let tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        XCTAssertEqual(tags.first(where: { $0.id == parentID })?.videoCount, 1)
        XCTAssertEqual(tags.first(where: { $0.id == childID })?.videoCount, 1)
    }

    func testBatchAssignmentStatesAndMergePreserveRelationsAndChildren() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        let videos = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [
                makeDiscoveredVideo(path: "A.mp4", size: 10),
                makeDiscoveredVideo(path: "B.mp4", size: 20),
            ]
        )
        let sourceID = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "来源", parentID: nil)
        let targetID = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "目标", parentID: nil)
        let childID = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "子项", parentID: sourceID)
        try await store.setTagAssignment(tagID: sourceID, videoIDs: [videos[0].id], enabled: true)

        var tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        var states = try await store.tagAssignmentStates(videoIDs: videos.map(\.id), tags: tags)
        XCTAssertEqual(states[sourceID], .mixed)
        XCTAssertEqual(states[targetID], .off)

        try await store.setTagAssignment(tagID: sourceID, videoIDs: videos.map(\.id), enabled: true)
        tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        states = try await store.tagAssignmentStates(videoIDs: videos.map(\.id), tags: tags)
        XCTAssertEqual(states[sourceID], .on)

        try await store.mergeTag(sourceID: sourceID, targetID: targetID)
        tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        states = try await store.tagAssignmentStates(videoIDs: videos.map(\.id), tags: tags)
        XCTAssertNil(tags.first(where: { $0.id == sourceID }))
        XCTAssertEqual(tags.first(where: { $0.id == childID })?.parentID, targetID)
        XCTAssertEqual(states[targetID], .on)
    }

    func testMovingTagKeepsSiblingOrderContiguous() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        let first = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "一", parentID: nil)
        let second = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "二", parentID: nil)
        let third = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "三", parentID: nil)

        try await store.moveTag(id: third, parentID: nil, sortOrder: 0)

        let userTags = try await store.fetchTags(libraryID: LibraryRecord.primaryID).filter { $0.source == "user" }
        XCTAssertEqual(userTags.map(\.id), [third, first, second])
        XCTAssertEqual(userTags.map(\.sortOrder), [0, 1, 2])
    }

    func testDeletingParentRemovesSubtreeAndSnapshotRestoresTagState() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        let videos = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [makeDiscoveredVideo(path: "A.mp4", size: 10)]
        )
        let parentID = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "父级", parentID: nil)
        let childID = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "子级", parentID: parentID)
        try await store.setTagAssignment(tagID: childID, videoIDs: videos.map(\.id), enabled: true)
        let snapshot = try await store.captureTagState(libraryID: LibraryRecord.primaryID)

        try await store.deleteTag(id: parentID)
        let afterDelete = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        XCTAssertNil(afterDelete.first(where: { $0.id == parentID || $0.id == childID }))

        try await store.restoreTagState(snapshot)
        let restored = try await store.captureTagState(libraryID: LibraryRecord.primaryID)
        XCTAssertEqual(Set(restored.tags.map(\.id)), Set(snapshot.tags.map(\.id)))
        XCTAssertEqual(restored.relations, snapshot.relations)
    }

    func testVideoFiltersSupportSearchRecencyUntaggedAndTagIntersection() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        let oldDate = Date(timeIntervalSince1970: 1_000)
        _ = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [
                makeDiscoveredVideo(path: "Alpha.mp4", size: 10),
                makeDiscoveredVideo(path: "Beta.mov", size: 20),
            ],
            completedAt: oldDate
        )
        let now = Date(timeIntervalSince1970: 4_000_000)
        let current = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [
                makeDiscoveredVideo(path: "Alpha.mp4", size: 10),
                makeDiscoveredVideo(path: "Gamma.mkv", size: 30),
            ],
            completedAt: now
        )
        let alpha = try XCTUnwrap(current.first(where: { $0.filename == "Alpha.mp4" }))
        let gamma = try XCTUnwrap(current.first(where: { $0.filename == "Gamma.mkv" }))
        let parentID = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "父级筛选", parentID: nil)
        let childID = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "子级筛选", parentID: parentID)
        let secondID = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "第二条件", parentID: nil)
        try await store.setTagAssignment(tagID: childID, videoIDs: [alpha.id, gamma.id], enabled: true)
        try await store.setTagAssignment(tagID: secondID, videoIDs: [gamma.id], enabled: true)

        let searched = try await store.fetchVideos(
            libraryID: LibraryRecord.primaryID,
            query: LibraryQueryRequest(
                baseFilter: .all,
                temporaryFilenameSearch: "ALPHA",
                rule: .standard
            ),
            now: now
        )
        let recent = try await store.fetchVideos(
            libraryID: LibraryRecord.primaryID,
            query: LibraryQueryRequest(
                baseFilter: .recent,
                temporaryFilenameSearch: "",
                rule: .standard
            ),
            now: now
        )
        let untagged = try await store.fetchVideos(
            libraryID: LibraryRecord.primaryID,
            query: LibraryQueryRequest(
                baseFilter: .untagged,
                temporaryFilenameSearch: "",
                rule: .standard
            ),
            now: now
        )
        let inherited = try await store.fetchVideos(
            libraryID: LibraryRecord.primaryID,
            query: LibraryQueryRequest(
                baseFilter: .tag(parentID),
                temporaryFilenameSearch: "",
                rule: .standard
            ),
            now: now
        )
        let intersection = try await store.fetchVideos(
            libraryID: LibraryRecord.primaryID,
            query: LibraryQueryRequest(
                baseFilter: .tags([parentID, secondID]),
                temporaryFilenameSearch: "",
                rule: .standard
            ),
            now: now
        )

        XCTAssertEqual(searched.map(\.filename), ["Alpha.mp4"])
        XCTAssertEqual(recent.map(\.filename), ["Gamma.mkv"])
        XCTAssertEqual(untagged.map(\.filename), ["Beta.mov"])
        XCTAssertEqual(Set(inherited.map(\.filename)), Set(["Alpha.mp4", "Gamma.mkv"]))
        XCTAssertEqual(intersection.map(\.filename), ["Gamma.mkv"])
    }

    func testFinderTagImportRunsOncePerVideoAndKeepsExistingAssignments() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        var video = makeDiscoveredVideo(path: "A.mp4", size: 10, finderTags: ["红色"])
        let firstVideos = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [video]
        )
        _ = try await store.importTestVideos(libraryID: LibraryRecord.primaryID, discoveredVideos: [video])
        var tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        let imported = try XCTUnwrap(tags.first(where: { $0.source == "finder" }))
        XCTAssertNil(imported.parentID)
        XCTAssertFalse(tags.contains(where: { $0.source == "finder-root" }))
        XCTAssertEqual(tags.filter { $0.source == "finder" }.count, 1)
        var states = try await store.tagAssignmentStates(videoIDs: firstVideos.map(\.id), tags: tags)
        XCTAssertEqual(states[imported.id], .on)

        video = makeDiscoveredVideo(path: "A.mp4", size: 10, finderTags: [])
        _ = try await store.importTestVideos(libraryID: LibraryRecord.primaryID, discoveredVideos: [video])
        tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        states = try await store.tagAssignmentStates(videoIDs: firstVideos.map(\.id), tags: tags)
        XCTAssertEqual(states[imported.id], .on)
    }

    func testFolderTagImportExcludesRootAndPreservesExistingAssignments() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        try await store.saveSourceAuthorization(makeSource(id: "source-a", name: "Travel"))
        let discovered = [
            makeDiscoveredVideo(path: "Root.mp4", size: 10),
            makeDiscoveredVideo(path: "Japan/Tokyo/Clip.mp4", size: 20, finderTags: ["Finder"]),
        ]
        let initial = try await store.importVideos(
            sourceID: "source-a",
            discoveredVideos: discovered
        )
        let nestedVideo = try XCTUnwrap(
            initial.importedVideos.first(where: { $0.filename == "Clip.mp4" })
        )
        let userTagID = try await store.createTag(
            libraryID: LibraryRecord.primaryID,
            name: "Existing",
            parentID: nil
        )
        try await store.setTagAssignment(
            tagID: userTagID,
            videoIDs: [nestedVideo.id],
            enabled: true
        )

        let folderImport = try await store.importVideos(
            sourceID: "source-a",
            discoveredVideos: discovered,
            folderTagOptions: FolderTagImportOptions(selectedRootName: nil)
        )
        let repeatedImport = try await store.importVideos(
            sourceID: "source-a",
            discoveredVideos: discovered,
            folderTagOptions: FolderTagImportOptions(selectedRootName: nil)
        )

        let videos = try await store.fetchVideos(libraryID: LibraryRecord.primaryID)
        let tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        let japan = try XCTUnwrap(tags.first(where: { $0.name == "Japan" }))
        let tokyo = try XCTUnwrap(tags.first(where: { $0.name == "Tokyo" }))
        let finder = try XCTUnwrap(tags.first(where: { $0.name == "Finder" }))
        let rootVideo = try XCTUnwrap(videos.first(where: { $0.filename == "Root.mp4" }))
        let nestedStates = try await store.tagAssignmentStates(
            videoIDs: [nestedVideo.id],
            tags: tags
        )
        let rootStates = try await store.tagAssignmentStates(
            videoIDs: [rootVideo.id],
            tags: tags
        )

        XCTAssertEqual(folderImport.existingCount, 2)
        XCTAssertEqual(folderImport.createdFolderTagIDs.count, 2)
        XCTAssertTrue(repeatedImport.createdFolderTagIDs.isEmpty)
        XCTAssertEqual(videos.count, 2)
        XCTAssertEqual(tokyo.parentID, japan.id)
        XCTAssertEqual(japan.videoCount, 1)
        XCTAssertEqual(tokyo.videoCount, 1)
        XCTAssertEqual(nestedStates[japan.id], .off)
        XCTAssertEqual(nestedStates[tokyo.id], .on)
        XCTAssertEqual(nestedStates[finder.id], .on)
        XCTAssertEqual(nestedStates[userTagID], .on)
        XCTAssertEqual(rootStates[japan.id], .off)
        XCTAssertEqual(rootStates[tokyo.id], .off)
    }

    func testFolderTagImportIncludesSelectedRootForDirectVideos() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        try await store.saveSourceAuthorization(makeSource(id: "source-a", name: "Travel"))
        let result = try await store.importVideos(
            sourceID: "source-a",
            discoveredVideos: [
                makeDiscoveredVideo(path: "Root.mp4", size: 10),
                makeDiscoveredVideo(path: "Japan/Tokyo/Clip.mp4", size: 20),
            ],
            folderTagOptions: FolderTagImportOptions(selectedRootName: "Travel")
        )

        let tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        let travel = try XCTUnwrap(tags.first(where: { $0.name == "Travel" }))
        let japan = try XCTUnwrap(tags.first(where: { $0.name == "Japan" }))
        let tokyo = try XCTUnwrap(tags.first(where: { $0.name == "Tokyo" }))
        let rootVideo = try XCTUnwrap(
            result.importedVideos.first(where: { $0.filename == "Root.mp4" })
        )
        let nestedVideo = try XCTUnwrap(
            result.importedVideos.first(where: { $0.filename == "Clip.mp4" })
        )
        let rootStates = try await store.tagAssignmentStates(
            videoIDs: [rootVideo.id],
            tags: tags
        )
        let nestedStates = try await store.tagAssignmentStates(
            videoIDs: [nestedVideo.id],
            tags: tags
        )

        XCTAssertEqual(result.createdFolderTagIDs.count, 3)
        XCTAssertNil(travel.parentID)
        XCTAssertEqual(japan.parentID, travel.id)
        XCTAssertEqual(tokyo.parentID, japan.id)
        XCTAssertEqual(travel.videoCount, 2)
        XCTAssertEqual(rootStates[travel.id], .on)
        XCTAssertEqual(rootStates[tokyo.id], .off)
        XCTAssertEqual(nestedStates[travel.id], .off)
        XCTAssertEqual(nestedStates[tokyo.id], .on)
    }

    func testFolderTagImportReusesNormalizedSiblingsAcrossPaths() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        try await store.saveSourceAuthorization(makeSource(id: "source-a", name: "Source"))

        _ = try await store.importVideos(
            sourceID: "source-a",
            discoveredVideos: [
                makeDiscoveredVideo(path: "Japan/Tokyo/A.mp4", size: 10),
                makeDiscoveredVideo(path: "JAPAN/Tokyó/B.mp4", size: 20),
                makeDiscoveredVideo(path: "Work/Tokyo/C.mp4", size: 30),
            ],
            folderTagOptions: FolderTagImportOptions(selectedRootName: nil)
        )

        let tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        let japan = try XCTUnwrap(
            tags.first { $0.name.localizedCaseInsensitiveCompare("Japan") == .orderedSame }
        )
        let work = try XCTUnwrap(tags.first(where: { $0.name == "Work" }))
        let tokyoTags = tags.filter {
            $0.name.compare(
                "Tokyo",
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }

        XCTAssertEqual(tags.count, 4)
        XCTAssertEqual(tokyoTags.count, 2)
        XCTAssertEqual(Set(tokyoTags.compactMap(\.parentID)), Set([japan.id, work.id]))
        XCTAssertEqual(japan.videoCount, 2)
        XCTAssertEqual(work.videoCount, 1)
    }

    func testFolderTagImportHandlesDeepHierarchyIteratively() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        try await store.saveSourceAuthorization(makeSource(id: "source-a", name: "Source"))
        let components = (0..<128).map { String(format: "Level-%03d", $0) }

        let result = try await store.importVideos(
            sourceID: "source-a",
            discoveredVideos: [
                makeDiscoveredVideo(
                    path: components.joined(separator: "/") + "/Deep.mp4",
                    size: 10
                ),
            ],
            folderTagOptions: FolderTagImportOptions(selectedRootName: nil)
        )

        let video = try XCTUnwrap(result.importedVideos.first)
        let tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        let first = try XCTUnwrap(tags.first(where: { $0.name == components[0] }))
        let leaf = try XCTUnwrap(tags.first(where: { $0.name == components[components.count - 1] }))
        let states = try await store.tagAssignmentStates(videoIDs: [video.id], tags: tags)

        XCTAssertEqual(result.createdFolderTagIDs.count, components.count)
        XCTAssertEqual(tags.count, components.count)
        XCTAssertEqual(first.videoCount, 1)
        XCTAssertEqual(leaf.videoCount, 1)
        XCTAssertEqual(states[first.id], .off)
        XCTAssertEqual(states[leaf.id], .on)
    }

    func testRestoredTagSnapshotKeepsFinderMappingForNewVideos() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        _ = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [makeDiscoveredVideo(path: "A.mp4", size: 10, finderTags: ["红色"])]
        )
        let snapshot = try await store.captureTagState(libraryID: LibraryRecord.primaryID)
        let finderTag = try XCTUnwrap(snapshot.tags.first(where: { $0.source == "finder" }))
        try await store.deleteTag(id: finderTag.id)

        try await store.restoreTagState(snapshot)
        let videos = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [
                makeDiscoveredVideo(path: "A.mp4", size: 10),
                makeDiscoveredVideo(path: "B.mp4", size: 20, finderTags: ["红色"]),
            ]
        )

        let tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        let importedTags = tags.filter { $0.source == "finder" }
        let newVideo = try XCTUnwrap(videos.first(where: { $0.filename == "B.mp4" }))
        let states = try await store.tagAssignmentStates(videoIDs: [newVideo.id], tags: tags)
        XCTAssertEqual(importedTags.count, 1)
        XCTAssertEqual(states[importedTags[0].id], .on)
    }

    func testSamePathWithDifferentFileIdentityCreatesNewVideo() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        let volume = Data("volume".utf8)
        let original = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [makeDiscoveredVideo(
                path: "A.mp4",
                size: 10,
                volumeIdentifier: volume,
                fileResourceIdentifier: Data("old".utf8)
            )]
        )
        let originalVideo = try XCTUnwrap(original.first)
        let tagID = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "旧视频标签", parentID: nil)
        try await store.setTagAssignment(tagID: tagID, videoIDs: [originalVideo.id], enabled: true)

        let replacement = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [makeDiscoveredVideo(
                path: "A.mp4",
                size: 20,
                volumeIdentifier: volume,
                fileResourceIdentifier: Data("new".utf8)
            )]
        )

        let replacementVideo = try XCTUnwrap(replacement.first)
        let allVideos = try await store.fetchVideos(libraryID: LibraryRecord.primaryID, includeMissing: true)
        let tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        let replacementStates = try await store.tagAssignmentStates(videoIDs: [replacementVideo.id], tags: tags)
        XCTAssertNotEqual(replacementVideo.id, originalVideo.id)
        XCTAssertNil(allVideos.first(where: { $0.id == originalVideo.id }))
        XCTAssertEqual(replacementStates[tagID], .off)
    }

    func testModifiedVideoResetsMediaInformationForRegeneration() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        let identity = Data("identity".utf8)
        let volume = Data("volume".utf8)
        let original = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [makeDiscoveredVideo(
                path: "A.mp4",
                size: 10,
                modificationDate: Date(timeIntervalSince1970: 100),
                volumeIdentifier: volume,
                fileResourceIdentifier: identity
            )]
        )
        let video = try XCTUnwrap(original.first)
        _ = try await store.updateMediaInfo(
            videoID: video.id,
            result: MediaProcessingResult(
                duration: 12,
                width: 1920,
                height: 1080,
                thumbnailID: video.id,
                metadataStatus: .completed,
                thumbnailStatus: .completed
            )
        )

        let reimported = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [makeDiscoveredVideo(
                path: "A.mp4",
                size: 11,
                modificationDate: Date(timeIntervalSince1970: 200),
                volumeIdentifier: volume,
                fileResourceIdentifier: identity
            )]
        )

        let updated = try XCTUnwrap(reimported.first)
        XCTAssertEqual(updated.id, video.id)
        XCTAssertNil(updated.duration)
        XCTAssertNil(updated.thumbnailID)
        XCTAssertEqual(updated.metadataStatus, .pending)
        XCTAssertEqual(updated.thumbnailStatus, .pending)
    }

    func testRenameByFileIdentityPreservesVideoIDAndTags() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        let identity = Data("file-id".utf8)
        let volume = Data("volume-id".utf8)
        let original = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [makeDiscoveredVideo(path: "Old.mp4", size: 10, volumeIdentifier: volume, fileResourceIdentifier: identity)]
        )
        let tagID = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "保留", parentID: nil)
        try await store.setTagAssignment(tagID: tagID, videoIDs: original.map(\.id), enabled: true)

        let moved = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [makeDiscoveredVideo(path: "Folder/New.mp4", size: 11, volumeIdentifier: volume, fileResourceIdentifier: identity)]
        )
        let tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        let states = try await store.tagAssignmentStates(videoIDs: moved.map(\.id), tags: tags)

        XCTAssertEqual(moved.first?.id, original.first?.id)
        XCTAssertEqual(moved.first?.relativePath, "Folder/New.mp4")
        XCTAssertEqual(states[tagID], .on)
    }

    func testManualImportsAcrossSourcesAreGloballyIdempotent() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        try await store.saveSourceAuthorization(makeSource(id: "source-a", name: "A"))
        try await store.saveSourceAuthorization(makeSource(id: "source-b", name: "B"))
        let volume = Data("volume".utf8)
        let identity = Data("same-file".utf8)

        let first = try await store.importVideos(
            sourceID: "source-a",
            discoveredVideos: [makeDiscoveredVideo(
                path: "Original.mp4",
                size: 10,
                finderTags: ["旅行"],
                volumeIdentifier: volume,
                fileResourceIdentifier: identity
            )]
        )
        let second = try await store.importVideos(
            sourceID: "source-b",
            discoveredVideos: [makeDiscoveredVideo(
                path: "Nested/Original.mp4",
                size: 10,
                finderTags: ["工作"],
                volumeIdentifier: volume,
                fileResourceIdentifier: identity
            )]
        )

        let videos = try await store.fetchVideos(libraryID: LibraryRecord.primaryID)
        let locations = try await store.fetchVideoLocations()
        let tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        XCTAssertEqual(first.addedCount, 1)
        XCTAssertEqual(second.existingCount, 1)
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(locations.count, 2)
        XCTAssertEqual(tags.filter { $0.source == "finder" }.map(\.name), ["旅行"])
    }

    func testSilentMaintenanceUpdatesMovedVideoAndRetainsConfirmedMissingRecord() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        try await store.saveSourceAuthorization(makeSource(id: "source-a", name: "A"))
        let volume = Data("volume".utf8)
        let identity = Data("moving-file".utf8)
        let imported = try await store.importVideos(
            sourceID: "source-a",
            discoveredVideos: [makeDiscoveredVideo(
                path: "Old.mp4",
                size: 10,
                volumeIdentifier: volume,
                fileResourceIdentifier: identity
            )],
            importedAt: Date(timeIntervalSince1970: 100)
        )
        let video = try XCTUnwrap(imported.importedVideos.first)
        let tagID = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "保留", parentID: nil)
        try await store.setTagAssignment(tagID: tagID, videoIDs: [video.id], enabled: true)

        _ = try await store.reconcileSource(
            sourceID: "source-a",
            discoveredVideos: [makeDiscoveredVideo(
                path: "Moved/New.mp4",
                size: 10,
                volumeIdentifier: volume,
                fileResourceIdentifier: identity
            )]
        )
        let movedVideos = try await store.fetchVideos(libraryID: LibraryRecord.primaryID)
        let moved = try XCTUnwrap(movedVideos.first)
        let tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        let states = try await store.tagAssignmentStates(videoIDs: [moved.id], tags: tags)
        XCTAssertEqual(moved.id, video.id)
        XCTAssertEqual(moved.relativePath, "Moved/New.mp4")
        XCTAssertEqual(states[tagID], .on)

        let missingDate = Date(timeIntervalSince1970: 500)
        _ = try await store.reconcileSource(
            sourceID: "source-a",
            discoveredVideos: [],
            verifiedAt: missingDate
        )
        let afterDeletion = try await store.fetchVideos(libraryID: LibraryRecord.primaryID)
        let retained = try await store.fetchVideos(
            libraryID: LibraryRecord.primaryID,
            includeMissing: true
        )
        let retainedVideo = try XCTUnwrap(retained.first)
        let retainedStates = try await store.tagAssignmentStates(
            videoIDs: [retainedVideo.id],
            tags: tags
        )
        XCTAssertTrue(afterDeletion.isEmpty)
        XCTAssertEqual(retainedVideo.id, video.id)
        XCTAssertEqual(retainedVideo.availability, .unavailable)
        XCTAssertEqual(retainedVideo.invalidatedAt, missingDate)
        XCTAssertEqual(retainedStates[tagID], .on)
    }

    func testExactFingerprintRelinkRestoresMissingRecordAndPreservesTags() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        try await store.saveSourceAuthorization(makeSource(id: "source-a", name: "A"))
        try await store.saveSourceAuthorization(makeSource(id: "source-b", name: "B"))
        let fingerprint = Data("content-fingerprint".utf8)
        let original = makeDiscoveredVideo(
            path: "Original.mp4",
            size: 10,
            volumeIdentifier: Data("old-volume".utf8),
            fileResourceIdentifier: Data("old-file".utf8),
            contentFingerprint: fingerprint
        )
        let imported = try await store.importVideos(
            sourceID: "source-a",
            discoveredVideos: [original],
            importedAt: Date(timeIntervalSince1970: 100)
        )
        let video = try XCTUnwrap(imported.importedVideos.first)
        let tagID = try await store.createTag(
            libraryID: LibraryRecord.primaryID,
            name: "保留",
            parentID: nil
        )
        try await store.setTagAssignment(tagID: tagID, videoIDs: [video.id], enabled: true)
        _ = try await store.reconcileSource(sourceID: "source-a", discoveredVideos: [])

        let candidate = makeDiscoveredVideo(
            path: "Relocated.mp4",
            size: 10,
            volumeIdentifier: Data("new-volume".utf8),
            fileResourceIdentifier: Data("new-file".utf8),
            contentFingerprint: fingerprint
        )
        let assessment = try await store.assessRelinkVideo(
            id: video.id,
            sourceID: "source-b",
            discoveredVideo: candidate
        )
        let restored = try await store.relinkVideo(
            id: video.id,
            sourceID: "source-b",
            discoveredVideo: candidate
        )
        let tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        let states = try await store.tagAssignmentStates(videoIDs: [restored.id], tags: tags)

        XCTAssertEqual(assessment, .exactMatch)
        XCTAssertEqual(restored.id, video.id)
        XCTAssertEqual(restored.availability, .available)
        XCTAssertEqual(restored.relativePath, "Relocated.mp4")
        XCTAssertEqual(states[tagID], .on)
    }

    func testTenThousandVideoIndexAndTagFilterMeetMVPBudgets() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        let discovered = (0..<10_000).map {
            makeDiscoveredVideo(path: String(format: "Folder/Video-%05d.mp4", $0), size: Int64($0 + 1))
        }
        let importStarted = Date()
        let videos = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: discovered
        )
        let importDuration = Date().timeIntervalSince(importStarted)
        let tagID = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "性能", parentID: nil)
        try await store.setTagAssignment(tagID: tagID, videoIDs: videos.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element.id : nil }, enabled: true)

        let filterStarted = Date()
        let filtered = try await store.fetchVideos(
            libraryID: LibraryRecord.primaryID,
            query: LibraryQueryRequest(
                baseFilter: .tag(tagID),
                temporaryFilenameSearch: "",
                rule: .standard
            )
        )
        let filterDuration = Date().timeIntervalSince(filterStarted)

        XCTAssertEqual(videos.count, 10_000)
        XCTAssertEqual(filtered.count, 5_000)
        XCTAssertLessThan(importDuration, 10, "10,000 条首次导入应在测试机上于 10 秒内完成")
        XCTAssertLessThan(filterDuration, 0.2, "10,000 条标签筛选目标为 200 毫秒")
    }

    func testCancelledImportLeavesExistingVideosAvailable() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        _ = try await store.importTestVideos(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [makeDiscoveredVideo(path: "Keep.mp4", size: 10)]
        )

        let importTask = Task {
            try await Task.sleep(nanoseconds: 100_000_000)
            return try await store.importTestVideos(libraryID: LibraryRecord.primaryID, discoveredVideos: [])
        }
        importTask.cancel()
        do { _ = try await importTask.value } catch {}

        let records = try await store.fetchVideos(libraryID: LibraryRecord.primaryID, includeMissing: true)
        XCTAssertEqual(records.first?.availability, .available)
    }

    private func makeLibraryRecord(name: String = "Videos") -> LibraryRecord {
        LibraryRecord(
            id: LibraryRecord.primaryID,
            name: name,
            rootBookmarkData: Data([0x01]),
            createdAt: Date(timeIntervalSince1970: 100),
            lastScanAt: nil
        )
    }

    private func makeSource(id: String, name: String) -> SourceAuthorizationRecord {
        SourceAuthorizationRecord(
            id: id,
            libraryID: LibraryRecord.primaryID,
            displayName: name,
            rootBookmarkData: Data([0x02]),
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }

    func testMediaCommitSurvivesUnchangedDiscoveryButRejectsChangedFile() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        try await store.saveSourceAuthorization(makeSource(id: "test-media", name: "Synthetic"))
        let fileURL = fixture.directoryURL.appendingPathComponent("Synthetic.mp4")
        let key = fallbackPathKey(for: fileURL)
        func discovery(_ size: Int64) -> DiscoveredVideo {
            DiscoveredVideo(relativePath: "Synthetic.mp4", filename: "Synthetic.mp4", fileExtension: "mp4",
                            fileSize: size, creationDate: nil, modificationDate: nil,
                            volumeIdentifier: Data([1]), fileResourceIdentifier: Data([2]),
                            finderTags: [], fallbackPathKey: key, lastKnownPath: fileURL.path)
        }
        let first = try await store.importVideos(sourceID: "test-media", discoveredVideos: [discovery(10)],
                                                 importedAt: Date(timeIntervalSince1970: 100))
        let video = try XCTUnwrap(first.importedVideos.first)
        let original = try await store.mediaProcessingSnapshot(videoID: video.id, pathKey: key)
        let expected = try XCTUnwrap(original)
        let result = MediaProcessingResult(duration: 2, width: 64, height: 64, thumbnailID: "synthetic",
                                           metadataStatus: .completed, thumbnailStatus: .completed)
        _ = try await store.reconcileSources(discoveredVideosBySource: ["test-media": [discovery(10)]],
                                             verifiedAt: Date(timeIntervalSince1970: 200))
        let committed = try await store.commitMediaProcessing(result, expected: expected)
        XCTAssertEqual(committed?.thumbnailID, "synthetic")

        let fresh = try await store.mediaProcessingSnapshot(videoID: video.id, pathKey: key)
        let freshExpected = try XCTUnwrap(fresh)
        _ = try await store.reconcileSources(discoveredVideosBySource: ["test-media": [discovery(11)]],
                                             verifiedAt: Date(timeIntervalSince1970: 300))
        let stale = try await store.commitMediaProcessing(result, expected: freshExpected)
        XCTAssertNil(stale)
        let updated = try await store.fetchVideo(id: video.id)
        XCTAssertEqual(updated?.fileSize, 11)
        XCTAssertEqual(updated?.thumbnailStatus, .pending)
    }

    func testMediaCommitIgnoresLocationOrderingButRejectsSelectedLocationRemoval() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        try await store.saveSourceAuthorization(makeSource(id: "location-a", name: "A"))
        try await store.saveSourceAuthorization(makeSource(id: "location-b", name: "B"))
        let firstKey = Data([3])
        for (sourceID, key, time) in [("location-a", firstKey, 100.0), ("location-b", Data([4]), 200.0)] {
            let record = DiscoveredVideo(relativePath: "Same.mp4", filename: "Same.mp4", fileExtension: "mp4",
                                         fileSize: 10, creationDate: nil, modificationDate: nil,
                                         volumeIdentifier: Data([1]), fileResourceIdentifier: Data([2]),
                                         finderTags: [], fallbackPathKey: key)
            _ = try await store.importVideos(sourceID: sourceID, discoveredVideos: [record],
                                             importedAt: Date(timeIntervalSince1970: time))
        }
        let rows = try await store.fetchVideos(libraryID: LibraryRecord.primaryID)
        XCTAssertEqual(rows.count, 1)
        let record = try XCTUnwrap(rows.first)
        let before = try await store.mediaProcessingSnapshot(videoID: record.id, pathKey: firstKey)
        let expected = try XCTUnwrap(before)
        XCTAssertEqual(expected.locations.count, 2)
        try executeSQL(at: fixture.databaseURL,
                       sql: "UPDATE video_locations SET last_verified_at = 300 WHERE source_id = 'location-a'")
        let result = MediaProcessingResult(duration: 2, width: 64, height: 64, thumbnailID: "synthetic",
                                           metadataStatus: .completed, thumbnailStatus: .completed)
        let committed = try await store.commitMediaProcessing(result, expected: expected)
        XCTAssertEqual(committed?.thumbnailID, "synthetic")

        let beforeRemoval = try await store.mediaProcessingSnapshot(videoID: record.id, pathKey: firstKey)
        let expectedBeforeRemoval = try XCTUnwrap(beforeRemoval)
        try executeSQL(at: fixture.databaseURL,
                       sql: "UPDATE video_locations SET is_available = 0 WHERE source_id = 'location-a'")
        let rejected = try await store.commitMediaProcessing(result, expected: expectedBeforeRemoval)
        XCTAssertNil(rejected)
    }

    func testProtectedLocationCanRecoverOnceInNewAuthenticatedScope() async throws {
        let first = UUID(), next = UUID()
        let timestamp = Date(timeIntervalSince1970: 100)
        let fingerprint = Data([1, 2, 3])
        let old = RecoveryFileObservation(sourceID: "synthetic", scopeGeneration: first, path: "/synthetic/test.m4v",
                                          size: 10, modified: timestamp, originalFingerprint: fingerprint)
        let retry = RecoveryFileObservation(sourceID: old.sourceID, scopeGeneration: next, path: old.path,
                                            size: old.size, modified: old.modified, originalFingerprint: fingerprint)
        XCTAssertFalse(old.needsVerification(previous: old, authenticatedScope: first))
        XCTAssertTrue(retry.needsVerification(previous: old, authenticatedScope: next))
        XCTAssertFalse(retry.needsVerification(previous: retry, authenticatedScope: next))
        XCTAssertFalse(retry.needsVerification(previous: old, authenticatedScope: nil))
        XCTAssertFalse(retry.needsVerification(previous: old, authenticatedScope: first))
        XCTAssertTrue(VideoCloudReadiness.isPlaceholder(status: .notDownloaded, dataless: false))

        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        try await store.saveSourceAuthorization(makeSource(id: "synthetic", name: "Synthetic"))
        let exact = makeDiscoveredVideo(path: "test.m4v", size: 10, contentFingerprint: fingerprint)
        let mismatched = makeDiscoveredVideo(path: "test.m4v", size: 10, contentFingerprint: Data([4]))
        let imported = try await store.importVideos(sourceID: "synthetic", discoveredVideos: [exact])
        let record = try XCTUnwrap(imported.importedVideos.first)
        try await store.protectRecoveryLocations(videoIDs: [record.id])
        let locked = record.withAvailability(.unavailable, unavailableReason: .accessLost)
        XCTAssertEqual(locked.accessPresentation, .accessNeedsVerification)
        XCTAssertEqual(locked.accessPresentation.symbol, "exclamationmark.circle")
        XCTAssertEqual(record.withAvailability(.unavailable, unavailableReason: .missingFromKnownLocation).accessPresentation, .unavailable)
        XCTAssertEqual(record.withAvailability(.offline).accessPresentation, .offline)
        XCTAssertEqual(record.withAvailability(.available, isCloudPlaceholder: true).accessPresentation, .cloud)
        let mismatch = try await store.assessRelinkVideo(id: record.id, sourceID: "synthetic",
            discoveredVideo: mismatched, allowAvailableRecord: true)
        XCTAssertNotEqual(mismatch, .exactMatch)
        let protected = try await store.fetchVideoLocations(videoID: record.id)
        XCTAssertEqual(protected.first?.requiresRecoveryVerification, true)
        let restored = try await store.relinkVideo(id: record.id, sourceID: "synthetic",
            discoveredVideo: exact, allowAvailableRecord: true)
        let resolved = try await store.fetchVideoLocations(videoID: record.id)
        XCTAssertEqual(resolved.first?.requiresRecoveryVerification, false)
        XCTAssertEqual(restored.id, record.id)
        XCTAssertEqual(restored.accessPresentation, .none)
        XCTAssertNil(restored.accessPresentation.symbol)
    }

    func testOriginalPathAccessPreservesFingerprintAndMakesNoDuplicate() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        try await store.saveSourceAuthorization(makeSource(id: "old", name: "Old"))
        let path = "/synthetic/root/nested/test.m4v"
        let fingerprint = Data(repeating: 7, count: 32)
        let input = DiscoveredVideo(relativePath: "test.m4v", filename: "test.m4v", fileExtension: "m4v",
            fileSize: 100, creationDate: nil, modificationDate: nil, volumeIdentifier: nil,
            fileResourceIdentifier: nil, contentFingerprint: fingerprint, finderTags: [], lastKnownPath: path)
        let imported = try await store.importVideos(sourceID: "old", discoveredVideos: [input])
        let record = try XCTUnwrap(imported.importedVideos.first)
        _ = try await store.updateMediaInfo(videoID: record.id, result: MediaProcessingResult(
            duration: nil, width: 64, height: 64, thumbnailID: "retained",
            metadataStatus: .completed, thumbnailStatus: .completed, contentFingerprint: fingerprint))
        try await store.protectRecoveryLocations(videoIDs: [record.id])
        let grant = makeSource(id: "new", name: "Ancestor")
        let wrongPath = try await store.restoreOriginalPathAccess(videoID: record.id, recordedPath: "/other/test.m4v",
            relativePath: "test.m4v", toSourceID: "new", authorization: grant)
        XCTAssertFalse(wrongPath)
        for _ in 0...1 {
            let restored = try await store.restoreOriginalPathAccess(videoID: record.id, recordedPath: path,
                relativePath: "nested/test.m4v", toSourceID: "new", authorization: grant)
            XCTAssertTrue(restored)
        }
        let observed = try await store.fetchVideo(id: record.id)
        XCTAssertEqual(observed?.contentFingerprint, fingerprint)
        XCTAssertEqual(observed?.thumbnailID, "retained")
        let locations = try await store.fetchVideoLocations(videoID: record.id)
        XCTAssertEqual(locations.filter({ !$0.requiresRecoveryVerification }).count, 1)
        let sources = try await store.fetchSourceAuthorizations()
        XCTAssertEqual(Set(sources.map(\.id)), ["old", "new"])
    }

    func testOriginalPathAccessForExactFileScopeRequiresExplicitRoot() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        try await store.saveSourceAuthorization(makeSource(id: "file", name: "Single file"))
        let path = "/synthetic/selected.m4v"
        let input = DiscoveredVideo(relativePath: "", filename: "selected.m4v", fileExtension: "m4v",
            fileSize: 0, creationDate: nil, modificationDate: nil, volumeIdentifier: nil,
            fileResourceIdentifier: nil, finderTags: [], lastKnownPath: path)
        let imported = try await store.importVideos(sourceID: "file", discoveredVideos: [input])
        let video = try XCTUnwrap(imported.importedVideos.first)
        try await store.protectRecoveryLocations(videoIDs: [video.id])
        let unspecified = try await store.restoreOriginalPathAccess(videoID: video.id, recordedPath: path,
            relativePath: "", toSourceID: "file")
        XCTAssertFalse(unspecified)
        let wrong = try await store.restoreOriginalPathAccess(videoID: video.id, recordedPath: path,
            relativePath: "", toSourceID: "file", authorizedFilePath: "/other/selected.m4v")
        XCTAssertFalse(wrong)
        let exact = try await store.restoreOriginalPathAccess(videoID: video.id, recordedPath: path,
            relativePath: "", toSourceID: "file", authorizedFilePath: path)
        XCTAssertTrue(exact)
        let result = try await store.fetchVideoLocations(videoID: video.id)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.relativePath, "")
        XCTAssertEqual(result.first?.requiresRecoveryVerification, false)
    }

    func testIndexedLiveMoveKeepsExistingRecordAndRefusesDestinationCollision() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        try await store.saveSourceAuthorization(makeSource(id: "granted", name: "Ancestor"))
        let identity = IndexedFileIdentity(device: 1, inode: 42, volume: Data([8]), resource: Data([9]))
        let fingerprint = Data(repeating: 7, count: 32)
        let original = DiscoveredVideo(relativePath: "one/old.mov", filename: "old.mov", fileExtension: "mov",
            fileSize: 0, creationDate: nil, modificationDate: nil, volumeIdentifier: identity.volume,
            fileResourceIdentifier: identity.resource, contentFingerprint: fingerprint, finderTags: ["Synthetic"],
            lastKnownPath: "/synthetic/one/old.mov")
        let other = DiscoveredVideo(relativePath: "two/occupied.mov", filename: "occupied.mov", fileExtension: "mov",
            fileSize: 0, creationDate: nil, modificationDate: nil, volumeIdentifier: identity.volume,
            fileResourceIdentifier: Data([10]), finderTags: [], lastKnownPath: "/synthetic/two/occupied.mov")
        let result = try await store.importVideos(sourceID: "granted", discoveredVideos: [original, other])
        let video = try XCTUnwrap(result.importedVideos.first(where: { $0.filename == "old.mov" }))
        let tag = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "Synthetic relocation", parentID: nil)
        try await store.setTagAssignment(tagID: tag, videoIDs: [video.id], enabled: true)
        let locations = try await store.fetchVideoLocations(videoID: video.id)
        let old = try XCTUnwrap(locations.first)
        let collided = try await store.moveIndexedVideoLocation(old, to: "/synthetic/two/occupied.mov",
            relativePath: "two/occupied.mov", identity: identity)
        XCTAssertFalse(collided)
        try await store.saveSourceAuthorization(makeSource(id: "overlapping", name: "Nested scope"))
        let overlap = DiscoveredVideo(relativePath: "foreign.mov", filename: "foreign.mov", fileExtension: "mov",
            fileSize: 0, creationDate: nil, modificationDate: nil, volumeIdentifier: identity.volume,
            fileResourceIdentifier: Data([11]), finderTags: [], lastKnownPath: "/synthetic/two/foreign.mov")
        _ = try await store.importVideos(sourceID: "overlapping", discoveredVideos: [overlap])
        let crossScope = try await store.moveIndexedVideoLocation(old, to: "/synthetic/two/foreign.mov",
            relativePath: "two/foreign.mov", identity: identity)
        XCTAssertFalse(crossScope)
        let moved = try await store.moveIndexedVideoLocation(old, to: "/synthetic/two/new.mov",
            relativePath: "two/new.mov", identity: identity)
        XCTAssertTrue(moved)
        let updated = try await store.fetchVideo(id: video.id)
        XCTAssertEqual(updated?.id, video.id)
        XCTAssertEqual(updated?.contentFingerprint, fingerprint)
        XCTAssertEqual(updated?.filename, "new.mov")
        let newLocations = try await store.fetchVideoLocations(videoID: video.id)
        XCTAssertEqual(newLocations.map(\.lastKnownPath), ["/synthetic/two/new.mov"])
        let tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        let states = try await store.tagAssignmentStates(videoIDs: [video.id], tags: tags)
        XCTAssertEqual(states[tag], .on)
    }

    private func makeDiscoveredVideo(
        path: String,
        size: Int64,
        finderTags: [String] = [],
        modificationDate: Date? = nil,
        volumeIdentifier: Data? = nil,
        fileResourceIdentifier: Data? = nil,
        contentFingerprint: Data? = nil
    ) -> DiscoveredVideo {
        DiscoveredVideo(
            relativePath: path,
            filename: URL(fileURLWithPath: path).lastPathComponent,
            fileExtension: URL(fileURLWithPath: path).pathExtension.lowercased(),
            fileSize: size,
            creationDate: nil,
            modificationDate: modificationDate,
            volumeIdentifier: volumeIdentifier,
            fileResourceIdentifier: fileResourceIdentifier,
            contentFingerprint: contentFingerprint,
            finderTags: finderTags
        )
    }
}

private extension DatabaseStore {
    func importTestVideos(
        libraryID: String,
        discoveredVideos: [DiscoveredVideo],
        completedAt: Date = Date()
    ) async throws -> [VideoRecord] {
        let sourceID = "test-source-\(libraryID)"
        try saveSourceAuthorization(SourceAuthorizationRecord(
            id: sourceID,
            libraryID: libraryID,
            displayName: "Test Source",
            rootBookmarkData: Data([0x02]),
            createdAt: Date(timeIntervalSince1970: 100)
        ))
        _ = try await importVideos(
            sourceID: sourceID,
            discoveredVideos: discoveredVideos,
            importedAt: completedAt
        )
        return try fetchVideos(libraryID: libraryID)
    }
}

private func executeSQL(at databaseURL: URL, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw CocoaError(.fileWriteUnknown)
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw CocoaError(.fileWriteUnknown)
    }
}

private struct DatabaseFixture {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoTagManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        databaseURL = directoryURL.appendingPathComponent("test.sqlite3")
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
