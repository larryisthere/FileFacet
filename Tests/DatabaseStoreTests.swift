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
