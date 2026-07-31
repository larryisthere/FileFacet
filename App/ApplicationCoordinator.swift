import AppKit
import CoreGraphics
import QuickLook
import QuickLookUI
import SwiftUI

@MainActor
final class ApplicationCoordinator: NSObject, NSMenuItemValidation {
    private static let userActivityEventTypes: [CGEventType] = [
        .keyDown,
        .flagsChanged,
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
        .scrollWheel,
    ]

    private let preferencesStore: PreferencesStore
    private let lockCoordinator: LockCoordinator
    private let databaseStore: DatabaseStore?
    private let windowController = MainWindowController()
    private let quickLookCoordinator = QuickLookPreviewCoordinator()
    private let folderImportMethodPresenter = FolderImportMethodPresenter()
    private var privacyShield: NSView?
    private var idleTimer: Timer?

    private lazy var libraryViewController = LibrarySplitViewController(
        onCancelImport: { [weak self] in self?.libraryAccessCoordinator?.cancelImport() },
        onImportDroppedItems: { [weak self] urls in self?.libraryAccessCoordinator?.importDroppedItems(urls) },
        onRemoveVideos: { [weak self] videoIDs, completion in
            guard let coordinator = self?.libraryAccessCoordinator else {
                completion(false)
                return
            }
            coordinator.removeVideos(ids: videoIDs, completion: completion)
        },
        onUndoLastMutation: { [weak self] in self?.libraryAccessCoordinator?.undoLastMutation() },
        onOpenVideo: { [weak self] video in self?.openVideo(video) },
        onRevealVideo: { [weak self] video in self?.revealVideo(video) },
        onCopyPath: { [weak self] video in self?.copyPath(video) },
        onPreviewVideos: { [weak self] videos in self?.previewVideos(videos) },
        thumbnailURL: { [weak self] video in self?.libraryAccessCoordinator?.thumbnailURL(for: video) },
        filePath: { [weak self] video in self?.libraryAccessCoordinator?.fileURL(for: video)?.path },
        offlineSourceName: { [weak self] video in
            self?.libraryAccessCoordinator?.offlineSourceName(for: video)
        },
        onQueryChanged: { [weak self] query, debounceSearch in
            self?.libraryAccessCoordinator?.applyQuery(query, debounceSearch: debounceSearch)
        },
        onCreateSmartCollection: { [weak self] name, rule, completion in
            guard let coordinator = self?.libraryAccessCoordinator else {
                completion(nil)
                return
            }
            coordinator.createSmartCollection(
                name: name,
                rule: rule,
                completion: completion
            )
        },
        onUpdateSmartCollection: { [weak self] id, name, rule, completion in
            guard let coordinator = self?.libraryAccessCoordinator else {
                completion(nil)
                return
            }
            coordinator.updateSmartCollection(
                id: id,
                name: name,
                rule: rule,
                completion: completion
            )
        },
        onDeleteSmartCollection: { [weak self] id, completion in
            guard let coordinator = self?.libraryAccessCoordinator else {
                completion(false)
                return
            }
            coordinator.deleteSmartCollection(
                id: id,
                completion: completion
            )
        },
        onCreateTag: { [weak self] name, parentID in self?.libraryAccessCoordinator?.createTag(name: name, parentID: parentID) },
        onRenameTag: { [weak self] tag, name in self?.libraryAccessCoordinator?.renameTag(tag, name: name) },
        onDeleteTag: { [weak self] tag in self?.libraryAccessCoordinator?.deleteTag(tag) },
        onMoveTags: { [weak self] tags, parentID, order in self?.libraryAccessCoordinator?.moveTags(tags, parentID: parentID, sortOrder: order) },
        onSetTagColor: { [weak self] tag, color in self?.libraryAccessCoordinator?.setTagColor(tag, color: color) },
        onMergeTag: { [weak self] source, target in self?.libraryAccessCoordinator?.mergeTag(source, into: target) },
        onAssignVideos: { [weak self] tag, videoIDs in self?.libraryAccessCoordinator?.setTagAssignment(tag, videoIDs: videoIDs, enabled: true) },
        onAssignTagID: { [weak self] tagID, videoIDs in self?.libraryAccessCoordinator?.setTagAssignment(tagID: tagID, videoIDs: videoIDs, enabled: true) },
        onApplyTagDraft: { [weak self] creations, assignments, videoIDs, completion in
            guard let coordinator = self?.libraryAccessCoordinator else {
                completion(false)
                return
            }
            coordinator.applyTagDraft(
                creations: creations,
                assignments: assignments,
                videoIDs: videoIDs,
                completion: completion
            )
        },
        loadTagStates: { [weak self] videoIDs, completion in self?.libraryAccessCoordinator?.tagAssignmentStates(videoIDs: videoIDs, completion: completion) },
        settingsViewController: settingsViewController
    )

