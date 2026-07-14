import AppKit

@MainActor
final class LibrarySplitViewController: NSSplitViewController {
    private let videoGridViewController: VideoGridViewController

    init(onChooseLibrary: @escaping () -> Void) {
        videoGridViewController = VideoGridViewController(onChooseLibrary: onChooseLibrary)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: SidebarViewController())
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 320

        let gridItem = NSSplitViewItem(viewController: videoGridViewController)
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

    func setLibrary(_ summary: LibrarySummary) {
        videoGridViewController.setLibrary(summary)
    }

    func setLibraryError(_ message: String) {
        videoGridViewController.setError(message)
    }
}
