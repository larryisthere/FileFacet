import AppKit

@MainActor
final class MainWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppConfiguration.displayName
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 840, height: 560)
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRootViewController(_ viewController: NSViewController) {
        contentViewController = viewController
    }
}
