import XCTest
import SQLite3
@testable import FileFacet

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

        let searched = try await store.fetchVideos(libraryID: LibraryRecord.primaryID, filter: .all, searchText: "ALPHA", now: now)
        let recent = try await store.fetchVideos(libraryID: LibraryRecord.primaryID, filter: .recent, now: now)
        let untagged = try await store.fetchVideos(libraryID: LibraryRecord.primaryID, filter: .untagged, now: now)
        let inherited = try await store.fetchVideos(libraryID: LibraryRecord.primaryID, filter: .tag(parentID), now: now)
        let intersection = try await store.fetchVideos(libraryID: LibraryRecord.primaryID, filter: .tags([parentID, secondID]), now: now)

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

    func testSilentMaintenanceUpdatesMovedVideoAndRemovesConfirmedDeletion() async throws {
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
            )]
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

        _ = try await store.reconcileSource(sourceID: "source-a", discoveredVideos: [])
        let afterDeletion = try await store.fetchVideos(libraryID: LibraryRecord.primaryID)
        XCTAssertTrue(afterDeletion.isEmpty)
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
        let filtered = try await store.fetchVideos(libraryID: LibraryRecord.primaryID, filter: .tag(tagID))
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

    private func makeDiscoveredVideo(
        path: String,
        size: Int64,
        finderTags: [String] = [],
        modificationDate: Date? = nil,
        volumeIdentifier: Data? = nil,
        fileResourceIdentifier: Data? = nil
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
