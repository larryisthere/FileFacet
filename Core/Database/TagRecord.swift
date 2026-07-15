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

struct TagCreationDraft: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let parentID: String?
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

struct FinderTagMapping: Equatable, Sendable {
    let externalKey: String
    let tagID: String
    let firstImportedAt: Date
    let lastSeenAt: Date
}

struct TagStateSnapshot: Equatable, Sendable {
    let libraryID: String
    let tags: [TagRecord]
    let relations: [VideoTagRelation]
    let finderMappings: [FinderTagMapping]
}
