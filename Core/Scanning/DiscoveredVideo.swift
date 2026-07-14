import Foundation

struct DiscoveredVideo: Equatable, Sendable {
    let relativePath: String
    let filename: String
    let fileExtension: String
    let fileSize: Int64
    let creationDate: Date?
    let modificationDate: Date?
    let volumeIdentifier: Data?
    let fileResourceIdentifier: Data?
}