    private lazy var libraryAccessCoordinator: LibraryAccessCoordinator? = {
        guard let databaseStore else { return nil }
        return LibraryAccessCoordinator(
            database: databaseStore,
            resolveFolderImportMethod: { [weak self] in
                await self?.resolveFolderImportMethod()
            }
        )
    }()

    private lazy var settingsNavigation = SettingsNavigationModel()

    private lazy var settingsViewController = NSHostingController(
        rootView: SettingsView(
            preferences: preferencesStore,
            navigation: settingsNavigation,
            setAuthenticationEnabled: { [weak self] enabled in
                self?.setAuthenticationEnabled(enabled)
            }
        )
    )

    override init() {
        let preferencesStore = PreferencesStore()
        self.preferencesStore = preferencesStore
        lockCoordinator = LockCoordinator(
            isAuthenticationEnabled: preferencesStore.authenticationEnabled
        )

        do {
            databaseStore = try DatabaseStore.makeDefault()
        } catch {
            databaseStore = nil
            AppLogger.database.fault("Database initialization failed with category: \(String(describing: type(of: error)), privacy: .public)")
        }

        super.init()
        registerForPrivacyEvents()
        idleTimer = Timer.scheduledTimer(
            timeInterval: 5,
            target: self,
            selector: #selector(checkIdleLock),
            userInfo: nil,
            repeats: true
        )
    }

    func start() {
        lockCoordinator.onStateChange = { [weak self] state in
            self?.render(lockState: state)
        }

        libraryAccessCoordinator?.onVideosChanged = { [weak self] videos in
            self?.libraryViewController.setVideos(videos)
        }
        libraryAccessCoordinator?.onSidebarFilterCountsChanged = { [weak self] counts in
            self?.libraryViewController.setSidebarFilterCounts(counts)
        }
        libraryAccessCoordinator?.onFilterChangedBySystem = { [weak self] filter in
            self?.libraryViewController.setFilterFromSystem(filter)
        }
        libraryAccessCoordinator?.onVideoChanged = { [weak self] video in
            self?.libraryViewController.updateVideo(video)
        }
        libraryAccessCoordinator?.onImportStateChanged = { [weak self] state in
            guard let self else { return }
            libraryViewController.setImportState(state)
            switch state {
            case .completed, .cancelled, .failed:
                if libraryAccessCoordinator?.canUndoVideoRemoval == true {
                    libraryViewController.offerVideoRemovalUndoForCurrentStatus()
                }
            case .idle, .importing:
                break
            }
        }
        libraryAccessCoordinator?.onTagsChanged = { [weak self] tags in
            self?.libraryViewController.setTags(tags)
        }
        libraryAccessCoordinator?.onSmartCollectionsChanged = { [weak self] collections in
            self?.libraryViewController.setSmartCollections(collections)
        }
        libraryAccessCoordinator?.onTagAssignmentsChanged = { [weak self] in
            self?.libraryViewController.refreshTagAssignments()
        }
        libraryAccessCoordinator?.onVideoRemovalRestored = { [weak self] videoIDs in
            self?.libraryViewController.showRestoredVideos(videoIDs)
        }
        libraryAccessCoordinator?.onVideoRemovalUndoDiscarded = { [weak self] in
            self?.libraryViewController.removeVideoRemovalUndoOffer()
        }
        libraryAccessCoordinator?.onError = { [weak self] message in
            self?.libraryViewController.setLibraryError(message)
        }
        libraryAccessCoordinator?.onOperationError = { [weak self] message in
            self?.libraryViewController.setOperationError(message)
        }

        installMainMenu()
        render(lockState: lockCoordinator.state)
        windowController.window?.center()
        windowController.window?.makeKeyAndOrderFront(nil)
        libraryAccessCoordinator?.restoreLibrary()
        AppLogger.lifecycle.notice("Application started")
    }

    private func render(lockState: LockState) {
        switch lockState {
        case .unlocked:
            windowController.setRootViewController(libraryViewController)
        case .locked, .authenticating, .failed:
            quickLookCoordinator.close()
            let view = LockView(
                state: lockState,
                unlock: { [weak self] in self?.lockCoordinator.unlock() }
            )
            windowController.setRootViewController(NSHostingController(rootView: view))
        }
    }

