import AppKit

@MainActor
final class LibrarySplitViewController: NSSplitViewController, NSToolbarDelegate, NSToolbarItemValidation {
    private enum NavigationTarget {
        case filter(LibraryFilter)
        case smartCollection(SmartCollectionRecord)
    }

    private static let toolbarIdentifier = NSToolbar.Identifier("LibraryToolbar")
    private static let settingsToolbarIdentifier = NSToolbar.Identifier("SettingsToolbar")
    private static let searchItemIdentifier = NSToolbarItem.Identifier("LibrarySearch")
    private static let zoomItemIdentifier = NSToolbarItem.Identifier("LibraryZoom")
    private static let zoomOutItemIdentifier = NSToolbarItem.Identifier("LibraryZoomOut")
    private static let zoomSliderItemIdentifier = NSToolbarItem.Identifier("LibraryZoomSlider")
    private static let zoomInItemIdentifier = NSToolbarItem.Identifier("LibraryZoomIn")
    private static let toggleSidebarItemIdentifier = NSToolbarItem.Identifier("ToggleLibrarySidebar")
    private static let toggleInspectorItemIdentifier = NSToolbarItem.Identifier("ToggleLibraryInspector")
    private static let contextTitleItemIdentifier = NSToolbarItem.Identifier("LibraryContextTitle")
    private static let settingsBackItemIdentifier = NSToolbarItem.Identifier("SettingsBack")
    private static let settingsTitleItemIdentifier = NSToolbarItem.Identifier("SettingsTitle")
    private static let splitViewAutosaveName = "MainLibrarySplitView"
    private static let splitViewAutosaveDefaultsKey = "NSSplitView Subview Frames \(splitViewAutosaveName)"

