import XCTest
@testable import VideoTagManager

final class DatabaseStoreTests: XCTestCase {
    func testMigrationCreatesCurrentSchema() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }

        let store = try DatabaseStore(databaseURL: fixture.databaseURL)

        let schemaVersion = try await store.schemaVersion()

        XCTAssertEqual(schemaVersion, DatabaseStore.currentSchemaVersion)
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

    func testSuccessfulScanUpsertsVideosAndMarksMissingRecords() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        let firstScanDate = Date(timeIntervalSince1970: 200)

        let firstResult = try await store.applyScan(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [
                makeDiscoveredVideo(path: "A.mp4", size: 10),
                makeDiscoveredVideo(path: "Folder/B.mov", size: 20),
            ],
            completedAt: firstScanDate
        )
        let firstA = try XCTUnwrap(firstResult.first { $0.relativePath == "A.mp4" })

        let secondResult = try await store.applyScan(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [makeDiscoveredVideo(path: "A.mp4", size: 30)],
            completedAt: Date(timeIntervalSince1970: 300)
        )
        let secondA = try XCTUnwrap(secondResult.first)
        let allRecords = try await store.fetchVideos(
            libraryID: LibraryRecord.primaryID,
            includeMissing: true
        )
        let missingB = try XCTUnwrap(allRecords.first { $0.relativePath == "Folder/B.mov" })

        XCTAssertEqual(secondResult.count, 1)
        XCTAssertEqual(secondA.id, firstA.id)
        XCTAssertEqual(secondA.firstIndexedAt, firstScanDate)
        XCTAssertEqual(secondA.fileSize, 30)
        XCTAssertEqual(missingB.availability, .missing)
    }

    func testReplacingLibraryClearsPreviousIndex() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord(name: "First"))
        _ = try await store.applyScan(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [makeDiscoveredVideo(path: "A.mp4", size: 10)]
        )

        try await store.replaceLibrary(makeLibraryRecord(name: "Second"))

        let records = try await store.fetchVideos(
            libraryID: LibraryRecord.primaryID,
            includeMissing: true
        )
        XCTAssertTrue(records.isEmpty)
    }

    func testMediaProcessingResultPersists() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        let records = try await store.applyScan(
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
        let videos = try await store.applyScan(
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
        let videos = try await store.applyScan(
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
        let videos = try await store.applyScan(
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

    func testVideoFiltersSupportSearchRecencyUntaggedMissingAndTagIntersection() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        let oldDate = Date(timeIntervalSince1970: 1_000)
        _ = try await store.applyScan(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [
                makeDiscoveredVideo(path: "Alpha.mp4", size: 10),
                makeDiscoveredVideo(path: "Beta.mov", size: 20),
            ],
            completedAt: oldDate
        )
        let now = Date(timeIntervalSince1970: 4_000_000)
        let current = try await store.applyScan(
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
        let missing = try await store.fetchVideos(libraryID: LibraryRecord.primaryID, filter: .missing, now: now)
        let inherited = try await store.fetchVideos(libraryID: LibraryRecord.primaryID, filter: .tag(parentID), now: now)
        let intersection = try await store.fetchVideos(libraryID: LibraryRecord.primaryID, filter: .tags([parentID, secondID]), now: now)

        XCTAssertEqual(searched.map(\.filename), ["Alpha.mp4"])
        XCTAssertEqual(recent.map(\.filename), ["Gamma.mkv"])
        XCTAssertTrue(untagged.isEmpty)
        XCTAssertEqual(missing.map(\.filename), ["Beta.mov"])
        XCTAssertEqual(Set(inherited.map(\.filename)), Set(["Alpha.mp4", "Gamma.mkv"]))
        XCTAssertEqual(intersection.map(\.filename), ["Gamma.mkv"])
    }

    func testFinderTagImportIsIdempotentAndRefreshesAssignments() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        var video = makeDiscoveredVideo(path: "A.mp4", size: 10, finderTags: ["红色"])
        let firstVideos = try await store.applyScan(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [video]
        )
        _ = try await store.applyScan(libraryID: LibraryRecord.primaryID, discoveredVideos: [video])
        var tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        let finderRoot = try XCTUnwrap(tags.first(where: { $0.source == "finder-root" }))
        let imported = try XCTUnwrap(tags.first(where: { $0.source == "finder" }))
        XCTAssertEqual(imported.parentID, finderRoot.id)
        XCTAssertEqual(tags.filter { $0.source == "finder" }.count, 1)
        var states = try await store.tagAssignmentStates(videoIDs: firstVideos.map(\.id), tags: tags)
        XCTAssertEqual(states[imported.id], .on)

        video = makeDiscoveredVideo(path: "A.mp4", size: 10, finderTags: [])
        _ = try await store.applyScan(libraryID: LibraryRecord.primaryID, discoveredVideos: [video])
        tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        states = try await store.tagAssignmentStates(videoIDs: firstVideos.map(\.id), tags: tags)
        XCTAssertEqual(states[imported.id], .off)
    }

    func testRenameByFileIdentityPreservesVideoIDAndTags() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        let identity = Data("file-id".utf8)
        let volume = Data("volume-id".utf8)
        let original = try await store.applyScan(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [makeDiscoveredVideo(path: "Old.mp4", size: 10, volumeIdentifier: volume, fileResourceIdentifier: identity)]
        )
        let tagID = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "保留", parentID: nil)
        try await store.setTagAssignment(tagID: tagID, videoIDs: original.map(\.id), enabled: true)

        let moved = try await store.applyScan(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [makeDiscoveredVideo(path: "Folder/New.mp4", size: 11, volumeIdentifier: volume, fileResourceIdentifier: identity)]
        )
        let tags = try await store.fetchTags(libraryID: LibraryRecord.primaryID)
        let states = try await store.tagAssignmentStates(videoIDs: moved.map(\.id), tags: tags)

        XCTAssertEqual(moved.first?.id, original.first?.id)
        XCTAssertEqual(moved.first?.relativePath, "Folder/New.mp4")
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
        let scanStarted = Date()
        let videos = try await store.applyScan(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: discovered
        )
        let scanDuration = Date().timeIntervalSince(scanStarted)
        let tagID = try await store.createTag(libraryID: LibraryRecord.primaryID, name: "性能", parentID: nil)
        try await store.setTagAssignment(tagID: tagID, videoIDs: videos.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element.id : nil }, enabled: true)

        let filterStarted = Date()
        let filtered = try await store.fetchVideos(libraryID: LibraryRecord.primaryID, filter: .tag(tagID))
        let filterDuration = Date().timeIntervalSince(filterStarted)

        XCTAssertEqual(videos.count, 10_000)
        XCTAssertEqual(filtered.count, 5_000)
        XCTAssertLessThan(scanDuration, 10, "10,000 条首次索引应在测试机上于 10 秒内完成")
        XCTAssertLessThan(filterDuration, 0.2, "10,000 条标签筛选目标为 200 毫秒")
    }

    func testCancelledScanLeavesPreviousAvailabilityUntouched() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let store = try DatabaseStore(databaseURL: fixture.databaseURL)
        try await store.saveLibrary(makeLibraryRecord())
        _ = try await store.applyScan(
            libraryID: LibraryRecord.primaryID,
            discoveredVideos: [makeDiscoveredVideo(path: "Keep.mp4", size: 10)]
        )

        let scan = Task {
            try await Task.sleep(nanoseconds: 100_000_000)
            return try await store.applyScan(libraryID: LibraryRecord.primaryID, discoveredVideos: [])
        }
        scan.cancel()
        do { _ = try await scan.value } catch {}

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

    private func makeDiscoveredVideo(
        path: String,
        size: Int64,
        finderTags: [String] = [],
        volumeIdentifier: Data? = nil,
        fileResourceIdentifier: Data? = nil
    ) -> DiscoveredVideo {
        DiscoveredVideo(
            relativePath: path,
            filename: URL(fileURLWithPath: path).lastPathComponent,
            fileExtension: URL(fileURLWithPath: path).pathExtension.lowercased(),
            fileSize: size,
            creationDate: nil,
            modificationDate: nil,
            volumeIdentifier: volumeIdentifier,
            fileResourceIdentifier: fileResourceIdentifier,
            finderTags: finderTags
        )
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
