import Foundation

struct SidebarSection: Equatable {
    let title: String
    let items: [SidebarItem]
}

struct SidebarItem: Equatable {
    let title: String
    let systemImageName: String
}

enum SidebarModel {
    static let defaultSections = [
        SidebarSection(
            title: "资料库",
            items: [
                SidebarItem(title: "全部视频", systemImageName: "film"),
                SidebarItem(title: "未打标签", systemImageName: "tag.slash"),
                SidebarItem(title: "最近新增", systemImageName: "clock"),
                SidebarItem(title: "无法访问", systemImageName: "exclamationmark.triangle"),
            ]
        ),
        SidebarSection(
            title: "标签",
            items: [
                SidebarItem(title: "Finder 标签", systemImageName: "tag"),
            ]
        ),
    ]
}
