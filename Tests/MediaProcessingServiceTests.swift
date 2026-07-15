import XCTest
@testable import VideoTagManager

final class MediaProcessingServiceTests: XCTestCase {
    func testInvalidMediaReturnsFailureWithoutLosingVideoIdentity() async throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let fileURL = fixture.rootURL.appendingPathComponent("broken.mp4")
        try Data("not-a-video".utf8).write(to: fileURL)
        let service = try MediaProcessingService(cacheDirectory: fixture.rootURL)
        let video = makeVideo(id: "broken-video")

        let result = await service.process(video: video, fileURL: fileURL)

        XCTAssertEqual(result.metadataStatus, .failed)
        XCTAssertEqual(result.thumbnailStatus, .failed)
        XCTAssertNil(result.thumbnailID)
        XCTAssertEqual(video.id, "broken-video")
    }

    func testThumbnailCachePrunesOldestFilesToConfiguredLimit() async throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let service = try MediaProcessingService(cacheDirectory: fixture.rootURL, maximumCacheBytes: 12)
        let oldURL = service.thumbnailURL(for: "old")
        let middleURL = service.thumbnailURL(for: "middle")
        let newURL = service.thumbnailURL(for: "new")
        try Data(repeating: 1, count: 6).write(to: oldURL)
        try Data(repeating: 2, count: 6).write(to: middleURL)
        try Data(repeating: 3, count: 6).write(to: newURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: oldURL.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: middleURL.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3)], ofItemAtPath: newURL.path)

        try await service.pruneCache()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: middleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
    }

    func testThumbnailIdentifiersAlwaysResolveToDistinctStableFiles() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let service = try MediaProcessingService(cacheDirectory: fixture.rootURL)

        XCTAssertEqual(service.thumbnailURL(for: "one"), service.thumbnailURL(for: "one"))
        XCTAssertNotEqual(service.thumbnailURL(for: "one"), service.thumbnailURL(for: "two"))
    }

    private func makeVideo(id: String) -> VideoRecord {
        VideoRecord(
            id: id,
            libraryID: LibraryRecord.primaryID,
            relativePath: "broken.mp4",
            filename: "broken.mp4",
            fileExtension: "mp4",
            fileSize: 11,
            creationDate: nil,
            modificationDate: nil,
            duration: nil,
            width: nil,
            height: nil,
            thumbnailID: nil,
            metadataStatus: .pending,
            thumbnailStatus: .pending,
            firstIndexedAt: Date(),
            availability: .available
        )
    }
}

private struct MediaFixture {
    let rootURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoMediaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: rootURL) }
}
