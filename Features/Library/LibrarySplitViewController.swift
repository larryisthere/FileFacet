import AppKit

@MainActor
final class LibrarySplitViewController: NSSplitViewController, NSToolbarDelegate, NSToolbarItemValidation {
    private static let toolbarIdentifier = NSToolbar.Identifier("LibraryToolbar")
    private static let searchItemIdentifier = NSToolbarItem.Identifier("LibrarySearch")
    private static let zoomItemIdentifier = NSToolbarItem.Identifier("LibraryZoom")
    private static let zoomOutItemIdentifier = NSToolbarItem.Identifier("LibraryZoomOut")
    private static let zoomSliderItemIdentifier = NSToolbarItem.Identifier("LibraryZoomSlider")
    private static let zoomInItemIdentifier = NSToolbarItem.Identifier("LibraryZoomIn")
    private static let toggleSidebarItemIdentifier = NSToolbarItem.Identifier("ToggleLibrarySidebar")
    private static let toggleInspectorItemIdentifier = NSToolbarItem.Identifier("ToggleLibraryInspector")
    private static let contextTitleItemIdentifier = NSToolbarItem.Identifier("LibraryContextTitle")
    private static let splitViewAutosaveName = "MainLibrarySplitView"
    private static let splitViewAutosaveDefaultsKey = "NSSplitView Subview Frames \(splitViewAutosaveName)"

    private let videoGridViewController: VideoGridViewController
    private let inspectorViewController: InspectorViewController
    private let sidebarViewController: SidebarViewController
    private let onSearchChanged: (String) -> Void
    private var contextTitle = "全部视频"
    private var contextTagID: String?
    private var contextStatus: String?
    private var isImporting = false
    private var visibleVideoCount = 0
    private var pendingVideoSelectionIDs: [String]?
    private var isPresentingSelectionAlert = false
    private var didApplyInitialLayout = false
    private var shouldApplyInitialLayout = false
    private var isLibraryAvailable = true
    private weak var searchToolbarItem: NSSearchToolbarItem?
    private weak var zoomSlider: NSSlider?
    private weak var zoomOutButton: NSButton?
    private weak var zoomInButton: NSButton?
    private weak var sidebarToggleButton: NSButton?
    private weak var inspectorToggleButton: NSButton?
    private weak var contextTitleView: ToolbarTitleView?
    private weak var sidebarSplitViewItem: NSSplitViewItem?
    private weak var inspectorSplitViewItem: NSSplitViewItem?
    private lazy var libraryToolbar: NSToolbar = {
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }()

