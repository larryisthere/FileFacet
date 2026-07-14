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
        XCTAssertTrue(afterDelete.isEmpty)

        try await store.restoreTagState(snapshot)
        let restored = try await store.captureTagState(libraryID: LibraryRecord.primaryID)
        XCTAssertEqual(Set(restored.tags.map(\.id)), Set([parentID, childID]))
        XCTAssertEqual(restored.relations, snapshot.relations)
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

    private func makeDiscoveredVideo(path: String, size: Int64) -> DiscoveredVideo {
        DiscoveredVideo(
            relativePath: path,
            filename: URL(fileURLWithPath: path).lastPathComponent,
            fileExtension: URL(fileURLWithPath: path).pathExtension.lowercased(),
            fileSize: size,
            creationDate: nil,
            modificationDate: nil,
            volumeIdentifier: nil,
            fileResourceIdentifier: nil
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
