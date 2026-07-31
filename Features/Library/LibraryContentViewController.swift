import AppKit

@MainActor
final class LibraryContentViewController: NSViewController {
    let ruleBarViewController: LibraryRuleBarViewController
    let videoGridViewController: VideoGridViewController

    init(
        ruleBarViewController: LibraryRuleBarViewController,
        videoGridViewController: VideoGridViewController
    ) {
        self.ruleBarViewController = ruleBarViewController
        self.videoGridViewController = videoGridViewController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        addChild(ruleBarViewController)
        addChild(videoGridViewController)

        let ruleBar = ruleBarViewController.view
        let grid = videoGridViewController.view
        ruleBar.translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(ruleBar)
        container.addSubview(grid)

        NSLayoutConstraint.activate([
            ruleBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            ruleBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ruleBar.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            ruleBar.heightAnchor.constraint(equalToConstant: 44),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grid.topAnchor.constraint(equalTo: ruleBar.bottomAnchor),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }
}
