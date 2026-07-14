import Foundation

struct VideoRecord: Equatable, Identifiable, Sendable {
    enum Availability: String, Sendable {
        case available
        case missing
    }

    let id: String
    let libraryID: String
    let relativePath: String
    let filename: String
    let fileExtension: String
    let fileSize: Int64
    let creationDate: Date?
    let modificationDate: Date?
    let firstIndexedAt: Date
    let availability: Availability
}
