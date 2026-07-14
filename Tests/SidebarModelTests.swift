import XCTest
@testable import VideoTagManager

final class SidebarModelTests: XCTestCase {
    func testDefaultSidebarContainsUserFacingLibraryFilters() {
        let titles = SidebarModel.defaultSections.flatMap(\.items).map(\.title)

        XCTAssertEqual(
            titles,
            ["全部视频", "未打标签", "最近新增", "无法访问", "Finder 标签"]
        )
    }

    func testFinderTagsLiveInDedicatedSection() {
        let tagsSection = SidebarModel.defaultSections[1]

        XCTAssertEqual(tagsSection.title, "标签")
        XCTAssertEqual(tagsSection.items.map(\.title), ["Finder 标签"])
    }
}
