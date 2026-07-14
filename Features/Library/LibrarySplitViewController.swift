import AppKit

@MainActor
final class LibrarySplitViewController: NSSplitViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: SidebarViewController())
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 320

        let gridItem = NSSplitViewItem(viewController: VideoGridViewController())
        gridItem.minimumThickness = 420

        let inspectorItem = NSSplitViewItem(viewController: InspectorViewController())
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 380
        inspectorItem.canCollapse = true

        addSplitViewItem(sidebarItem)
        addSplitViewItem(gridItem)
        addSplitViewItem(inspectorItem)

        splitView.autosaveName = "MainLibrarySplitView"
        splitView.setPosition(220, ofDividerAt: 0)
        splitView.setPosition(900, ofDividerAt: 1)
    }
}