    private let videoGridViewController: VideoGridViewController
    private let ruleBarViewController = LibraryRuleBarViewController()
    private let libraryContentViewController: LibraryContentViewController
    private let inspectorViewController: InspectorViewController
    private let sidebarViewController: SidebarViewController
    private let settingsViewController: NSViewController
    private let onQueryChanged: (LibraryQueryRequest, Bool) -> Void
    private let onCreateSmartCollection: (
        String,
        LibraryQueryRule,
        @escaping (SmartCollectionRecord?) -> Void
    ) -> Void
    private let onUpdateSmartCollection: (
        String,
        String?,
        LibraryQueryRule?,
        @escaping (SmartCollectionRecord?) -> Void
    ) -> Void
    private let onDeleteSmartCollection: (String, @escaping (Bool) -> Void) -> Void
    private let onEndVideoRemovalUndo: () -> Void
    private var contextTitle = String(localized: .libraryAllVideos)
    private var contextTagID: String?
    private var contextStatus: String?
    private var isImporting = false
    private var visibleVideoCount = 0
    private var tags: [TagRecord] = []
    private var smartCollections: [SmartCollectionRecord] = []
    private var currentBaseFilter: LibraryFilter = .all
    private var temporaryFilenameSearch = ""
    private var currentRule = LibraryQueryRule.standard
    private var selectedSmartCollection: SmartCollectionRecord?
    private var pendingNavigationTarget: NavigationTarget?
    private var isPresentingSmartCollectionAlert = false
    private var pendingVideoSelectionIDs: [String]?
    private var pendingVideoRevealRequest: VideoRevealRequest?
    private var resetBrowsingStateForNextVideoUpdate = false
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
    private var sidebarSplitViewItem: NSSplitViewItem?
    private var gridSplitViewItem: NSSplitViewItem?
    private var inspectorSplitViewItem: NSSplitViewItem?
    private var settingsSplitViewItem: NSSplitViewItem?
    private var isShowingSettings = false
    private var sidebarWasCollapsedBeforeSettings = false
    private var inspectorWasCollapsedBeforeSettings = false
    private lazy var libraryToolbar: NSToolbar = {
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }()
    private lazy var settingsToolbar: NSToolbar = {
        let toolbar = NSToolbar(identifier: Self.settingsToolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }()

    init(
        onCancelImport: @escaping () -> Void,
        onImportDroppedItems: @escaping ([URL]) -> Void,
        onRemoveVideos: @escaping ([String], @escaping (Bool) -> Void) -> Void,
        onRelinkVideo: @escaping (VideoRecord) -> Void,
        onRetryRelinkVideo: @escaping (String) -> Void,
        onUndoLastMutation: @escaping () -> Void,
        onEndVideoRemovalUndo: @escaping () -> Void,
        onOpenVideo: @escaping (VideoRecord) -> Void,
        onRevealVideo: @escaping (VideoRecord) -> Void,
        onCopyPath: @escaping (VideoRecord) -> Void,
        onPreviewVideos: @escaping ([VideoRecord]) -> Void,
        thumbnailURL: @escaping (VideoRecord) -> URL?,
        filePath: @escaping (VideoRecord) -> String?,
        offlineSourceName: @escaping (VideoRecord) -> String?,
        onQueryChanged: @escaping (LibraryQueryRequest, Bool) -> Void,
        onCreateSmartCollection: @escaping (
            String,
            LibraryQueryRule,
            @escaping (SmartCollectionRecord?) -> Void
        ) -> Void,
        onUpdateSmartCollection: @escaping (
            String,
            String?,
            LibraryQueryRule?,
            @escaping (SmartCollectionRecord?) -> Void
        ) -> Void,
        onDeleteSmartCollection: @escaping (String, @escaping (Bool) -> Void) -> Void,
        onCreateTag: @escaping (String, String?) -> Void,
        onRenameTag: @escaping (TagRecord, String) -> Void,
        onDeleteTag: @escaping (TagRecord) -> Void,
        onMoveTags: @escaping ([TagRecord], String?, Int) -> Void,
        onSetTagColor: @escaping (TagRecord, String?) -> Void,
        onMergeTag: @escaping (TagRecord, TagRecord) -> Void,
        onAssignVideos: @escaping (TagRecord, [String]) -> Void,
        onAssignTagID: @escaping (String, [String]) -> Void,
        onApplyTagDraft: @escaping ([TagCreationDraft], [String: Bool], [String], @escaping (Bool) -> Void) -> Void,
        loadTagStates: @escaping ([String], @escaping ([String: TagAssignmentState]) -> Void) -> Void,
        settingsViewController: NSViewController
    ) {
        self.onQueryChanged = onQueryChanged
        self.onCreateSmartCollection = onCreateSmartCollection
        self.onUpdateSmartCollection = onUpdateSmartCollection
        self.onDeleteSmartCollection = onDeleteSmartCollection
        self.onEndVideoRemovalUndo = onEndVideoRemovalUndo
        self.settingsViewController = settingsViewController
        let inspector = InspectorViewController(
            onApplyTagDraft: onApplyTagDraft,
            loadTagStates: loadTagStates,
            filePath: filePath,
            offlineSourceName: offlineSourceName,
            onRelinkVideo: onRelinkVideo,
            onRemoveVideos: onRemoveVideos
        )
        inspectorViewController = inspector
        sidebarViewController = SidebarViewController(
            onFilterChanged: { _ in },
            onSmartCollectionSelected: { _ in },
            onRenameSmartCollection: { _, _ in },
            onDeleteSmartCollection: { _ in },
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
            onRelinkVideo: onRelinkVideo,
            onRetryRelinkVideo: onRetryRelinkVideo,
            onPreviewVideos: onPreviewVideos,
            onSelectionChanged: { [weak inspector] videos in inspector?.setSelection(videos) },
            thumbnailURL: thumbnailURL,
            onAssignTagID: onAssignTagID,
            onCancelImport: onCancelImport,
            onImportDroppedItems: onImportDroppedItems,
            onRemoveVideos: { [weak inspector] videoIDs, completion in
                let pendingDraft = inspector?.takePendingTagChanges()
                onRemoveVideos(videoIDs) { succeeded in
                    if succeeded == false, let pendingDraft {
                        inspector?.restorePendingTagChanges(pendingDraft)
                    }
                    completion(succeeded)
                }
            },
            onUndoLastMutation: onUndoLastMutation,
            onDismissNotification: onEndVideoRemovalUndo
        )
        libraryContentViewController = LibraryContentViewController(
            ruleBarViewController: ruleBarViewController,
            videoGridViewController: videoGridViewController
        )
        super.init(nibName: nil, bundle: nil)
        inspectorViewController.onVideoRemoved = { [weak self] count in
            self?.videoGridViewController.showVideoRemovalUndo(videoCount: count)
        }
        videoGridViewController.onSelectionChanged = { [weak self] videos in
            self?.handleVideoSelectionChange(videos)
        }
        videoGridViewController.onViewVideos = { [weak self] request in
            self?.viewVideos(request)
        }
        inspectorViewController.onTagApplicationFinished = { [weak self] succeeded in
            guard succeeded else { return }
            self?.syncInspectorSelectionFromGrid()
        }
        sidebarViewController.setNavigationHandlers(
            filter: { [weak self] filter in self?.requestNavigation(to: .filter(filter)) },
            smartCollection: { [weak self] collection in
                self?.requestNavigation(to: .smartCollection(collection))
            },
            renameSmartCollection: { [weak self] collection, name in
                self?.renameSmartCollection(collection, to: name)
            },
            deleteSmartCollection: { [weak self] collection in
                self?.presentDeleteSmartCollection(collection)
            }
        )
        configureRuleBarCallbacks()
    }

    func showRestoredVideos(_ videoIDs: [String]) {
        videoGridViewController.showRestoredVideos(videoIDs)
    }

    func offerVideoRemovalUndoForCurrentStatus() {
        videoGridViewController.offerVideoRemovalUndoForCurrentStatus()
    }

    func removeVideoRemovalUndoOffer() {
        videoGridViewController.removeVideoRemovalUndoOffer()
    }

    var canUseRuleCommands: Bool {
        isShowingSettings == false && isLibraryAvailable
    }

    func focusFilenameSearch() {
        guard canUseRuleCommands, let searchField = searchToolbarItem?.searchField else { return }
        view.window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func presentAddFilterMenu() {
        guard canUseRuleCommands else { return }
        ruleBarViewController.presentAddFilterMenu()
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

        let gridItem = NSSplitViewItem(viewController: libraryContentViewController)
        gridItem.minimumThickness = 420
        gridSplitViewItem = gridItem

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorViewController)
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 380
        inspectorItem.canCollapse = true
        inspectorItem.preferredThicknessFraction = 0.24
        inspectorItem.isCollapsed = false
        inspectorSplitViewItem = inspectorItem

        let settingsItem = NSSplitViewItem(viewController: settingsViewController)
        settingsItem.minimumThickness = 420
        settingsItem.canCollapse = false
        settingsSplitViewItem = settingsItem

        addSplitViewItem(sidebarItem)
        addSplitViewItem(gridItem)
        addSplitViewItem(inspectorItem)

        splitView.dividerStyle = .thin
        shouldApplyInitialLayout = UserDefaults.standard.object(forKey: Self.splitViewAutosaveDefaultsKey) == nil
        splitView.autosaveName = Self.splitViewAutosaveName
    }

    func makeToolbar() -> NSToolbar {
        isShowingSettings ? settingsToolbar : libraryToolbar
    }

    func showSettings() {
        loadViewIfNeeded()
        guard isShowingSettings == false,
              let sidebarSplitViewItem,
              let gridSplitViewItem,
              let inspectorSplitViewItem,
              let settingsSplitViewItem else { return }
        isShowingSettings = true
        sidebarViewController.setPresetShortcutHintsVisible(false)
        sidebarWasCollapsedBeforeSettings = sidebarSplitViewItem.isCollapsed
        inspectorWasCollapsedBeforeSettings = inspectorSplitViewItem.isCollapsed
        removeSplitViewItem(inspectorSplitViewItem)
        removeSplitViewItem(gridSplitViewItem)
        removeSplitViewItem(sidebarSplitViewItem)
        addSplitViewItem(settingsSplitViewItem)
        view.window?.toolbar = settingsToolbar
        view.window?.title = String(localized: .toolbarSettings)
        view.window?.subtitle = ""
        updateSplitViewToggleState()
    }

    private func showLibrary() {
        guard isShowingSettings,
              let sidebarSplitViewItem,
              let gridSplitViewItem,
              let inspectorSplitViewItem,
              let settingsSplitViewItem else { return }
        isShowingSettings = false
        removeSplitViewItem(settingsSplitViewItem)
        addSplitViewItem(sidebarSplitViewItem)
        addSplitViewItem(gridSplitViewItem)
        addSplitViewItem(inspectorSplitViewItem)
        sidebarSplitViewItem.isCollapsed = sidebarWasCollapsedBeforeSettings
        inspectorSplitViewItem.isCollapsed = inspectorWasCollapsedBeforeSettings
        view.window?.toolbar = libraryToolbar
        updateWindowTitle()
        DispatchQueue.main.async { [weak self] in
            self?.updateSplitViewToggleState()
        }
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
        let resetBrowsingState = resetBrowsingStateForNextVideoUpdate
        resetBrowsingStateForNextVideoUpdate = false
        videoGridViewController.setVideos(videos, resetBrowsingState: resetBrowsingState)
        if let request = pendingVideoRevealRequest,
           videoGridViewController.selectAndRevealVideos(ids: request.videoIDs) {
            pendingVideoRevealRequest = nil
        }
        updateWindowTitle()
    }

    func setOperationStatus(_ status: LibraryOperationStatus?) {
        videoGridViewController.setOperationStatus(status)
    }

    func setRelinkingVideoID(_ videoID: String?) {
        videoGridViewController.setRelinkingVideoID(videoID)
        inspectorViewController.setRelinkingVideoID(videoID)
    }

    func setSidebarFilterCounts(_ counts: SidebarFilterCounts) {
        sidebarViewController.setFilterCounts(counts)
    }

    func setPresetShortcutHintsVisible(_ visible: Bool) {
        sidebarViewController.setPresetShortcutHintsVisible(visible && isShowingSettings == false)
    }

    var canNavigateLibraryPresets: Bool {
        isLibraryAvailable && isShowingSettings == false
    }

    func navigateToPreset(_ filter: LibraryFilter) {
        guard canNavigateLibraryPresets else { return }
        requestNavigation(to: .filter(filter))
    }

    func setFilterFromSystem(_ filter: LibraryFilter) {
        if isSameNavigationTarget(.filter(filter)) == false {
            onEndVideoRemovalUndo()
            resetBrowsingStateForNextVideoUpdate = true
        }
        currentBaseFilter = filter
        selectedSmartCollection = nil
        sidebarViewController.selectFilter(filter)
        updateContext(for: filter)
        updateInspectorBrowsingContext()
        refreshRuleBar()
    }

    func updateVideo(_ video: VideoRecord) {
        videoGridViewController.updateVideo(video)
    }

    func setTags(_ tags: [TagRecord]) {
        self.tags = tags
        if let contextTagID,
           let selectedTag = tags.first(where: { $0.id == contextTagID }) {
            contextTitle = selectedTag.name
        }
        sidebarViewController.setTags(tags)
        inspectorViewController.setTags(tags)
        refreshRuleBar()
        updateWindowTitle()
    }

    func setSmartCollections(_ collections: [SmartCollectionRecord]) {
        smartCollections = collections
        if let selectedID = selectedSmartCollection?.id,
           let updated = collections.first(where: { $0.id == selectedID }) {
            selectedSmartCollection = updated
        }
        sidebarViewController.setSmartCollections(collections)
        refreshRuleBar()
    }

    private var smartCollectionIsDirty: Bool {
        guard let selectedSmartCollection else { return false }
        return currentRule.normalized() != selectedSmartCollection.rule.normalized()
    }

    private func configureRuleBarCallbacks() {
        ruleBarViewController.onRuleChanged = { [weak self] rule in
            guard let self else { return }
            currentRule = rule.normalized()
            refreshRuleBar()
            applyCurrentQuery(debounce: true)
        }
        ruleBarViewController.onClearTemporarySearch = { [weak self] in
            self?.setTemporaryFilenameSearch("")
        }
        ruleBarViewController.onClearRules = { [weak self] in
            guard let self else { return }
            currentRule = .standard
            setTemporaryFilenameSearch("", applyQuery: false)
            refreshRuleBar()
            applyCurrentQuery()
        }
        ruleBarViewController.onSaveAs = { [weak self] in
            self?.presentSaveSmartCollection()
        }
        ruleBarViewController.onRevert = { [weak self] in
            guard let self, let selectedSmartCollection else { return }
            currentRule = selectedSmartCollection.rule
            refreshRuleBar()
            applyCurrentQuery()
        }
        ruleBarViewController.onUpdate = { [weak self] in
            self?.updateCurrentSmartCollection()
        }
    }

    private func refreshRuleBar() {
        ruleBarViewController.configure(LibraryRuleBarContext(
            scopeTitle: selectedSmartCollection == nil ? currentScopeTitle : nil,
            temporarySearch: temporaryFilenameSearch,
            rule: currentRule,
            presetSort: selectedSmartCollection == nil ? currentBaseFilter.presetSort : nil,
            tags: tags,
            smartCollection: selectedSmartCollection,
            isDirty: smartCollectionIsDirty,
            hasPersistableBaseScope: hasPersistableBaseScope,
            canSaveAsSmartCollection: canSaveCurrentContext
        ))
    }

    private var hasPersistableBaseScope: Bool {
        guard selectedSmartCollection == nil else { return false }
        switch currentBaseFilter {
        case .tag, .tags, .untagged, .recent:
            return true
        case .all, .unavailable:
            return false
        }
    }

    private var canSaveCurrentContext: Bool {
        selectedSmartCollection != nil || currentBaseFilter != .unavailable
    }

    private var currentScopeTitle: String? {
        switch currentBaseFilter {
        case let .tag(tagID):
            tags.first(where: { $0.id == tagID })?.name
        case let .tags(tagIDs):
            String(localized: .selectionTagCount(tagIDs.count))
        case .all:
            nil
        case .untagged:
            String(localized: .libraryUntagged)
        case .recent:
            String(localized: .libraryRecent)
        case .unavailable:
            String(localized: "library.unavailable", defaultValue: "Unavailable Videos")
        }
    }

    private func applyCurrentQuery(debounce: Bool = false) {
        onQueryChanged(
            LibraryQueryRequest(
                baseFilter: selectedSmartCollection == nil ? currentBaseFilter : .all,
                temporaryFilenameSearch: temporaryFilenameSearch,
                rule: currentRule
            ),
            debounce
        )
    }

    private func setTemporaryFilenameSearch(
        _ value: String,
        applyQuery: Bool = true
    ) {
        temporaryFilenameSearch = value
        if searchToolbarItem?.searchField.stringValue != value {
            searchToolbarItem?.searchField.stringValue = value
        }
        refreshRuleBar()
        if applyQuery { applyCurrentQuery(debounce: true) }
    }

    private func requestNavigation(to target: NavigationTarget) {
        guard isSameNavigationTarget(target) == false else {
            restoreCurrentSidebarSelection()
            return
        }
        if smartCollectionIsDirty {
            pendingNavigationTarget = target
            restoreCurrentSidebarSelection()
            presentSmartCollectionLeaveConfirmation()
            return
        }
        performNavigation(to: target)
    }

    private func viewVideos(_ request: VideoRevealRequest) {
        guard request.videoIDs.isEmpty == false else { return }
        pendingVideoRevealRequest = request
        let target = NavigationTarget.filter(request.destination)
        if isSameNavigationTarget(target) {
            performNavigation(to: target)
            return
        }
        requestNavigation(to: target)
    }

    private func isSameNavigationTarget(_ target: NavigationTarget) -> Bool {
        switch target {
        case let .filter(filter):
            return selectedSmartCollection == nil && currentBaseFilter == filter
        case let .smartCollection(collection):
            return selectedSmartCollection?.id == collection.id
        }
    }

    private func performNavigation(to target: NavigationTarget) {
        pendingNavigationTarget = nil
        onEndVideoRemovalUndo()
        let isPendingVideoRevealTarget: Bool
        switch target {
        case let .filter(filter):
            isPendingVideoRevealTarget = pendingVideoRevealRequest?.destination == filter
        case .smartCollection:
            isPendingVideoRevealTarget = false
        }
        if isPendingVideoRevealTarget {
            currentRule = .standard
            setTemporaryFilenameSearch("", applyQuery: false)
        } else {
            pendingVideoRevealRequest = nil
            resetBrowsingStateForNextVideoUpdate = true
        }
        switch target {
        case let .filter(filter):
            if selectedSmartCollection != nil {
                currentRule = .standard
            }
            selectedSmartCollection = nil
            currentBaseFilter = filter
            sidebarViewController.selectFilter(filter)
            updateContext(for: filter)
        case let .smartCollection(collection):
            selectedSmartCollection = collection
            currentBaseFilter = .all
            currentRule = collection.rule
            setTemporaryFilenameSearch("", applyQuery: false)
            sidebarViewController.selectSmartCollection(id: collection.id)
            setContextTitle(collection.name, tagID: nil)
        }
        updateInspectorBrowsingContext()
        refreshRuleBar()
        applyCurrentQuery()
    }

    private func updateInspectorBrowsingContext() {
        inspectorViewController.setBrowsingContext(
            selectedSmartCollection == nil && currentBaseFilter == .unavailable
                ? .unavailable
                : .library
        )
    }

    private func restoreCurrentSidebarSelection() {
        if let selectedSmartCollection {
            sidebarViewController.selectSmartCollection(id: selectedSmartCollection.id)
        } else {
            sidebarViewController.selectFilter(currentBaseFilter)
        }
    }

    private func updateContext(for filter: LibraryFilter) {
        switch filter {
        case .all:
            setContextTitle(String(localized: .libraryAllVideos), tagID: nil)
        case .untagged:
            setContextTitle(String(localized: .libraryUntagged), tagID: nil)
        case .recent:
            setContextTitle(String(localized: .libraryRecent), tagID: nil)
        case .unavailable:
            setContextTitle(String(
                localized: "library.unavailable",
                defaultValue: "Unavailable Videos"
            ), tagID: nil)
        case let .tag(tagID):
            let title = tags.first(where: { $0.id == tagID })?.name
                ?? String(localized: "filter.deletedTag", defaultValue: "Deleted Tag")
            setContextTitle(title, tagID: tagID)
        case let .tags(tagIDs):
            setContextTitle(String(localized: .selectionTagCount(tagIDs.count)), tagID: nil)
        }
    }

    private func presentSmartCollectionLeaveConfirmation() {
        guard isPresentingSmartCollectionAlert == false,
              let selectedSmartCollection,
              let window = view.window else { return }
        isPresentingSmartCollectionAlert = true
        let alert = NSAlert()
        alert.messageText = String(
            localized: "smartCollection.leave.title",
            defaultValue: "Save changes to “\(selectedSmartCollection.name)”?"
        )
        alert.informativeText = String(
            localized: "smartCollection.leave.detail",
            defaultValue: "The current results use rules that have not been saved."
        )
        alert.addButton(withTitle: String(
            localized: "smartCollection.leave.update",
            defaultValue: "Update and Continue"
        ))
        alert.addButton(withTitle: String(
            localized: "smartCollection.leave.discard",
            defaultValue: "Discard Changes"
        ))
        alert.addButton(withTitle: String(localized: .actionCancel))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            isPresentingSmartCollectionAlert = false
            switch response {
            case .alertFirstButtonReturn:
                updateCurrentSmartCollection { [weak self] succeeded in
                    guard let self else { return }
                    if succeeded, let target = pendingNavigationTarget {
                        performNavigation(to: target)
                    } else {
                        pendingNavigationTarget = nil
                        pendingVideoRevealRequest = nil
                        restoreCurrentSidebarSelection()
                    }
                }
            case .alertSecondButtonReturn:
                if let target = pendingNavigationTarget {
                    performNavigation(to: target)
                }
            default:
                pendingNavigationTarget = nil
                pendingVideoRevealRequest = nil
                restoreCurrentSidebarSelection()
            }
        }
    }