    private func registerForPrivacyEvents() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceRequiresLock),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceRequiresLock),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceVolumeAvailabilityChanged(_:)),
            name: NSWorkspace.didMountNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceVolumeAvailabilityChanged(_:)),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )
    }

    @objc private func applicationWillResignActive() {
        guard lockCoordinator.isAuthenticationEnabled else { return }
        installPrivacyShield()
        if preferencesStore.idleLockInterval == .immediately,
           lockCoordinator.state == .unlocked {
            lockCoordinator.lock()
        }
    }

    @objc private func applicationDidBecomeActive() {
        render(lockState: lockCoordinator.state)
        removePrivacyShield()
    }

    @objc private func workspaceRequiresLock() {
        guard lockCoordinator.isAuthenticationEnabled else { return }
        installPrivacyShield()
        lockCoordinator.lock()
    }

    @objc private func workspaceVolumeAvailabilityChanged(_ notification: Notification) {
        libraryAccessCoordinator?.refreshVolumeAvailability(
            interruptMediaProcessing: notification.name == NSWorkspace.didUnmountNotification
        )
    }

    @objc private func checkIdleLock() {
        guard lockCoordinator.isAuthenticationEnabled,
              lockCoordinator.state == .unlocked else { return }
        let interval = preferencesStore.idleLockInterval
        guard interval != .never, interval != .immediately else { return }
        guard let idleSeconds = systemIdleSeconds() else { return }
        if idleSeconds >= Double(interval.rawValue) { lockCoordinator.lock() }
    }

    private func systemIdleSeconds() -> TimeInterval? {
        Self.userActivityEventTypes.lazy
            .map {
                CGEventSource.secondsSinceLastEventType(
                    .combinedSessionState,
                    eventType: $0
                )
            }
            .filter { $0.isFinite && $0 >= 0 }
            .min()
    }

    @objc private func showSettings() {
        presentSettings(section: .privacy)
    }

    @objc private func showAbout() {
        presentSettings(section: .about)
    }

    private func presentSettings(section: SettingsSection) {
        guard lockCoordinator.state == .unlocked else { return }
        settingsNavigation.selection = section
        libraryViewController.showSettings()
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func importVideos() {
        guard lockCoordinator.state == .unlocked else { return }
        guard let libraryAccessCoordinator else {
            libraryViewController.setLibraryError(String(localized: .errorDatabaseUnavailable))
            return
        }
        libraryAccessCoordinator.importVideos()
    }

    private func resolveFolderImportMethod() async -> FolderImportMethod? {
        switch preferencesStore.folderImportPreference {
        case .direct:
            return .direct
        case .folderTags:
            return .folderTags(
                includeSelectedRoot: preferencesStore.includeSelectedFolderAsRootTag
            )
        case .ask:
            guard let window = windowController.window else { return nil }
            guard let decision = await folderImportMethodPresenter.present(
                on: window,
                includeSelectedRootByDefault: preferencesStore.includeSelectedFolderAsRootTag
            ) else {
                return nil
            }
            if decision.remember {
                switch decision.method {
                case .direct:
                    preferencesStore.folderImportPreference = .direct
                case let .folderTags(includeSelectedRoot):
                    preferencesStore.folderImportPreference = .folderTags
                    preferencesStore.includeSelectedFolderAsRootTag = includeSelectedRoot
                }
            }
            return decision.method
        }
    }

    @objc private func undoLastMutation() {
        guard lockCoordinator.state == .unlocked else { return }
        libraryAccessCoordinator?.undoLastMutation()
    }

    @objc private func createRootTag() {
        guard lockCoordinator.state == .unlocked else { return }
        libraryViewController.beginCreatingRootTag()
    }

    @objc private func focusFilenameSearch() {
        guard lockCoordinator.state == .unlocked else { return }
        libraryViewController.focusFilenameSearch()
    }

    @objc private func presentAddFilterMenu() {
        guard lockCoordinator.state == .unlocked else { return }
        libraryViewController.presentAddFilterMenu()
    }

    private func openVideo(_ video: VideoRecord) {
        guard let url = libraryAccessCoordinator?.fileURL(for: video) else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealVideo(_ video: VideoRecord) {
        guard let url = libraryAccessCoordinator?.fileURL(for: video) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyPath(_ video: VideoRecord) {
        guard let path = libraryAccessCoordinator?.fileURL(for: video)?.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func previewVideos(_ videos: [VideoRecord]) {
        let urls = videos.compactMap { libraryAccessCoordinator?.fileURL(for: $0) }
        quickLookCoordinator.toggle(urls: urls)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(importVideos) {
            return lockCoordinator.state == .unlocked && databaseStore != nil
        }
        if menuItem.action == #selector(undoLastMutation) {
            return lockCoordinator.state == .unlocked
                && libraryAccessCoordinator?.canUndoLastMutation == true
        }
        if menuItem.action == #selector(createRootTag) {
            return lockCoordinator.state == .unlocked
                && databaseStore != nil
                && libraryViewController.canBeginCreatingRootTag
        }
        if menuItem.action == #selector(focusFilenameSearch)
            || menuItem.action == #selector(presentAddFilterMenu) {
            return lockCoordinator.state == .unlocked
                && databaseStore != nil
                && libraryViewController.canUseRuleCommands
        }
        if menuItem.action == #selector(showSettings) || menuItem.action == #selector(showAbout) {
            return lockCoordinator.state == .unlocked
        }
        return true
    }

    private func setAuthenticationEnabled(_ enabled: Bool) {
        Task {
            let accepted = await lockCoordinator.setAuthenticationEnabled(enabled)
            if accepted {
                preferencesStore.setAuthenticationEnabled(enabled)
                AppLogger.security.notice("Authentication preference changed: \(enabled, privacy: .public)")
            }
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: AppConfiguration.displayName)
        let aboutItem = NSMenuItem(
            title: String(localized: .menuAbout(AppConfiguration.displayName)),
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: String(localized: .menuSettings),
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: String(localized: .menuQuit(AppConfiguration.displayName)),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: String(localized: .menuFile))
        let importItem = NSMenuItem(
            title: String(localized: .menuFileImport),
            action: #selector(importVideos),
            keyEquivalent: "i"
        )
        importItem.keyEquivalentModifierMask = [.command, .shift]
        importItem.target = self
        fileMenu.addItem(importItem)
        let createTagItem = NSMenuItem(
            title: String(localized: .menuFileNewTag),
            action: #selector(createRootTag),
            keyEquivalent: "n"
        )
        createTagItem.keyEquivalentModifierMask = [.command, .shift]
        createTagItem.target = self
        fileMenu.addItem(createTagItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: .menuEdit))
        let undoItem = NSMenuItem(
            title: String(localized: .menuUndoLastAction),
            action: #selector(undoLastMutation),
            keyEquivalent: "z"
        )
        undoItem.target = self
        editMenu.addItem(undoItem)
        editMenu.addItem(.separator())
        let searchItem = NSMenuItem(
            title: String(
                localized: "menu.searchFilenames",
                defaultValue: "Search Filenames"
            ),
            action: #selector(focusFilenameSearch),
            keyEquivalent: "f"
        )
        searchItem.keyEquivalentModifierMask = [.command]
        searchItem.target = self
        editMenu.addItem(searchItem)
        let addFilterItem = NSMenuItem(
            title: String(
                localized: "menu.addFilterCondition",
                defaultValue: "Add Filter Condition"
            ),
            action: #selector(presentAddFilterMenu),
            keyEquivalent: "f"
        )
        addFilterItem.keyEquivalentModifierMask = [.command, .shift]
        addFilterItem.target = self
        editMenu.addItem(addFilterItem)
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: .menuWindow))
        windowMenu.addItem(
            withTitle: String(localized: .menuMinimize),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func installPrivacyShield() {
        guard privacyShield == nil,
              let contentView = windowController.window?.contentView,
              let containerView = contentView.superview else { return }

        let shield = NSVisualEffectView(frame: contentView.convert(contentView.bounds, to: containerView))
        shield.autoresizingMask = [.width, .height]
        shield.material = .windowBackground
        shield.blendingMode = .withinWindow
        shield.state = .active

        let label = NSTextField(labelWithString: AppConfiguration.displayName)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        shield.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: shield.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: shield.centerYAnchor),
        ])

        containerView.addSubview(shield, positioned: .above, relativeTo: contentView)
        privacyShield = shield
    }

    private func removePrivacyShield() {
        privacyShield?.removeFromSuperview()
        privacyShield = nil
    }
}

@MainActor
private final class QuickLookPreviewCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource {
    private var previewURLs: [URL] = []
    private weak var activePanel: QLPreviewPanel?

    func toggle(urls: [URL]) {
        guard urls.isEmpty == false, let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }

        previewURLs = urls
        activePanel = panel
        panel.dataSource = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        activePanel?.orderOut(nil)
        activePanel = nil
        previewURLs = []
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard previewURLs.indices.contains(index) else { return nil }
        return previewURLs[index] as NSURL
    }
}
