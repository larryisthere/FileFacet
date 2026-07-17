import XCTest
@testable import FileFacet

final class VideoFileDiscoveryTests: XCTestCase {
    func testDiscoveryFindsSupportedVideosAndSkipsExcludedLocations() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        try fixture.createFile(at: "clip.MP4")
        try fixture.createFile(at: "Nested/movie.mov")
        try fixture.createFile(at: "notes.txt")
        try fixture.createFile(at: ".Hidden/secret.mp4")
        try fixture.createFile(at: "Example.app/inside.mp4")
        try fixture.createDirectory(at: "Linked")
        try FileManager.default.createSymbolicLink(
            at: fixture.rootURL.appendingPathComponent("LinkedAlias"),
            withDestinationURL: fixture.rootURL.appendingPathComponent("Linked")
        )
        try fixture.createFile(at: "Linked/visible.m4v")

        let videos = try VideoFileDiscovery().discoverVideos(at: fixture.rootURL)

        XCTAssertEqual(
            videos.map(\.relativePath),
            ["clip.MP4", "Linked/visible.m4v", "Nested/movie.mov"]
        )
        XCTAssertEqual(videos.first?.fileExtension, "mp4")
    }

    func testLargeDirectoryDiscoveryCompletesWithoutDroppingVideos() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        for index in 0..<1_000 {
            try fixture.createFile(at: String(format: "Batch/%04d.mp4", index))
        }

        let started = Date()
        let videos = try VideoFileDiscovery().discoverVideos(at: fixture.rootURL)

        XCTAssertEqual(videos.count, 1_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testUnreadableOrMissingRootFailsWithoutReturningPartialSuccess() throws {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingVideoRoot-\(UUID().uuidString)")

        XCTAssertThrowsError(try VideoFileDiscovery().discoverVideos(at: missingRoot))
    }
}

private struct DiscoveryFixture {
    let rootURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func createDirectory(at relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent(relativePath, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func createFile(at relativePath: String) throws {
        let url = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x00]).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
