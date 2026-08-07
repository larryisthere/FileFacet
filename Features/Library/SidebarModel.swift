import Foundation

enum TagSortMode: String, CaseIterable {
    case custom
    case name
    case count

    var title: String {
        switch self {
        case .custom: String(localized: .tagSortCustom)
        case .name: String(localized: .tagSortName)
        case .count: String(localized: .tagSortCount)
        }
    }

    func orders(_ left: TagRecord, before right: TagRecord) -> Bool {
        switch self {
        case .custom:
            if left.sortOrder != right.sortOrder { return left.sortOrder < right.sortOrder }
        case .name:
            break
        case .count:
            if left.videoCount != right.videoCount { return left.videoCount > right.videoCount }
        }

        let nameOrder = left.name.localizedStandardCompare(right.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return left.id < right.id
    }
}

enum LibraryFilter: Equatable, Sendable {
    case all
    case untagged
    case recent
    case unavailable
    case tag(String)
    case tags([String])
}

struct SidebarFilterCounts: Equatable, Sendable {
    let all: Int
    let untagged: Int
    let recent: Int
    let unavailable: Int

    init(all: Int, untagged: Int, recent: Int, unavailable: Int = 0) {
        self.all = all
        self.untagged = untagged
        self.recent = recent
        self.unavailable = unavailable
    }

    static let zero = SidebarFilterCounts(all: 0, untagged: 0, recent: 0, unavailable: 0)
}

enum SidebarGroupKind {
    case library
    case smartCollections
    case tags
}

final class SidebarGroupNode {
    let kind: SidebarGroupKind
    let title: String
    var children: [Any]

    init(kind: SidebarGroupKind, title: String, children: [Any]) {
        self.kind = kind
        self.title = title
        self.children = children
    }
}

final class SidebarFilterNode {
    let title: String
    let systemImageName: String
    let filter: LibraryFilter
    let videoCount: Int

    var shortcutHint: String? {
        switch filter {
        case .all: "⌘1"
        case .untagged: "⌘2"
        case .recent: "⌘3"
        case .unavailable: "⌘4"
        case .tag, .tags: nil
        }
    }

    init(title: String, systemImageName: String, filter: LibraryFilter, videoCount: Int) {
        self.title = title
        self.systemImageName = systemImageName
        self.filter = filter
        self.videoCount = videoCount
    }
}

final class SidebarPlaceholderNode {
    let title: String

    init(title: String) {
        self.title = title
    }
}

final class SidebarDraftTagNode {}

final class SmartCollectionNode {
    let collection: SmartCollectionRecord

    init(collection: SmartCollectionRecord) {
        self.collection = collection
    }
}

final class TagNode {
    let tag: TagRecord
    var children: [TagNode] = []

    init(tag: TagRecord) {
        self.tag = tag
    }
}
