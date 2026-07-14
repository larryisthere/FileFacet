import Foundation

struct TagRecord: Equatable, Identifiable, Sendable {
    let id: String
    let libraryID: String
    let name: String
    let parentID: String?
    let color: String?
    let sortOrder: Int
    let source: String
    let videoCount: Int
}

enum TagAssignmentState: Equatable, Sendable {
    case off
    case mixed
    case on
}

struct VideoTagRelation: Equatable, Sendable {
    let videoID: String
    let tagID: String
}

struct TagStateSnapshot: Equatable, Sendable {
    let libraryID: String
    let tags: [TagRecord]
    let relations: [VideoTagRelation]
}
