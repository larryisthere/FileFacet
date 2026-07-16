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
    private var privacyShield: NSView?
    private var idleTimer: Timer?

    private lazy var libraryViewController = LibrarySplitViewController(
        onCancelImport: { [weak self] in self?.libraryAccessCoordinator?.cancelImport() },
        onImportDroppedVideos: { [weak self] urls in self?.libraryAccessCoordinator?.importDroppedVideos(urls) },
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
        onFilterChanged: { [weak self] filter in self?.applyFilter(filter) },
        onSearchChanged: { [weak self] text in self?.libraryAccessCoordinator?.applySearch(text) },
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
        loadTagStates: { [weak self] videoIDs, completion in self?.libraryAccessCoordinator?.tagAssignmentStates(videoIDs: videoIDs, completion: completion) }
    )

    private lazy var libraryAccessCoordinator: LibraryAccessCoordinator? = {
        guard let databaseStore else { return nil }
        return LibraryAccessCoordinator(database: databaseStore)
    }()

    private lazy var settingsWindowController = SettingsWindowController(
        preferences: preferencesStore,
        setAuthenticationEnabled: { [weak self] enabled in
            self?.setAuthenticationEnabled(enabled)
        }
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
        settingsWindowController.present()
    }

    @objc private func importVideos() {
        guard lockCoordinator.state == .unlocked else { return }
        guard let libraryAccessCoordinator else {
            libraryViewController.setLibraryError("应用数据库暂时不可用，请重新启动应用。")
            return
        }
        libraryAccessCoordinator.importVideos()
    }

    @objc private func undoLastMutation() {
        guard lockCoordinator.state == .unlocked else { return }
        libraryAccessCoordinator?.undoLastMutation()
    }

    @objc private func createRootTag() {
        guard lockCoordinator.state == .unlocked else { return }
        libraryViewController.beginCreatingRootTag()
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

    private func applyFilter(_ filter: LibraryFilter) {
        libraryAccessCoordinator?.applyFilter(filter)
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
        appMenu.addItem(
            withTitle: "关于 \(AppConfiguration.displayName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 \(AppConfiguration.displayName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        let importItem = NSMenuItem(
            title: "导入视频…",
            action: #selector(importVideos),
            keyEquivalent: "i"
        )
        importItem.keyEquivalentModifierMask = [.command, .shift]
        importItem.target = self
        fileMenu.addItem(importItem)
        let createTagItem = NSMenuItem(
            title: "新建标签…",
            action: #selector(createRootTag),
            keyEquivalent: "n"
        )
        createTagItem.keyEquivalentModifierMask = [.command, .shift]
        createTagItem.target = self
        fileMenu.addItem(createTagItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        let undoItem = NSMenuItem(
            title: "撤销上一次操作",
            action: #selector(undoLastMutation),
            keyEquivalent: "z"
        )
        undoItem.target = self
        editMenu.addItem(undoItem)
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(
            withTitle: "最小化",
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
