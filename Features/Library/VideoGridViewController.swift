import AppKit

@MainActor
final class VideoGridViewController: NSViewController {
    private let collectionView = NSCollectionView()

    override func loadView() {
        let container = NSView()

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 180, height: 150)
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 20
        layout.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = collectionView

        let emptyState = NSStackView()
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 10

        let icon = NSImageView(image: NSImage(systemSymbolName: "film.stack", accessibilityDescription: "视频") ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 32, weight: .light)
        icon.contentTintColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: "尚未选择视频资料库")
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let detail = NSTextField(wrappingLabelWithString: "验证完成后，可以选择一个本地目录建立只读索引。")
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center

        emptyState.addArrangedSubview(icon)
        emptyState.addArrangedSubview(title)
        emptyState.addArrangedSubview(detail)

        container.addSubview(scrollView)
        container.addSubview(emptyState)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        view = container
    }
}
