import XCTest
@testable import Tagivy

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

    func testDeferredMediaWaitsForMatchingResolvedURLAndRetriesOnlyOnce() {
        let video = makeVideo(id: "pending")
        let sourceURL = URL(fileURLWithPath: "/synthetic/fixture.mp4")
        var deferred = DeferredMediaVideos()
        deferred.hold(video)
        deferred.hold(video)

        XCTAssertTrue(deferred.takeReady(resolvedURLs: [:]).isEmpty)
        XCTAssertTrue(deferred.takeReady(resolvedURLs: ["unrelated": sourceURL]).isEmpty)
        XCTAssertEqual(deferred.takeReady(resolvedURLs: [video.id: sourceURL]), [video])
        XCTAssertTrue(deferred.takeReady(resolvedURLs: [video.id: sourceURL]).isEmpty)

        deferred.hold(video)
        deferred.remove(id: video.id)
        XCTAssertTrue(deferred.takeReady(resolvedURLs: [video.id: sourceURL]).isEmpty)
    }

    func testFreshAndMissingCachedThumbnailGenerateWithoutPlayback() async throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SyntheticThumbnailFixture", withExtension: "m4v"))
        let file = fixture.rootURL.appendingPathComponent("synthetic.m4v")
        try FileManager.default.copyItem(at: source, to: file)
        let service = try MediaProcessingService(cacheDirectory: fixture.rootURL)
        let pending = makeVideo(id: "fresh")
        let freshNeeded = await service.needsProcessing(pending)
        XCTAssertTrue(freshNeeded)
        let result = await service.process(video: pending, fileURL: file)
        XCTAssertEqual(result.metadataStatus, .completed)
        XCTAssertEqual(result.thumbnailStatus, .completed)
        XCTAssertEqual(result.duration, 2)
        let firstID = try XCTUnwrap(result.thumbnailID)
        let firstJPEG = service.thumbnailURL(for: firstID)
        XCTAssertEqual(try Data(contentsOf: firstJPEG).prefix(3), Data([0xff, 0xd8, 0xff]))

        try FileManager.default.removeItem(at: firstJPEG)
        let old = VideoRecord(id: "old", libraryID: LibraryRecord.primaryID, relativePath: "synthetic.m4v",
                              filename: "synthetic.m4v", fileExtension: "m4v", fileSize: 13741,
                              creationDate: nil, modificationDate: nil, duration: result.duration,
                              width: result.width, height: result.height, thumbnailID: firstID,
                              metadataStatus: .completed, thumbnailStatus: .completed,
                              firstIndexedAt: Date(), availability: .available,
                              contentFingerprint: result.contentFingerprint)
        let repairNeeded = await service.needsProcessing(old)
        XCTAssertTrue(repairNeeded)
        let rebuilt = await service.process(video: old, fileURL: file)
        XCTAssertEqual(rebuilt.duration, old.duration)
        XCTAssertEqual(rebuilt.thumbnailStatus, .completed)
        let secondID = try XCTUnwrap(rebuilt.thumbnailID)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(try Data(contentsOf: service.thumbnailURL(for: secondID)).prefix(3), Data([0xff, 0xd8, 0xff]))
    }

    @MainActor
    func testThumbnailReadinessKeepsCloudAndUnavailableDistinct() {
        XCTAssertTrue(VideoCloudReadiness.isPlaceholder(status: .notDownloaded, dataless: false))
        XCTAssertTrue(VideoCloudReadiness.isPlaceholder(status: nil, dataless: true))
        XCTAssertFalse(VideoCloudReadiness.isPlaceholder(status: .downloaded, dataless: false))
        XCTAssertFalse(VideoCloudReadiness.isPlaceholder(status: .current, dataless: false))
        XCTAssertFalse(VideoCloudReadiness.isPlaceholder(status: nil, dataless: false))
        XCTAssertEqual(VideoThumbnailStatus(availability: .available, isCloudPlaceholder: true).symbol, "icloud.and.arrow.down")
        XCTAssertEqual(VideoThumbnailStatus(availability: .unavailable, isCloudPlaceholder: true,
                                            unavailableReason: .missingFromKnownLocation).symbol, "icloud.and.arrow.down")
        XCTAssertEqual(VideoThumbnailStatus(availability: .unavailable, isCloudPlaceholder: true,
                                            unavailableReason: .accessLost).symbol, "exclamationmark.circle")
        XCTAssertEqual(VideoThumbnailStatus(availability: .unavailable, isCloudPlaceholder: false).symbol, "exclamationmark.circle")
        XCTAssertEqual(VideoThumbnailStatus(availability: .offline, isCloudPlaceholder: false).symbol, "externaldrive.badge.exclamationmark")
        XCTAssertNil(VideoThumbnailStatus(availability: .available, isCloudPlaceholder: false).symbol)
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
