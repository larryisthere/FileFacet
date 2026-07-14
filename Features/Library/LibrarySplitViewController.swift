import AppKit

@MainActor
final class LibrarySplitViewController: NSSplitViewController {
    private let videoGridViewController: VideoGridViewController
    private let inspectorViewController: InspectorViewController
    private let sidebarViewController: SidebarViewController

    init(
        onChooseLibrary: @escaping () -> Void,
        onRescan: @escaping () -> Void,
        onOpenVideo: @escaping (VideoRecord) -> Void,
        onRevealVideo: @escaping (VideoRecord) -> Void,
        onCopyPath: @escaping (VideoRecord) -> Void,
        thumbnailURL: @escaping (VideoRecord) -> URL?,
        onFilterChanged: @escaping (LibraryFilter) -> Void,
        onSearchChanged: @escaping (String) -> Void,
        onCreateTag: @escaping (String, String?) -> Void,
        onRenameTag: @escaping (TagRecord, String) -> Void,
        onDeleteTag: @escaping (TagRecord) -> Void,
        onMoveTag: @escaping (TagRecord, String?, Int) -> Void,
        onSetTagColor: @escaping (TagRecord, String?) -> Void,
        onMergeTag: @escaping (TagRecord, TagRecord) -> Void,
        onAssignVideos: @escaping (TagRecord, [String]) -> Void,
        onAssignTagID: @escaping (String, [String]) -> Void,
        onSetTagAssignment: @escaping (TagRecord, [String], Bool) -> Void,
        loadTagStates: @escaping ([String], @escaping ([String: TagAssignmentState]) -> Void) -> Void
    ) {
        let inspector = InspectorViewController(
            onOpen: onOpenVideo,
            onReveal: onRevealVideo,
            onCopyPath: onCopyPath,
            onSetTagAssignment: onSetTagAssignment,
            loadTagStates: loadTagStates
        )
        inspectorViewController = inspector
        sidebarViewController = SidebarViewController(
            onFilterChanged: onFilterChanged,
            onCreateTag: onCreateTag,
            onRenameTag: onRenameTag,
            onDeleteTag: onDeleteTag,
            onMoveTag: onMoveTag,
            onSetColor: onSetTagColor,
            onMergeTag: onMergeTag,
            onAssignVideos: onAssignVideos
        )
        videoGridViewController = VideoGridViewController(
            onChooseLibrary: onChooseLibrary,
            onRescan: onRescan,
            onOpenVideo: onOpenVideo,
            onSelectionChanged: { [weak inspector] videos in inspector?.setSelection(videos) },
            thumbnailURL: thumbnailURL,
            onAssignTagID: onAssignTagID,
            onSearchChanged: onSearchChanged
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
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

    func setTags(_ tags: [TagRecord]) {
        sidebarViewController.setTags(tags)
        inspectorViewController.setTags(tags)
    }

    func refreshTagAssignments() {
        inspectorViewController.refreshTagAssignments()
    }

    func setScanState(_ state: LibraryScanState) {
        videoGridViewController.setScanState(state)
    }

    func setLibraryError(_ message: String) {
        videoGridViewController.setError(message)
    }
}
