import AppKit

@MainActor
final class InspectorViewController: NSViewController {
    private let stack = NSStackView()
    private let onOpen: (VideoRecord) -> Void
    private let onReveal: (VideoRecord) -> Void
    private let onCopyPath: (VideoRecord) -> Void
    private var selectedVideo: VideoRecord?

    init(
        onOpen: @escaping (VideoRecord) -> Void,
        onReveal: @escaping (VideoRecord) -> Void,
        onCopyPath: @escaping (VideoRecord) -> Void
    ) {
        self.onOpen = onOpen
        self.onReveal = onReveal
        self.onCopyPath = onCopyPath
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
        ])
        view = container
        setSelection([])
    }

    func setSelection(_ videos: [VideoRecord]) {
        loadViewIfNeeded()
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        selectedVideo = videos.count == 1 ? videos[0] : nil

        let heading = NSTextField(labelWithString: "检查器")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(heading)

        guard videos.isEmpty == false else {
            addSecondaryText("选择一个或多个视频以查看详细信息。")
            return
        }
        guard let video = selectedVideo else {
            addPrimaryText("已选择 \(videos.count) 个视频")
            let totalBytes = videos.reduce(Int64(0)) { $0 + $1.fileSize }
            addField(title: "总大小", value: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
            return
        }

        addPrimaryText(video.filename)
        addField(title: "格式", value: video.fileExtension.uppercased())
        addField(title: "大小", value: ByteCountFormatter.string(fromByteCount: video.fileSize, countStyle: .file))
        addField(title: "时长", value: formattedDuration(video.duration))
        let resolution = if let width = video.width, let height = video.height {
            "\(width) × \(height)"
        } else {
            "媒体信息不可用"
        }
        addField(title: "分辨率", value: resolution)
        addField(title: "相对路径", value: video.relativePath)

        let buttons = NSStackView()
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 6
        let openButton = NSButton(title: "使用默认播放器打开", target: self, action: #selector(openVideo))
        let revealButton = NSButton(title: "在 Finder 中显示", target: self, action: #selector(revealVideo))
        let copyButton = NSButton(title: "复制完整路径", target: self, action: #selector(copyPath))
        let available = video.availability == .available
        openButton.isEnabled = available
        revealButton.isEnabled = available
        copyButton.isEnabled = available
        buttons.addArrangedSubview(openButton)
        buttons.addArrangedSubview(revealButton)
        buttons.addArrangedSubview(copyButton)
        stack.addArrangedSubview(buttons)
    }

    private func addPrimaryText(_ value: String) {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        stack.addArrangedSubview(label)
    }

    private func addSecondaryText(_ value: String) {
        let label = NSTextField(wrappingLabelWithString: value)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)
    }

    private func addField(title: String, value: String) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.isSelectable = true
        let fieldStack = NSStackView(views: [titleLabel, valueLabel])
        fieldStack.orientation = .vertical
        fieldStack.alignment = .leading
        fieldStack.spacing = 2
        stack.addArrangedSubview(fieldStack)
    }

    private func formattedDuration(_ duration: Double?) -> String {
        guard let duration, duration.isFinite else { return "媒体信息不可用" }
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    @objc private func openVideo() {
        if let selectedVideo { onOpen(selectedVideo) }
    }

    @objc private func revealVideo() {
        if let selectedVideo { onReveal(selectedVideo) }
    }

    @objc private func copyPath() {
        if let selectedVideo { onCopyPath(selectedVideo) }
    }
}
