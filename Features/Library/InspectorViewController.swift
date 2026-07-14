import AppKit

@MainActor
final class InspectorViewController: NSViewController {
    override func loadView() {
        let container = NSView()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let title = NSTextField(labelWithString: "检查器")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let detail = NSTextField(wrappingLabelWithString: "选择视频后显示文件信息、应用标签和 Finder 标签。")
        detail.textColor = .secondaryLabelColor

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(detail)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
        ])
        view = container
    }
}
