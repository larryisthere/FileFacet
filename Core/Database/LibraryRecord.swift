import Foundation

struct LibraryRecord: Equatable, Sendable {
    static let primaryID = "primary"

    let id: String
    let name: String
    let rootBookmarkData: Data
    let createdAt: Date
    let lastScanAt: Date?
}
