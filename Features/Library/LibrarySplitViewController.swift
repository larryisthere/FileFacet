import AppKit

@MainActor
final class LibrarySplitViewController: NSSplitViewController {
    private let videoGridViewController: VideoGridViewController
    private let inspectorViewController: InspectorViewController

    init(
        onChooseLibrary: @escaping () -> Void,
        onRescan: @escaping () -> Void,
        onOpenVideo: @escaping (VideoRecord) -> Void,
        onRevealVideo: @escaping (VideoRecord) -> Void,
        onCopyPath: @escaping (VideoRecord) -> Void,
        thumbnailURL: @escaping (VideoRecord) -> URL?
    ) {
        let inspector = InspectorViewController(
            onOpen: onOpenVideo,
            onReveal: onRevealVideo,
            onCopyPath: onCopyPath
        )
        inspectorViewController = inspector
        videoGridViewController = VideoGridViewController(
            onChooseLibrary: onChooseLibrary,
            onRescan: onRescan,
            onOpenVideo: onOpenVideo,
            onSelectionChanged: { [weak inspector] videos in inspector?.setSelection(videos) },
            thumbnailURL: thumbnailURL
        )
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

        let inspectorItem = NSSplitViewItem(viewController: inspectorViewController)
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

    func setVideos(_ videos: [VideoRecord]) {
        videoGridViewController.setVideos(videos)
        inspectorViewController.setSelection([])
    }

    func updateVideo(_ video: VideoRecord) {
        videoGridViewController.updateVideo(video)
    }

    func setScanState(_ state: LibraryScanState) {
        videoGridViewController.setScanState(state)
    }

    func setLibraryError(_ message: String) {
        videoGridViewController.setError(message)
    }
}
