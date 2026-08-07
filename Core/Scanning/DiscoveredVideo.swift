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
