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
