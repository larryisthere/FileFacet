import XCTest
@testable import FileFacet

final class SidebarModelTests: XCTestCase {
    func testLibraryFiltersPreserveAssociatedTagIdentity() {
        XCTAssertEqual(LibraryFilter.all, .all)
        XCTAssertEqual(LibraryFilter.untagged, .untagged)
        XCTAssertEqual(LibraryFilter.recent, .recent)
        XCTAssertEqual(LibraryFilter.tag("tag-id"), .tag("tag-id"))
        XCTAssertEqual(LibraryFilter.tags(["one", "two"]), .tags(["one", "two"]))
    }

    func testTagNodeKeepsTagAndChildren() {
        let parent = TagNode(tag: makeTag(id: "parent", name: "父级"))
        let child = TagNode(tag: makeTag(id: "child", name: "子级", parentID: "parent"))
        parent.children.append(child)

        XCTAssertEqual(parent.tag.id, "parent")
        XCTAssertEqual(parent.children.map(\.tag.id), ["child"])
    }

    private func makeTag(id: String, name: String, parentID: String? = nil) -> TagRecord {
        TagRecord(
            id: id,
            libraryID: LibraryRecord.primaryID,
            name: name,
            parentID: parentID,
            color: nil,
            sortOrder: 0,
            source: "user",
            videoCount: 0
        )
    }
}
