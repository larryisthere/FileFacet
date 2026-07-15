import CryptoKit
import Foundation

func fallbackPathKey(for fileURL: URL) -> Data {
    let normalizedURL = fileURL.standardizedFileURL.absoluteString
    return Data(SHA256.hash(data: Data(normalizedURL.utf8)))
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
    let finderTags: [String]
    let fallbackPathKey: Data?

    init(
        relativePath: String,
        filename: String,
        fileExtension: String,
        fileSize: Int64,
        creationDate: Date?,
        modificationDate: Date?,
        volumeIdentifier: Data?,
        fileResourceIdentifier: Data?,
        finderTags: [String],
        fallbackPathKey: Data? = nil
    ) {
        self.relativePath = relativePath
        self.filename = filename
        self.fileExtension = fileExtension
        self.fileSize = fileSize
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.volumeIdentifier = volumeIdentifier
        self.fileResourceIdentifier = fileResourceIdentifier
        self.finderTags = finderTags
        self.fallbackPathKey = fallbackPathKey
    }
}
