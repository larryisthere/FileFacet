import AppKit
import SwiftUI

@MainActor
final class ApplicationCoordinator: NSObject, NSMenuItemValidation {
    private let preferencesStore: PreferencesStore
    private let lockCoordinator: LockCoordinator
    private let databaseStore: DatabaseStore?
    private let windowController = MainWindowController()
    private var privacyShield: NSView?

    private lazy var libraryViewController = LibrarySplitViewController(
        onChooseLibrary: { [weak self] in self?.chooseLibrary() },
        onRescan: { [weak self] in self?.rescanLibrary() }
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
    }

    func start() {
        lockCoordinator.onStateChange = { [weak self] state in
            self?.render(lockState: state)
        }

        libraryAccessCoordinator?.onLibraryChanged = { [weak self] summary in
            self?.libraryViewController.setLibrary(summary)
        }
        libraryAccessCoordinator?.onVideosChanged = { [weak self] videos in
            self?.libraryViewController.setVideos(videos)
        }
        libraryAccessCoordinator?.onScanStateChanged = { [weak self] state in
            self?.libraryViewController.setScanState(state)
        }
        libraryAccessCoordinator?.onError = { [weak self] message in
            self?.libraryViewController.setLibraryError(message)
        }

        installMainMenu()
        render(lockState: lockCoordinator.state)
        windowController.showWindow(nil)
        windowController.window?.center()
        libraryAccessCoordinator?.restoreLibrary()
        AppLogger.lifecycle.notice("Application started")
    }

    private func render(lockState: LockState) {
        switch lockState {
        case .unlocked:
            windowController.setRootViewController(libraryViewController)
        case .locked, .authenticating, .failed:
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
        installPrivacyShield()
    }

    @objc private func applicationDidBecomeActive() {
        render(lockState: lockCoordinator.state)
        removePrivacyShield()
    }

    @objc private func workspaceRequiresLock() {
        installPrivacyShield()
        lockCoordinator.lock()
    }

    @objc private func showSettings() {
        settingsWindowController.present()
    }

    @objc private func chooseLibrary() {
        guard lockCoordinator.state == .unlocked else { return }
        guard let libraryAccessCoordinator else {
            libraryViewController.setLibraryError("应用数据库暂时不可用，请重新启动应用。")
            return
        }
        libraryAccessCoordinator.chooseLibrary()
    }

    @objc private func rescanLibrary() {
        guard lockCoordinator.state == .unlocked else { return }
        libraryAccessCoordinator?.rescan()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(chooseLibrary) {
            return lockCoordinator.state == .unlocked && databaseStore != nil
        }
        if menuItem.action == #selector(rescanLibrary) {
            return lockCoordinator.state == .unlocked
                && libraryAccessCoordinator?.hasActiveLibrary == true
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
        let chooseLibraryItem = NSMenuItem(
            title: "选择视频资料库…",
            action: #selector(chooseLibrary),
            keyEquivalent: "o"
        )
        chooseLibraryItem.target = self
        fileMenu.addItem(chooseLibraryItem)
        let rescanItem = NSMenuItem(
            title: "重新扫描资料库",
            action: #selector(rescanLibrary),
            keyEquivalent: "r"
        )
        rescanItem.keyEquivalentModifierMask = [.command, .shift]
        rescanItem.target = self
        fileMenu.addItem(rescanItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

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
        guard privacyShield == nil, let contentView = windowController.window?.contentView else { return }

        let shield = NSVisualEffectView(frame: contentView.bounds)
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

        contentView.addSubview(shield, positioned: .above, relativeTo: nil)
        privacyShield = shield
    }

    private func removePrivacyShield() {
        privacyShield?.removeFromSuperview()
        privacyShield = nil
    }
}
