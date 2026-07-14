import AppKit
import SwiftUI

@MainActor
final class ApplicationCoordinator: NSObject {
    private let lockCoordinator = LockCoordinator()
    private let windowController = MainWindowController()
    private var privacyShield: NSView?

    override init() {
        super.init()
        registerForPrivacyEvents()
    }

    func start() {
        lockCoordinator.onStateChange = { [weak self] state in
            self?.render(lockState: state)
        }

        render(lockState: lockCoordinator.state)
        windowController.showWindow(nil)
        windowController.window?.center()
    }

    private func render(lockState: LockState) {
        switch lockState {
        case .unlocked:
            windowController.setRootViewController(LibrarySplitViewController())
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
