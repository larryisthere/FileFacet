import AppKit

struct FolderImportDecision: Equatable, Sendable {
    let method: FolderImportMethod
    let remember: Bool
}

@MainActor
final class FolderImportMethodPresenter: NSObject {
    private var alert: NSAlert?
    private var continuation: CheckedContinuation<FolderImportDecision?, Never>?
    private weak var directButton: NSButton?
    private weak var folderTagsButton: NSButton?
    private weak var includeRootButton: NSButton?
    private weak var mappingLabel: NSTextField?

    func present(
        on window: NSWindow,
        includeSelectedRootByDefault: Bool
    ) async -> FolderImportDecision? {
        guard continuation == nil else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let alert = makeAlert(includeSelectedRootByDefault: includeSelectedRootByDefault)
            self.alert = alert
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.finish(response: response)
            }
        }
    }

    private func makeAlert(includeSelectedRootByDefault: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: .folderImportTitle)
        alert.informativeText = String(localized: .folderImportDetail)
        alert.addButton(withTitle: String(localized: .folderImportContinue))
        alert.addButton(withTitle: String(localized: .actionCancel))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: .folderImportRemember)

        let directButton = NSButton(
            radioButtonWithTitle: String(localized: .folderImportDirectTitle),
            target: self,
            action: #selector(selectDirect)
        )
        directButton.state = .on
        let directDetail = detailLabel(String(localized: .folderImportDirectDetail))

        let folderTagsButton = NSButton(
            radioButtonWithTitle: String(localized: .folderImportTagsTitle),
            target: self,
            action: #selector(selectFolderTags)
        )
        let folderTagsDetail = detailLabel(String(localized: .folderImportTagsDetail))

        let includeRootButton = NSButton(
            checkboxWithTitle: String(localized: .folderImportIncludeRoot),
            target: self,
            action: #selector(toggleIncludeRoot)
        )
        includeRootButton.state = includeSelectedRootByDefault ? .on : .off
        includeRootButton.isEnabled = false
        let includeRootDetail = detailLabel(String(localized: .folderImportIncludeRootDetail))
        includeRootDetail.textColor = .tertiaryLabelColor

        let mappingLabel = detailLabel(String(localized: .folderImportMappingDirect))
        mappingLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            directButton,
            directDetail,
            spacer(height: 4),
            folderTagsButton,
            folderTagsDetail,
            spacer(height: 2),
            includeRootButton,
            includeRootDetail,
            spacer(height: 4),
            mappingLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        let accessoryWidth: CGFloat = 440
        let detailWidth: CGFloat = 416
        [directButton, folderTagsButton, includeRootButton, mappingLabel].forEach {
            $0.widthAnchor.constraint(equalToConstant: accessoryWidth).isActive = true
        }
        [directDetail, folderTagsDetail, includeRootDetail].forEach {
            $0.widthAnchor.constraint(equalToConstant: detailWidth).isActive = true
        }
        stack.frame = NSRect(x: 0, y: 0, width: accessoryWidth, height: 1)
        stack.layoutSubtreeIfNeeded()
        let accessoryHeight = ceil(stack.fittingSize.height)

        let accessoryView = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: accessoryWidth,
            height: accessoryHeight
        ))
        stack.frame = accessoryView.bounds
        stack.autoresizingMask = [.width, .height]
        accessoryView.addSubview(stack)
        alert.accessoryView = accessoryView

        self.directButton = directButton
        self.folderTagsButton = folderTagsButton
        self.includeRootButton = includeRootButton
        self.mappingLabel = mappingLabel
        return alert
    }

    private func detailLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 416
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    private func spacer(height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    @objc private func selectDirect() {
        directButton?.state = .on
        folderTagsButton?.state = .off
        includeRootButton?.isEnabled = false
        mappingLabel?.stringValue = String(localized: .folderImportMappingDirect)
    }

    @objc private func selectFolderTags() {
        directButton?.state = .off
        folderTagsButton?.state = .on
        includeRootButton?.isEnabled = true
        updateFolderTagMapping()
    }

    @objc private func toggleIncludeRoot() {
        updateFolderTagMapping()
    }

    private func updateFolderTagMapping() {
        mappingLabel?.stringValue = includeRootButton?.state == .on
            ? String(localized: .folderImportMappingIncludeRoot)
            : String(localized: .folderImportMappingExcludeRoot)
    }

    private func finish(response: NSApplication.ModalResponse) {
        let result: FolderImportDecision?
        if response == .alertFirstButtonReturn {
            let method: FolderImportMethod = folderTagsButton?.state == .on
                ? .folderTags(includeSelectedRoot: includeRootButton?.state == .on)
                : .direct
            result = FolderImportDecision(
                method: method,
                remember: alert?.suppressionButton?.state == .on
            )
        } else {
            result = nil
        }

        let continuation = continuation
        self.continuation = nil
        alert = nil
        directButton = nil
        folderTagsButton = nil
        includeRootButton = nil
        mappingLabel = nil
        continuation?.resume(returning: result)
    }
}
