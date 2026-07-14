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