    init(
        onCancelImport: @escaping () -> Void,
        onImportDroppedVideos: @escaping ([URL]) -> Void,
        onOpenVideo: @escaping (VideoRecord) -> Void,
        onRevealVideo: @escaping (VideoRecord) -> Void,
        onCopyPath: @escaping (VideoRecord) -> Void,
        onPreviewVideos: @escaping ([VideoRecord]) -> Void,
        thumbnailURL: @escaping (VideoRecord) -> URL?,
        filePath: @escaping (VideoRecord) -> String?,
        onFilterChanged: @escaping (LibraryFilter) -> Void,
        onSearchChanged: @escaping (String) -> Void,
        onCreateTag: @escaping (String, String?) -> Void,
        onRenameTag: @escaping (TagRecord, String) -> Void,
        onDeleteTag: @escaping (TagRecord) -> Void,
        onMoveTags: @escaping ([TagRecord], String?, Int) -> Void,
        onSetTagColor: @escaping (TagRecord, String?) -> Void,
        onMergeTag: @escaping (TagRecord, TagRecord) -> Void,
        onAssignVideos: @escaping (TagRecord, [String]) -> Void,
        onAssignTagID: @escaping (String, [String]) -> Void,
        onApplyTagDraft: @escaping ([TagCreationDraft], [String: Bool], [String], @escaping (Bool) -> Void) -> Void,
        loadTagStates: @escaping ([String], @escaping ([String: TagAssignmentState]) -> Void) -> Void
    ) {
        self.onSearchChanged = onSearchChanged
        let inspector = InspectorViewController(
            onApplyTagDraft: onApplyTagDraft,
            loadTagStates: loadTagStates,
            filePath: filePath
        )
        inspectorViewController = inspector
        sidebarViewController = SidebarViewController(
            onFilterChanged: onFilterChanged,
            onSelectionTitleChanged: { _, _ in },
            onCreateTag: onCreateTag,
            onRenameTag: onRenameTag,
            onDeleteTag: onDeleteTag,
            onMoveTags: onMoveTags,
            onSetColor: onSetTagColor,
            onMergeTag: onMergeTag,
            onAssignVideos: onAssignVideos
        )
        videoGridViewController = VideoGridViewController(
            onOpenVideo: onOpenVideo,
            onRevealVideo: onRevealVideo,
            onCopyPath: onCopyPath,
            onPreviewVideos: onPreviewVideos,
            onSelectionChanged: { [weak inspector] videos in inspector?.setSelection(videos) },
            thumbnailURL: thumbnailURL,
            onAssignTagID: onAssignTagID,
            onCancelImport: onCancelImport,
            onImportDroppedVideos: onImportDroppedVideos
        )
        super.init(nibName: nil, bundle: nil)
        videoGridViewController.onSelectionChanged = { [weak self] videos in
            self?.handleVideoSelectionChange(videos)
        }
        inspectorViewController.onTagApplicationFinished = { [weak self] succeeded in
            guard succeeded else { return }
            self?.syncInspectorSelectionFromGrid()
        }
        sidebarViewController.setSelectionTitleHandler { [weak self] title, tag in
            self?.setContextTitle(title, tagID: tag?.id)
        }
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
        sidebarItem.preferredThicknessFraction = 0.2
        sidebarSplitViewItem = sidebarItem

        let gridItem = NSSplitViewItem(viewController: videoGridViewController)
        gridItem.minimumThickness = 420

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorViewController)
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 380
        inspectorItem.canCollapse = true
        inspectorItem.preferredThicknessFraction = 0.24
        inspectorItem.isCollapsed = false
        inspectorSplitViewItem = inspectorItem

        addSplitViewItem(sidebarItem)
        addSplitViewItem(gridItem)
        addSplitViewItem(inspectorItem)

