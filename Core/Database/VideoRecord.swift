import Foundation

struct VideoRecord: Equatable, Identifiable, Sendable {
    enum Availability: String, Sendable {
        case available
        case missing
    }

    enum ProcessingStatus: String, Sendable {
        case pending
        case completed
        case failed
    }

    let id: String
    let libraryID: String
    let relativePath: String
    let filename: String
    let fileExtension: String
    let fileSize: Int64
    let creationDate: Date?
    let modificationDate: Date?
    let duration: Double?
    let width: Int?
    let height: Int?
    let thumbnailID: String?
    let metadataStatus: ProcessingStatus
    let thumbnailStatus: ProcessingStatus
    let firstIndexedAt: Date
    let availability: Availability
}

struct RemovedVideoRecord: Equatable, Sendable {
    let id: String
    let libraryID: String
    let relativePath: String
    let volumeIdentifier: Data?
    let fileResourceIdentifier: Data?
    let filename: String
    let fileExtension: String
    let fileSize: Int64
    let creationDate: Date?
    let modificationDate: Date?
    let duration: Double?
    let width: Int?
    let height: Int?
    let thumbnailID: String?
    let metadataStatus: String
    let thumbnailStatus: String
    let availabilityStatus: String
    let firstIndexedAt: Date
    let updatedAt: Date
    let lastSeenScanID: String?
    let finderTagsImportedAt: Date?
}

struct RemovedVideoLocation: Equatable, Sendable {
    let videoID: String
    let sourceID: String
    let relativePath: String
    let lastVerifiedAt: Date
    let isAvailable: Bool
    let fallbackPathKey: Data?
}

struct RemovedVideoTagRelation: Equatable, Sendable {
    let videoID: String
    let tagID: String
    let createdAt: Date
}

struct VideoRemovalSnapshot: Equatable, Sendable {
    let videos: [RemovedVideoRecord]
    let locations: [RemovedVideoLocation]
    let tagRelations: [RemovedVideoTagRelation]
}
