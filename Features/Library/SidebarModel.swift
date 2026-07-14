import Foundation

enum LibraryFilter: Equatable, Sendable {
    case all
    case untagged
    case recent
    case missing
    case tag(String)
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

    init(title: String, systemImageName: String, filter: LibraryFilter) {
        self.title = title
        self.systemImageName = systemImageName
        self.filter = filter
    }
}

final class TagNode {
    let tag: TagRecord
    var children: [TagNode] = []

    init(tag: TagRecord) {
        self.tag = tag
    }
}
