import AppKit

@MainActor
final class MainWindowController: NSWindowController {
    private static let minimumWindowSize = NSSize(width: 920, height: 560)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppConfiguration.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.minSize = Self.minimumWindowSize
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRootViewController(_ viewController: NSViewController) {
        guard contentViewController !== viewController else { return }
        guard let window else {
            contentViewController = viewController
            return
        }
        let preservedFrame = window.frame
        contentViewController = viewController
        if let libraryViewController = viewController as? LibrarySplitViewController {
            window.toolbar = libraryViewController.makeToolbar()
            window.titleVisibility = .hidden
        } else {
            window.toolbar = nil
            window.title = AppConfiguration.displayName
            window.subtitle = ""
            window.titleVisibility = .hidden
        }
        window.minSize = Self.minimumWindowSize
        window.setFrame(preservedFrame, display: window.isVisible, animate: false)
    }
}
