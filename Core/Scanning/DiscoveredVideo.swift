import CryptoKit
import Foundation

func fallbackPathKey(for fileURL: URL) -> Data {
    let normalizedURL = fileURL.standardizedFileURL.absoluteString
    return Data(SHA256.hash(data: Data(normalizedURL.utf8)))
}

func contentFingerprint(for fileURL: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        try Task.checkCancellation()
        guard let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024),
              chunk.isEmpty == false else { break }
        hasher.update(data: chunk)
    }
    return Data(hasher.finalize())
}

struct DiscoveredVideo: Equatable, Sendable {
    let relativePath: String
    let filename: String
    let fileExtension: String
    let fileSize: Int64
    let creationDate: Date?
    let modificationDate: Date?
    let volumeIdentifier: Data?
    let fileResourceIdentifier: Data?
    let contentFingerprint: Data?
    let finderTags: [String]
    let fallbackPathKey: Data?
    let lastKnownPath: String?

    init(
        relativePath: String,
        filename: String,
        fileExtension: String,
        fileSize: Int64,
        creationDate: Date?,
        modificationDate: Date?,
        volumeIdentifier: Data?,
        fileResourceIdentifier: Data?,
        contentFingerprint: Data? = nil,
        finderTags: [String],
        fallbackPathKey: Data? = nil,
        lastKnownPath: String? = nil
    ) {
        self.relativePath = relativePath
        self.filename = filename
        self.fileExtension = fileExtension
        self.fileSize = fileSize
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.volumeIdentifier = volumeIdentifier
        self.fileResourceIdentifier = fileResourceIdentifier
        self.contentFingerprint = contentFingerprint
        self.finderTags = finderTags
        self.fallbackPathKey = fallbackPathKey
        self.lastKnownPath = lastKnownPath
    }

    func relativeToRecoveryDirectory(path: String) -> DiscoveredVideo {
        DiscoveredVideo(relativePath: path, filename: self.filename, fileExtension: fileExtension,
            fileSize: fileSize, creationDate: creationDate, modificationDate: modificationDate,
            volumeIdentifier: volumeIdentifier, fileResourceIdentifier: fileResourceIdentifier,
            contentFingerprint: contentFingerprint, finderTags: [], fallbackPathKey: fallbackPathKey,
            lastKnownPath: lastKnownPath)
    }

    func withContentFingerprint(_ fingerprint: Data) -> DiscoveredVideo {
        DiscoveredVideo(
            relativePath: relativePath,
            filename: filename,
            fileExtension: fileExtension,
            fileSize: fileSize,
            creationDate: creationDate,
            modificationDate: modificationDate,
            volumeIdentifier: volumeIdentifier,
            fileResourceIdentifier: fileResourceIdentifier,
            contentFingerprint: fingerprint,
            finderTags: finderTags,
            fallbackPathKey: fallbackPathKey,
            lastKnownPath: lastKnownPath
        )
    }
}

struct ScannedVideoCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let sourceID: String
    let sourceName: String
    let video: DiscoveredVideo
    let fileURL: URL

    init(
        sourceID: String,
        sourceName: String,
        video: DiscoveredVideo,
        fileURL: URL
    ) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.video = video
        self.fileURL = fileURL
        id = Self.identifier(sourceID: sourceID, video: video, fileURL: fileURL)
    }

    private static func identifier(
        sourceID: String,
        video: DiscoveredVideo,
        fileURL: URL
    ) -> String {
        var identity = Data()
        if let volumeIdentifier = video.volumeIdentifier,
           let fileResourceIdentifier = video.fileResourceIdentifier {
            identity.append(Data("resource:".utf8))
            identity.append(volumeIdentifier)
            identity.append(fileResourceIdentifier)
        } else if let fallbackPathKey = video.fallbackPathKey {
            identity.append(Data("path:".utf8))
            identity.append(fallbackPathKey)
        } else {
            identity.append(Data("source:\(sourceID):".utf8))
            identity.append(Data(fileURL.standardizedFileURL.absoluteString.utf8))
        }
        return Data(SHA256.hash(data: identity)).base64EncodedString()
    }
}
