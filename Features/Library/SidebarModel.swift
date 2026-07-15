import Foundation

enum LibraryFilter: Equatable, Sendable {
    case all
    case untagged
    case recent
    case tag(String)
    case tags([String])
}

struct SidebarFilterCounts: Equatable, Sendable {
    let all: Int
    let untagged: Int
    let recent: Int

    static let zero = SidebarFilterCounts(all: 0, untagged: 0, recent: 0)
}

final class SidebarGroupNode {
    let title: String
    var children: [Any]

    init(title: String, children: [Any]) {
        self.title = title
        self.children = children
    }
}

final class SidebarFilterNode {
    let title: String
    let systemImageName: String
    let filter: LibraryFilter
    let videoCount: Int

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

final class TagNode {
    let tag: TagRecord
    var children: [TagNode] = []

    init(tag: TagRecord) {
        self.tag = tag
    }
}