    private func ruleForSavingCurrentContext() -> LibraryQueryRule {
        var rule = currentRule
        if selectedSmartCollection == nil {
            switch currentBaseFilter {
            case let .tag(tagID):
                rule.requiredTagIDs.append(tagID)
            case let .tags(tagIDs):
                rule.requiredTagIDs.append(contentsOf: tagIDs)
            case .untagged:
                rule.requiredConditions.append(.untagged)
            case .recent:
                rule.requiredConditions.append(.addedWithinDays(30))
            case .all, .unavailable:
                break
            }
        }
        let search = temporaryFilenameSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if search.isEmpty == false {
            rule.filenameContains.append(search)
        }
        return rule.normalized()
    }

    private func presentSaveSmartCollection(
        suggestedName: String? = nil,
        validationMessage: String? = nil
    ) {
        guard canSaveCurrentContext else { return }
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(
            localized: "smartCollection.save.title",
            defaultValue: "Save as Smart Collection"
        )
        alert.informativeText = validationMessage ?? String(
            localized: "smartCollection.save.detail",
            defaultValue: "The current scope, filename search, filters, and sort order will be saved."
        )
        let field = NSTextField(string: suggestedName
            ?? selectedSmartCollection.map {
                String(
                    localized: "smartCollection.copyName",
                    defaultValue: "\($0.name) Copy"
                )
            }
            ?? String(localized: "smartCollection.defaultName", defaultValue: "New Smart Collection"))
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: .actionSave))
        alert.addButton(withTitle: String(localized: .actionCancel))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedName = normalizedSmartCollectionName(name)
            let duplicate = smartCollections.contains {
                normalizedSmartCollectionName($0.name) == normalizedName
            }
            guard name.isEmpty == false, duplicate == false else {
                let message = name.isEmpty
                    ? String(localized: "smartCollection.name.empty", defaultValue: "Enter a name.")
                    : String(
                        localized: "smartCollection.name.duplicate",
                        defaultValue: "A smart collection with this name already exists."
                    )
                DispatchQueue.main.async { [weak self] in
                    self?.presentSaveSmartCollection(
                        suggestedName: name,
                        validationMessage: message
                    )
                }
                return
            }
            let savedRule = ruleForSavingCurrentContext()
            onCreateSmartCollection(name, savedRule) { [weak self] collection in
                guard let self, let collection else { return }
                selectedSmartCollection = collection
                currentBaseFilter = .all
                currentRule = collection.rule
                setTemporaryFilenameSearch("", applyQuery: false)
                sidebarViewController.selectSmartCollection(id: collection.id)
                setContextTitle(collection.name, tagID: nil)
                updateInspectorBrowsingContext()
                refreshRuleBar()
                applyCurrentQuery()
            }
        }
    }

    private func updateCurrentSmartCollection(
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let selectedSmartCollection else {
            completion?(false)
            return
        }
        onUpdateSmartCollection(
            selectedSmartCollection.id,
            nil,
            currentRule
        ) { [weak self] collection in
            guard let self else {
                completion?(false)
                return
            }
            guard let collection else {
                completion?(false)
                return
            }
            self.selectedSmartCollection = collection
            currentRule = collection.rule
            refreshRuleBar()
            applyCurrentQuery()
            completion?(true)
        }
    }

    private func renameSmartCollection(_ collection: SmartCollectionRecord, to name: String) {
        onUpdateSmartCollection(collection.id, name, nil) { [weak self] updated in
            guard let self, let updated else { return }
            if selectedSmartCollection?.id == updated.id {
                selectedSmartCollection = updated
                setContextTitle(updated.name, tagID: nil)
            }
            refreshRuleBar()
        }
    }

    private func presentDeleteSmartCollection(_ collection: SmartCollectionRecord) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(
            localized: "smartCollection.delete.title",
            defaultValue: "Delete “\(collection.name)”?"
        )
        alert.informativeText = String(
            localized: "smartCollection.delete.detail",
            defaultValue: "Videos, files, and tags will not be changed."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(
            localized: "smartCollection.delete.action",
            defaultValue: "Delete"
        ))
        alert.addButton(withTitle: String(localized: .actionCancel))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            onDeleteSmartCollection(collection.id) { [weak self] succeeded in
                guard let self, succeeded else { return }
                if selectedSmartCollection?.id == collection.id {
                    selectedSmartCollection = nil
                    currentBaseFilter = .all
                    currentRule = .standard
                    sidebarViewController.selectFilter(.all)
                    updateContext(for: .all)
                    updateInspectorBrowsingContext()
                    refreshRuleBar()
                    applyCurrentQuery()
                }
            }
        }
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
        alert.messageText = String(localized: .unsavedTagsTitle)
        alert.informativeText = String(localized: .unsavedTagsDetail)
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: .actionApply))
        alert.addButton(withTitle: String(localized: .unsavedTagsDiscard))
        alert.addButton(withTitle: String(localized: .actionCancel))
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
        contextTitle = String(localized: .libraryAllVideos)
        contextTagID = nil
        setContextStatus(message)
        updateToolbarState()
    }

    func setOperationError(_ message: String) {
        setContextStatus(message)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        if toolbar.identifier == Self.settingsToolbarIdentifier {
            return [
                Self.settingsBackItemIdentifier,
                Self.settingsTitleItemIdentifier,
                .flexibleSpace,
            ]
        }
        return [
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
        if toolbar.identifier == Self.settingsToolbarIdentifier {
            return [
                Self.settingsBackItemIdentifier,
                Self.settingsTitleItemIdentifier,
                .flexibleSpace,
            ]
        }
        return [
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
                label: String(localized: .toolbarHideShowSidebar),
                action: #selector(toggleSidebarFromToolbar(_:)),
                isOn: sidebarSplitViewItem?.isCollapsed == false,
                buttonStore: { [weak self] button in self?.sidebarToggleButton = button }
            )
        case Self.settingsBackItemIdentifier:
            return makeSettingsBackToolbarItem(identifier: itemIdentifier)
        case Self.settingsTitleItemIdentifier:
            return makeSettingsTitleToolbarItem(identifier: itemIdentifier)
        case Self.toggleInspectorItemIdentifier:
            return makeSplitViewToggleToolbarItem(
                identifier: itemIdentifier,
                symbolName: "sidebar.right",
                label: String(localized: .toolbarHideShowInspector),
                action: #selector(toggleInspectorFromToolbar(_:)),
                isOn: inspectorSplitViewItem?.isCollapsed == false,
                buttonStore: { [weak self] button in self?.inspectorToggleButton = button }
            )
        case Self.contextTitleItemIdentifier:
            return makeContextTitleToolbarItem(identifier: itemIdentifier)
        case Self.searchItemIdentifier:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.label = String(localized: .toolbarSearch)
            item.paletteLabel = String(localized: .toolbarSearchVideos)
            item.toolTip = String(
                localized: "filter.searchShortcutTooltip",
                defaultValue: "Search filenames (⌘F)"
            )
            item.searchField.placeholderString = String(localized: .toolbarSearchFilename)
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.stringValue = temporaryFilenameSearch
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
            label: String(localized: .toolbarThumbnailDecrease),
            target: self,
            action: #selector(decreaseZoom(_:)),
            buttonType: .momentaryPushIn
        )
        let largeButton = makeToolbarIconButton(
            symbolName: "square.grid.2x2",
            label: String(localized: .toolbarThumbnailIncrease),
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
        slider.toolTip = String(localized: .toolbarThumbnailSizeAdjust)
        slider.setAccessibilityLabel(String(localized: .toolbarThumbnailSize))
        slider.widthAnchor.constraint(equalToConstant: 70).isActive = true
        slider.isEnabled = isLibraryAvailable
        zoomSlider = slider

        let zoomOutItem = NSToolbarItem(itemIdentifier: Self.zoomOutItemIdentifier)
        zoomOutItem.label = String(localized: .toolbarThumbnailDecrease)
        zoomOutItem.toolTip = String(localized: .toolbarThumbnailDecrease)
        zoomOutItem.view = smallButton

        let sliderItem = NSToolbarItem(itemIdentifier: Self.zoomSliderItemIdentifier)
        sliderItem.label = String(localized: .toolbarThumbnailSize)
        sliderItem.toolTip = String(localized: .toolbarThumbnailSizeAdjust)
        sliderItem.view = slider

        let zoomInItem = NSToolbarItem(itemIdentifier: Self.zoomInItemIdentifier)
        zoomInItem.label = String(localized: .toolbarThumbnailIncrease)
        zoomInItem.toolTip = String(localized: .toolbarThumbnailIncrease)
        zoomInItem.view = largeButton

        let group = NSToolbarItemGroup(itemIdentifier: identifier)
        group.label = String(localized: .toolbarThumbnailSize)
        group.paletteLabel = String(localized: .toolbarThumbnailSize)
        group.toolTip = String(localized: .toolbarThumbnailSizeAdjust)
        group.controlRepresentation = .expanded
        group.subitems = [zoomOutItem, sliderItem, zoomInItem]
        return group
    }

    private func makeContextTitleToolbarItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let titleView = ToolbarTitleView()
        contextTitleView = titleView

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = String(localized: .toolbarCurrentCategory)
        item.paletteLabel = String(localized: .toolbarCurrentCategory)
        item.isBordered = false
        if #available(macOS 26.0, *) {
            item.style = .plain
        }
        item.view = titleView
        updateWindowTitle()
        return item
    }

    private func makeSettingsBackToolbarItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let image = NSImage(
            systemSymbolName: "chevron.left",
            accessibilityDescription: String(localized: .toolbarBackLibrary)
        ) ?? NSImage()
        let button = NSButton(
            title: String(localized: .libraryGroup),
            image: image,
            target: self,
            action: #selector(returnToLibraryFromSettings(_:))
        )
        button.imagePosition = .imageLeading
        button.bezelStyle = .toolbar
        button.toolTip = String(localized: .toolbarBackLibrary)
        button.setAccessibilityLabel(String(localized: .toolbarBackLibrary))

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = String(localized: .toolbarBackLibrary)
        item.paletteLabel = String(localized: .toolbarBackLibrary)
        item.view = button
        return item
    }

    private func makeSettingsTitleToolbarItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let label = NSTextField(labelWithString: String(localized: .toolbarSettings))
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = String(localized: .toolbarSettings)
        item.paletteLabel = String(localized: .toolbarSettings)
        item.isBordered = false
        if #available(macOS 26.0, *) {
            item.style = .plain
        }
        item.view = label
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
        videoGridViewController.endBrowsingContextNotificationLifecycle()
        if isImporting == false {
            contextStatus = nil
        }
        updateWindowTitle()
    }

    private func clearSearchForImport() {
        setTemporaryFilenameSearch("")
    }

    private func updateWindowTitle() {
        var subtitleParts: [String] = []
        if isLibraryAvailable {
            subtitleParts.append(String(localized: .libraryVideoCount(visibleVideoCount)))
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
        temporaryFilenameSearch = sender.stringValue
        refreshRuleBar()
        applyCurrentQuery(debounce: true)
    }

    @objc private func toggleSidebarFromToolbar(_ sender: NSButton) {
        guard let sidebarSplitViewItem else { return }
        sidebarSplitViewItem.animator().isCollapsed = sender.state == .off
    }

    @objc private func returnToLibraryFromSettings(_ sender: Any?) {
        showLibrary()
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

        let textContainer = NSView()
        textContainer.translatesAutoresizingMaskIntoConstraints = false

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

        addSubview(textContainer)
        textContainer.addSubview(titleLabel)
        textContainer.addSubview(subtitleLabel)
        NSLayoutConstraint.activate([
            textContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            textContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            textContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            textContainer.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            textContainer.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: textContainer.topAnchor),
            subtitleLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: -1),
            subtitleLabel.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
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