        splitView.dividerStyle = .thin
        shouldApplyInitialLayout = UserDefaults.standard.object(forKey: Self.splitViewAutosaveDefaultsKey) == nil
        splitView.autosaveName = Self.splitViewAutosaveName
    }

    func makeToolbar() -> NSToolbar {
        libraryToolbar
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateSplitViewToggleState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateWindowTitle()
        guard didApplyInitialLayout == false else { return }
        didApplyInitialLayout = true
        guard shouldApplyInitialLayout else { return }

        let width = splitView.bounds.width
        guard width > 0 else { return }
        splitView.setPosition(220, ofDividerAt: 0)
        splitView.setPosition(max(640, width - 280), ofDividerAt: 1)
    }

    func setVideos(_ videos: [VideoRecord]) {
        visibleVideoCount = videos.count
        videoGridViewController.setVideos(videos)
        updateWindowTitle()
    }

    func setSidebarFilterCounts(_ counts: SidebarFilterCounts) {
        sidebarViewController.setFilterCounts(counts)
    }

    func updateVideo(_ video: VideoRecord) {
        videoGridViewController.updateVideo(video)
    }

    func setTags(_ tags: [TagRecord]) {
        if let contextTagID,
           let selectedTag = tags.first(where: { $0.id == contextTagID }) {
            contextTitle = selectedTag.name
        }
        sidebarViewController.setTags(tags)
        inspectorViewController.setTags(tags)
        updateWindowTitle()
    }

    func refreshTagAssignments() {
        inspectorViewController.refreshTagAssignments()
    }

    var canBeginCreatingRootTag: Bool {
        sidebarViewController.canBeginCreatingRootTag
    }

    func beginCreatingRootTag() {
        sidebarViewController.beginCreatingRootTag()
    }

    private func handleVideoSelectionChange(_ videos: [VideoRecord]) {
        if inspectorViewController.isApplyingTagChanges { return }
        let videoIDs = videos.map(\.id)
        guard inspectorViewController.hasPendingTagChanges,
              videoIDs != inspectorViewController.selectedVideoIDs else {
            inspectorViewController.setSelection(videos)
            return
        }
        pendingVideoSelectionIDs = videoIDs
        videoGridViewController.setSelectedVideoIDs(inspectorViewController.selectedVideoIDs, notify: false)
        presentSelectionChangeConfirmationIfNeeded()
    }

    private func presentSelectionChangeConfirmationIfNeeded() {
        guard isPresentingSelectionAlert == false,
              pendingVideoSelectionIDs != nil,
              let window = view.window else { return }
        isPresentingSelectionAlert = true
        let alert = NSAlert()
        alert.messageText = "应用标签更改？"
        alert.informativeText = "当前视频的标签还有未应用的修改。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "放弃更改")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isPresentingSelectionAlert = false
            switch response {
            case .alertFirstButtonReturn:
                self.inspectorViewController.applyPendingTagChanges { [weak self] succeeded in
                    guard let self else { return }
                    if succeeded { self.commitPendingVideoSelection() }
                    else { self.pendingVideoSelectionIDs = nil }
                }
            case .alertSecondButtonReturn:
                self.inspectorViewController.discardPendingTagChanges()
                self.commitPendingVideoSelection()
            default:
                self.pendingVideoSelectionIDs = nil
            }
        }
    }

    private func commitPendingVideoSelection() {
        guard let videoIDs = pendingVideoSelectionIDs else { return }
        pendingVideoSelectionIDs = nil
        videoGridViewController.setSelectedVideoIDs(videoIDs)
    }

    private func syncInspectorSelectionFromGrid() {
        inspectorViewController.setSelection(videoGridViewController.selectedVideos())
    }

    func setImportState(_ state: LibraryImportState) {
        switch state {
        case .idle:
            isImporting = false
        case .importing:
            isImporting = true
            clearSearchForImport()
        case .completed, .cancelled, .failed:
            isImporting = false
        }
        videoGridViewController.setImportState(state)
        updateToolbarState()
    }

    func setLibraryError(_ message: String) {
        isLibraryAvailable = false
        contextTitle = "全部视频"
        contextTagID = nil
        setContextStatus(message)
        updateToolbarState()
    }

    func setOperationError(_ message: String) {
        setContextStatus(message)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.toggleSidebarItemIdentifier,
            .sidebarTrackingSeparator,
            Self.contextTitleItemIdentifier,
            .flexibleSpace,
            Self.zoomItemIdentifier,
            .space,
            Self.searchItemIdentifier,
            .inspectorTrackingSeparator,
            .flexibleSpace,
            Self.toggleInspectorItemIdentifier,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.toggleSidebarItemIdentifier,
            .sidebarTrackingSeparator,
            Self.contextTitleItemIdentifier,
            .flexibleSpace,
            Self.zoomItemIdentifier,
            .space,
            Self.searchItemIdentifier,
            .inspectorTrackingSeparator,
            .flexibleSpace,
            Self.toggleInspectorItemIdentifier,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.toggleSidebarItemIdentifier:
            return makeSplitViewToggleToolbarItem(
                identifier: itemIdentifier,
                symbolName: "sidebar.left",
                label: "显示或隐藏左侧边栏",
                action: #selector(toggleSidebarFromToolbar(_:)),
                isOn: sidebarSplitViewItem?.isCollapsed == false,
                buttonStore: { [weak self] button in self?.sidebarToggleButton = button }
            )
        case Self.toggleInspectorItemIdentifier:
            return makeSplitViewToggleToolbarItem(
                identifier: itemIdentifier,
                symbolName: "sidebar.right",
                label: "显示或隐藏右侧边栏",
                action: #selector(toggleInspectorFromToolbar(_:)),
                isOn: inspectorSplitViewItem?.isCollapsed == false,
                buttonStore: { [weak self] button in self?.inspectorToggleButton = button }
            )
        case Self.contextTitleItemIdentifier:
            return makeContextTitleToolbarItem(identifier: itemIdentifier)
        case Self.searchItemIdentifier:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "搜索"
            item.paletteLabel = "搜索视频"
            item.toolTip = "按文件名搜索"
            item.searchField.placeholderString = "搜索文件名"
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.widthAnchor.constraint(equalToConstant: 180).isActive = true
            item.isEnabled = isLibraryAvailable
            searchToolbarItem = item
            return item
        case Self.zoomItemIdentifier:
            return makeZoomToolbarItem(identifier: itemIdentifier)
        default:
            return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Self.searchItemIdentifier, Self.zoomItemIdentifier:
            isLibraryAvailable
        default:
            super.validateUserInterfaceItem(item)
        }
    }

    private func makeZoomToolbarItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItemGroup {
        let smallButton = makeToolbarIconButton(
            symbolName: "rectangle.grid.3x2",
            label: "减小缩略图",
            target: self,
            action: #selector(decreaseZoom(_:)),
            buttonType: .momentaryPushIn
        )
        let largeButton = makeToolbarIconButton(
            symbolName: "square.grid.2x2",
            label: "增大缩略图",
            target: self,
            action: #selector(increaseZoom(_:)),
            buttonType: .momentaryPushIn
        )
        smallButton.isEnabled = isLibraryAvailable
        largeButton.isEnabled = isLibraryAvailable
        zoomOutButton = smallButton
        zoomInButton = largeButton

        let slider = NSSlider(
            value: VideoGridViewController.persistedGridItemWidth(),
            minValue: VideoGridViewController.minimumGridItemWidth,
            maxValue: VideoGridViewController.maximumGridItemWidth,
            target: self,
            action: #selector(changeZoom(_:))
        )
        slider.controlSize = .small
        slider.toolTip = "调整缩略图大小"
        slider.setAccessibilityLabel("缩略图大小")
        slider.widthAnchor.constraint(equalToConstant: 70).isActive = true
        slider.isEnabled = isLibraryAvailable
        zoomSlider = slider

        let zoomOutItem = NSToolbarItem(itemIdentifier: Self.zoomOutItemIdentifier)
        zoomOutItem.label = "减小缩略图"
        zoomOutItem.toolTip = "减小缩略图"
        zoomOutItem.view = smallButton

        let sliderItem = NSToolbarItem(itemIdentifier: Self.zoomSliderItemIdentifier)
        sliderItem.label = "缩略图大小"
        sliderItem.toolTip = "调整缩略图大小"
        sliderItem.view = slider

        let zoomInItem = NSToolbarItem(itemIdentifier: Self.zoomInItemIdentifier)
        zoomInItem.label = "增大缩略图"
        zoomInItem.toolTip = "增大缩略图"
        zoomInItem.view = largeButton

        let group = NSToolbarItemGroup(itemIdentifier: identifier)
        group.label = "缩略图大小"
        group.paletteLabel = "缩略图大小"
        group.toolTip = "调整缩略图大小"
        group.controlRepresentation = .expanded
        group.subitems = [zoomOutItem, sliderItem, zoomInItem]
        return group
    }

    private func makeContextTitleToolbarItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let titleView = ToolbarTitleView()
        contextTitleView = titleView

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "当前分类"
        item.paletteLabel = "当前分类"
        item.isBordered = false
        if #available(macOS 26.0, *) {
            item.style = .plain
        }
        item.view = titleView
        updateWindowTitle()
        return item
    }

    private func makeSplitViewToggleToolbarItem(
        identifier: NSToolbarItem.Identifier,
        symbolName: String,
        label: String,
        action: Selector,
        isOn: Bool,
        buttonStore: (NSButton) -> Void
    ) -> NSToolbarItem {
        let button = makeToolbarIconButton(
            symbolName: symbolName,
            label: label,
            target: self,
            action: action,
            buttonType: .toggle
        )
        button.state = isOn ? .on : .off
        buttonStore(button)

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.paletteLabel = label
        item.toolTip = label
        item.view = button
        return item
    }

    private func makeToolbarIconButton(
        symbolName: String,
        label: String,
        target: AnyObject?,
        action: Selector,
        buttonType: NSButton.ButtonType
    ) -> NSButton {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: target, action: action)
        button.title = ""
        button.imagePosition = .imageOnly
        button.bezelStyle = .toolbar
        button.setButtonType(buttonType)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    private func updateToolbarState() {
        searchToolbarItem?.isEnabled = isLibraryAvailable
        zoomSlider?.isEnabled = isLibraryAvailable
        zoomOutButton?.isEnabled = isLibraryAvailable
        zoomInButton?.isEnabled = isLibraryAvailable
        libraryToolbar.validateVisibleItems()
    }

    private func updateSplitViewToggleState() {
        if let sidebarSplitViewItem {
            sidebarToggleButton?.state = sidebarSplitViewItem.isCollapsed ? .off : .on
        }
        if let inspectorSplitViewItem {
            inspectorToggleButton?.state = inspectorSplitViewItem.isCollapsed ? .off : .on
        }
    }

    private func setContextStatus(_ message: String?) {
        contextStatus = message
        updateWindowTitle()
    }

    private func setContextTitle(_ title: String, tagID: String?) {
        contextTitle = title
        contextTagID = tagID
        if isImporting == false {
            contextStatus = nil
            videoGridViewController.clearFinishedImportState()
        }
        updateWindowTitle()
    }

    private func clearSearchForImport() {
        searchToolbarItem?.searchField.stringValue = ""
        onSearchChanged("")
    }

    private func updateWindowTitle() {
        var subtitleParts: [String] = []
        if isLibraryAvailable {
            subtitleParts.append("\(visibleVideoCount) 个视频")
        }
        if let contextStatus, contextStatus.isEmpty == false {
            subtitleParts.append(contextStatus)
        }
        let subtitle = subtitleParts.joined(separator: " · ")
        contextTitleView?.update(title: contextTitle, subtitle: subtitle)
        guard let window = viewIfLoaded?.window else { return }
        window.title = contextTitle
        window.subtitle = subtitle
        window.titleVisibility = .hidden
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        onSearchChanged(sender.stringValue)
    }

    @objc private func toggleSidebarFromToolbar(_ sender: NSButton) {
        guard let sidebarSplitViewItem else { return }
        sidebarSplitViewItem.animator().isCollapsed = sender.state == .off
    }

    @objc private func toggleInspectorFromToolbar(_ sender: NSButton) {
        guard let inspectorSplitViewItem else { return }
        inspectorSplitViewItem.animator().isCollapsed = sender.state == .off
    }

    @objc private func changeZoom(_ sender: NSSlider) {
        videoGridViewController.setGridItemWidth(sender.doubleValue)
    }

    @objc private func decreaseZoom(_ sender: NSButton) {
        adjustZoom(by: -10)
    }

    @objc private func increaseZoom(_ sender: NSButton) {
        adjustZoom(by: 10)
    }

    private func adjustZoom(by delta: Double) {
        guard let slider = zoomSlider else { return }
        slider.doubleValue = min(slider.maxValue, max(slider.minValue, slider.doubleValue + delta))
        changeZoom(slider)
    }

}

@MainActor
private final class ToolbarTitleView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        addSubview(titleLabel)
        addSubview(subtitleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: -1),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 200, height: 36)
    }

    func update(title: String, subtitle: String) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
    }
}
