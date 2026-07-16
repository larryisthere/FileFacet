import AppKit

struct InspectorTagDraftSnapshot {
    let states: [String: TagAssignmentState]
    let creations: [TagCreationDraft]
}

@MainActor
final class InspectorViewController: NSViewController {
    private let stack = NSStackView()
    private let contentScrollView = NSScrollView()
    private let contentStack = InspectorContentStackView()
    private let actionContainer = NSStackView()
    private let draftStatusLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var discardButton = NSButton(title: "取消", target: self, action: #selector(discardTagChanges))
    private lazy var applyButton = NSButton(title: "应用", target: self, action: #selector(applyTagChanges))
    private lazy var sectionControl: NSSegmentedControl = {
        let control = NSSegmentedControl(
            labels: ["标签", "详情"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(changeSection(_:))
        )
        control.segmentStyle = .rounded
        control.selectedSegment = 0
        control.setAccessibilityLabel("检查器内容")
        return control
    }()
    private lazy var tagSearchField: NSSearchField = {
        let field = NSSearchField()
        field.placeholderString = "搜索或新建标签"
        field.target = self
        field.action = #selector(searchTags(_:))
        field.sendsSearchStringImmediately = true
        field.isHidden = true
        return field
    }()
    private let onApplyTagDraft: ([TagCreationDraft], [String: Bool], [String], @escaping (Bool) -> Void) -> Void
    private let loadTagStates: ([String], @escaping ([String: TagAssignmentState]) -> Void) -> Void
    private let filePath: (VideoRecord) -> String?
    private var selectedVideo: VideoRecord?
    private var selectedVideos: [VideoRecord] = []
    private var tags: [TagRecord] = []
    private var tagStates: [String: TagAssignmentState] = [:]
    private var draftTagStates: [String: TagAssignmentState] = [:]
    private var draftTagCreations: [TagCreationDraft] = []
    private var tagStateVideoIDs: [String] = []
    private var loadedTagOrderIDs: [String] = []
    private var tagStateRequestRevision = 0
    private(set) var isApplyingTagChanges = false
    private var tagSearchText = ""
    private var newTagPopover: NSPopover?
    var onTagApplicationFinished: ((Bool) -> Void)?
    var selectedVideoIDs: [String] { selectedVideos.map(\.id) }
    var hasPendingTagChanges: Bool { pendingTagAssignments.isEmpty == false }

    init(
        onApplyTagDraft: @escaping ([TagCreationDraft], [String: Bool], [String], @escaping (Bool) -> Void) -> Void,
        loadTagStates: @escaping ([String], @escaping ([String: TagAssignmentState]) -> Void) -> Void,
        filePath: @escaping (VideoRecord) -> String?
    ) {
        self.onApplyTagDraft = onApplyTagDraft
        self.loadTagStates = loadTagStates
        self.filePath = filePath
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
        stack.spacing = 12
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 9
        contentScrollView.translatesAutoresizingMaskIntoConstraints = false
        contentScrollView.hasVerticalScroller = true
        contentScrollView.hasHorizontalScroller = false
        contentScrollView.autohidesScrollers = true
        contentScrollView.drawsBackground = false
        contentScrollView.documentView = contentStack
        contentScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        configureActionArea()
        stack.addArrangedSubview(sectionControl)
        stack.addArrangedSubview(tagSearchField)
        stack.addArrangedSubview(contentScrollView)
        stack.addArrangedSubview(actionContainer)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            sectionControl.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tagSearchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = container
        setSelection([])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateScrollDocumentSize()
    }

    func setSelection(_ videos: [VideoRecord]) {
        let previousVideoIDs = selectedVideos.map(\.id)
        selectedVideos = videos
        selectedVideo = videos.count == 1 ? videos[0] : nil
        if previousVideoIDs != videos.map(\.id) {
            closeNewTagPopover()
            tagStateRequestRevision += 1
            tagStates = [:]
            draftTagStates = [:]
            draftTagCreations = []
            tagStateVideoIDs = []
            loadedTagOrderIDs = []
            isApplyingTagChanges = false
        }
        renderSelection()
        scheduleInitialTagStateLoadIfNeeded()
    }

    func setTags(_ tags: [TagRecord]) {
        self.tags = tags
        renderSelection()
        scheduleInitialTagStateLoadIfNeeded()
    }

    func refreshTagAssignments() {
        let videoIDs = selectedVideos.map(\.id)
        guard sectionControl.selectedSegment == 0,
              videoIDs.isEmpty == false,
              hasPendingTagChanges == false,
              isApplyingTagChanges == false else { return }
        tagStateRequestRevision += 1
        let requestRevision = tagStateRequestRevision
        loadTagStates(videoIDs) { [weak self] states in
            guard let self,
                  self.tagStateRequestRevision == requestRevision,
                  self.selectedVideos.map(\.id) == videoIDs else { return }
            self.tagStates = states
            self.draftTagStates = states
            self.tagStateVideoIDs = videoIDs
            self.loadedTagOrderIDs = self.tags
                .enumerated()
                .sorted { lhs, rhs in
                    let lhsIsSelected = (states[lhs.element.id] ?? .off) != .off
                    let rhsIsSelected = (states[rhs.element.id] ?? .off) != .off
                    if lhsIsSelected != rhsIsSelected {
                        return lhsIsSelected
                    }
                    return lhs.offset < rhs.offset
                }
                .map(\.element.id)
            self.renderSelection()
        }
    }

    private func renderSelection() {
        loadViewIfNeeded()
        defer {
            updateTagSearchFieldVisibility()
            updateActionArea()
        }
        clearContent()
        let videos = selectedVideos

        guard videos.isEmpty == false else {
            addSecondaryText("选择一个或多个视频以查看标签或详情。")
            updateScrollDocumentSize()
            return
        }
        guard sectionControl.selectedSegment == 1 else {
            addTagControls()
            updateScrollDocumentSize()
            return
        }
        guard let video = selectedVideo else {
            addPrimaryText("已选择 \(videos.count) 个视频")
            let totalBytes = videos.reduce(Int64(0)) { $0 + $1.fileSize }
            addField(title: "总大小", value: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
            updateScrollDocumentSize()
            return
        }

        addFilename(video.filename)
        addField(title: "格式", value: video.fileExtension.uppercased())
        addField(title: "大小", value: ByteCountFormatter.string(fromByteCount: video.fileSize, countStyle: .file))
        addField(title: "时长", value: formattedDuration(video.duration))
        let resolution = if let width = video.width, let height = video.height {
            "\(width) × \(height)"
        } else {
            "媒体信息不可用"
        }
        addField(title: "分辨率", value: resolution)
        addField(title: "创建时间", value: formattedDate(video.creationDate))
        addField(title: "修改时间", value: formattedDate(video.modificationDate))
        addField(title: "完整路径", value: filePath(video) ?? "文件位置不可用")
        updateScrollDocumentSize()
    }

    private func addPrimaryText(_ value: String) {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        contentStack.addArrangedSubview(label)
    }

    private func addFilename(_ filename: String) {
        let label = NSTextField(wrappingLabelWithString: filename)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.isSelectable = true

        let image = NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: "复制文件名"
        ) ?? NSImage()
        let copyButton = NSButton(image: image, target: self, action: #selector(copyFilename))
        copyButton.title = ""
        copyButton.imagePosition = .imageOnly
        copyButton.isBordered = false
        copyButton.controlSize = .small
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.toolTip = "复制文件名"
        copyButton.setAccessibilityLabel("复制文件名")
        copyButton.setContentHuggingPriority(.required, for: .horizontal)
        copyButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let filenameRow = NSStackView(views: [label, copyButton])
        filenameRow.orientation = .horizontal
        filenameRow.alignment = .centerY
        filenameRow.spacing = 6
        contentStack.addArrangedSubview(filenameRow)
        filenameRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func addSecondaryText(_ value: String) {
        let label = NSTextField(wrappingLabelWithString: value)
        label.textColor = .secondaryLabelColor
        contentStack.addArrangedSubview(label)
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
        contentStack.addArrangedSubview(fieldStack)
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

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "未知" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func addTagControls() {
        guard selectedVideos.isEmpty == false else { return }
        guard tagStateVideoIDs == selectedVideos.map(\.id) else {
            addSecondaryText("正在加载标签…")
            return
        }
        let orderedTagIDs = Set(loadedTagOrderIDs)
        let tagsByID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        let newlyAvailableTags = tags.filter { orderedTagIDs.contains($0.id) == false }
        let loadedTags = loadedTagOrderIDs.compactMap { tagsByID[$0] }
        let assignableTags = newlyAvailableTags + loadedTags
        let hasExactMatch = assignableTags.contains {
            $0.name.compare(tagSearchText, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        } || draftTagCreations.contains {
            $0.name.compare(tagSearchText, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if tagSearchText.isEmpty == false, hasExactMatch == false {
            addCreateTagButton(title: tagSearchText)
        }
        let visibleTags = assignableTags.filter {
            tagSearchText.isEmpty || $0.name.localizedCaseInsensitiveContains(tagSearchText)
        }
        let visibleCreations = draftTagCreations.reversed().filter {
            tagSearchText.isEmpty || $0.name.localizedCaseInsensitiveContains(tagSearchText)
        }
        for creation in visibleCreations {
            addPendingTagRow(creation)
        }
        for tag in visibleTags {
            let button = TagCheckbox(tag: tag, target: self, action: #selector(toggleTag(_:)))
            button.title = tag.name
            button.setButtonType(.switch)
            button.allowsMixedState = true
            switch draftTagStates[tag.id] ?? .off {
            case .off: button.state = .off
            case .mixed: button.state = .mixed
            case .on: button.state = .on
            }
            button.isEnabled = isApplyingTagChanges == false
            contentStack.addArrangedSubview(button)
        }
        if tagSearchText.isEmpty, assignableTags.isEmpty, draftTagCreations.isEmpty {
            addSecondaryText("暂无可用标签。可在搜索框中输入名称并新建。")
        } else if tagSearchText.isEmpty == false,
                  visibleTags.isEmpty,
                  visibleCreations.isEmpty,
                  hasExactMatch {
            addSecondaryText("没有匹配的标签。")
        }
    }

    private func addCreateTagButton(title: String) {
        let image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        let button = NSButton(title: "新建“\(title)”", target: self, action: #selector(createTagFromSearch(_:)))
        button.image = image
        button.imagePosition = .imageLeading
        button.isBordered = false
        button.alignment = .left
        button.contentTintColor = .controlAccentColor
        button.toolTip = "新建标签"
        button.setAccessibilityLabel("新建标签“\(title)”")
        button.isEnabled = isApplyingTagChanges == false
        contentStack.addArrangedSubview(button)
        button.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func addPendingTagRow(_ creation: TagCreationDraft) {
        let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        checkbox.state = .on
        checkbox.isEnabled = false

        let nameLabel = NSTextField(labelWithString: creation.name)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pathLabel = NSTextField(labelWithString: parentName(for: creation.parentID))
        pathLabel.font = .systemFont(ofSize: 10)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.setContentHuggingPriority(.required, for: .horizontal)

        let pendingLabel = NSTextField(labelWithString: "待新建")
        pendingLabel.font = .systemFont(ofSize: 9, weight: .medium)
        pendingLabel.textColor = .controlAccentColor
        pendingLabel.setContentHuggingPriority(.required, for: .horizontal)

        let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "移除待新建标签") ?? NSImage()
        let removeButton = NSButton(image: image, target: self, action: #selector(removePendingTag(_:)))
        removeButton.title = ""
        removeButton.isBordered = false
        removeButton.controlSize = .small
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.identifier = NSUserInterfaceItemIdentifier(creation.id)
        removeButton.toolTip = "移除待新建标签"
        removeButton.setAccessibilityLabel("移除待新建标签“\(creation.name)”")
        removeButton.isEnabled = isApplyingTagChanges == false

        let row = NSStackView(views: [checkbox, nameLabel, pathLabel, pendingLabel, removeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        contentStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    @objc private func changeSection(_ sender: NSSegmentedControl) {
        closeNewTagPopover()
        guard sender.selectedSegment == 0 else {
            renderSelection()
            return
        }
        showTagLoadingState()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sectionControl.selectedSegment == 0 else { return }
            if self.tagStateVideoIDs == self.selectedVideos.map(\.id) {
                self.renderSelection()
            } else {
                self.refreshTagAssignments()
            }
        }
    }

    @objc private func toggleTag(_ sender: TagCheckbox) {
        guard selectedVideos.isEmpty == false, isApplyingTagChanges == false else { return }
        let previousState = draftTagStates[sender.tagRecord.id] ?? .off
        let nextState: TagAssignmentState = previousState == .on ? .off : .on
        draftTagStates[sender.tagRecord.id] = nextState
        sender.state = nextState == .on ? .on : .off
        updateActionArea()
    }

    @objc private func discardTagChanges() {
        discardPendingTagChanges()
    }

    @objc private func applyTagChanges() {
        applyPendingTagChanges { [weak self] succeeded in
            self?.onTagApplicationFinished?(succeeded)
        }
    }

    @objc private func searchTags(_ sender: NSSearchField) {
        tagSearchText = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        renderSelection()
    }

    @objc private func createTagFromSearch(_ sender: NSButton) {
        showNewTagPopover(relativeTo: sender.bounds, of: sender, suggestedName: tagSearchText)
    }

    @objc private func removePendingTag(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, isApplyingTagChanges == false else { return }
        draftTagCreations.removeAll { $0.id == id }
        draftTagStates.removeValue(forKey: id)
        renderSelection()
    }

    var canBeginCreatingTag: Bool {
        selectedVideos.isEmpty == false && isApplyingTagChanges == false
    }

    func beginCreatingTag() {
        guard canBeginCreatingTag else { return }
        sectionControl.selectedSegment = 0
        renderSelection()
        showNewTagPopover(
            relativeTo: tagSearchField.bounds,
            of: tagSearchField,
            suggestedName: tagSearchText
        )
    }

    private func showNewTagPopover(relativeTo rect: NSRect, of positioningView: NSView, suggestedName: String) {
        guard canBeginCreatingTag else { return }
        closeNewTagPopover()
        let controller = NewTagPopoverViewController(
            suggestedName: suggestedName,
            parentOptions: parentTagOptions
        )
        controller.onCancel = { [weak self] in self?.closeNewTagPopover() }
        controller.onStage = { [weak self] name, parentID in
            guard let self else { return "无法新建标签，请重试。" }
            let duplicateExists = self.tags.contains {
                $0.parentID == parentID
                    && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            } || self.draftTagCreations.contains {
                $0.parentID == parentID
                    && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            guard duplicateExists == false else { return "同一父标签下已经存在同名标签。" }
            let creation = TagCreationDraft(id: UUID().uuidString, name: name, parentID: parentID)
            self.draftTagCreations.append(creation)
            self.draftTagStates[creation.id] = .on
            self.tagSearchText = ""
            self.tagSearchField.stringValue = ""
            self.closeNewTagPopover()
            self.renderSelection()
            return nil
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        newTagPopover = popover
        popover.show(relativeTo: rect, of: positioningView, preferredEdge: .maxY)
    }

    private func closeNewTagPopover() {
        newTagPopover?.performClose(nil)
        newTagPopover = nil
    }

    private var parentTagOptions: [NewTagParentOption] {
        tags
            .map { NewTagParentOption(id: $0.id, title: tagPath(for: $0)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func tagPath(for tag: TagRecord) -> String {
        var names = [tag.name]
        var parentID = tag.parentID
        var visited = Set([tag.id])
        while let currentID = parentID,
              visited.insert(currentID).inserted,
              let parent = tags.first(where: { $0.id == currentID }) {
            names.insert(parent.name, at: 0)
            parentID = parent.parentID
        }
        return names.joined(separator: " › ")
    }

    private func parentName(for parentID: String?) -> String {
        guard let parentID, let parent = tags.first(where: { $0.id == parentID }) else {
            return "顶级"
        }
        return tagPath(for: parent)
    }

    @objc private func copyFilename() {
        guard let filename = selectedVideo?.filename else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(filename, forType: .string)
    }

    private func scheduleInitialTagStateLoadIfNeeded() {
        guard sectionControl.selectedSegment == 0,
              selectedVideos.isEmpty == false,
              tagStateVideoIDs != selectedVideos.map(\.id) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.refreshTagAssignments()
        }
    }

    private func showTagLoadingState() {
        clearContent()
        if selectedVideos.isEmpty {
            addSecondaryText("选择一个或多个视频以查看标签或详情。")
        } else {
            addSecondaryText("正在加载标签…")
        }
        updateScrollDocumentSize()
        updateTagSearchFieldVisibility()
        updateActionArea()
    }

    func discardPendingTagChanges() {
        guard isApplyingTagChanges == false else { return }
        closeNewTagPopover()
        draftTagCreations = []
        draftTagStates = tagStates
        renderSelection()
    }

    func takePendingTagChanges() -> InspectorTagDraftSnapshot? {
        guard hasPendingTagChanges, isApplyingTagChanges == false else { return nil }
        let snapshot = InspectorTagDraftSnapshot(
            states: draftTagStates,
            creations: draftTagCreations
        )
        discardPendingTagChanges()
        return snapshot
    }

    func restorePendingTagChanges(_ snapshot: InspectorTagDraftSnapshot) {
        guard isApplyingTagChanges == false else { return }
        draftTagStates = snapshot.states
        draftTagCreations = snapshot.creations
        renderSelection()
    }

    func applyPendingTagChanges(completion: @escaping (Bool) -> Void) {
        let assignments = pendingTagAssignments
        let creations = draftTagCreations
        let videoIDs = selectedVideos.map(\.id)
        guard assignments.isEmpty == false || creations.isEmpty == false else {
            completion(true)
            return
        }
        guard videoIDs.isEmpty == false, isApplyingTagChanges == false else {
            completion(false)
            return
        }
        closeNewTagPopover()
        isApplyingTagChanges = true
        updateActionArea()
        onApplyTagDraft(creations, assignments, videoIDs) { [weak self] succeeded in
            guard let self else { return }
            self.isApplyingTagChanges = false
            if succeeded {
                self.draftTagCreations = []
                self.tagStates = [:]
                self.draftTagStates = [:]
                self.tagStateVideoIDs = []
                self.loadedTagOrderIDs = []
            }
            self.renderSelection()
            completion(succeeded)
        }
    }

    private var pendingTagAssignments: [String: Bool] {
        var assignments: [String: Bool] = [:]
        for tag in tags {
            let savedState = tagStates[tag.id] ?? .off
            let draftState = draftTagStates[tag.id] ?? .off
            guard savedState != draftState else { continue }
            switch draftState {
            case .on: assignments[tag.id] = true
            case .off: assignments[tag.id] = false
            case .mixed: break
            }
        }
        for creation in draftTagCreations {
            assignments[creation.id] = true
        }
        return assignments
    }

    private func configureActionArea() {
        actionContainer.orientation = .vertical
        actionContainer.alignment = .leading
        actionContainer.spacing = 8

        let separator = NSBox()
        separator.boxType = .separator
        actionContainer.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: actionContainer.widthAnchor).isActive = true

        draftStatusLabel.font = .systemFont(ofSize: 11)
        draftStatusLabel.textColor = .secondaryLabelColor
        actionContainer.addArrangedSubview(draftStatusLabel)
        draftStatusLabel.widthAnchor.constraint(equalTo: actionContainer.widthAnchor).isActive = true

        discardButton.controlSize = .small
        applyButton.controlSize = .small
        applyButton.keyEquivalent = "\r"
        applyButton.keyEquivalentModifierMask = [.command]
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, discardButton, applyButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        actionContainer.addArrangedSubview(buttonRow)
        buttonRow.widthAnchor.constraint(equalTo: actionContainer.widthAnchor).isActive = true
    }

    private func updateActionArea() {
        guard isViewLoaded else { return }
        let tagContentAvailable = sectionControl.selectedSegment == 0
            && selectedVideos.isEmpty == false
            && tagStateVideoIDs == selectedVideos.map(\.id)
        actionContainer.isHidden = tagContentAvailable == false
        guard tagContentAvailable else { return }
        let assignments = pendingTagAssignments
        let isDirty = assignments.isEmpty == false || draftTagCreations.isEmpty == false
        discardButton.isEnabled = isDirty && isApplyingTagChanges == false
        applyButton.isEnabled = isDirty && isApplyingTagChanges == false
        if isApplyingTagChanges {
            draftStatusLabel.stringValue = "正在应用标签…"
            return
        }
        guard isDirty else {
            draftStatusLabel.stringValue = "勾选标签后，点击“应用”保存更改。"
            return
        }
        let creations = draftTagCreations.count
        let additions = assignments.values.filter { $0 }.count
        let removals = assignments.values.filter { $0 == false }.count
        var parts: [String] = []
        if creations > 0 { parts.append("新建 \(creations) 个标签") }
        if additions > 0 { parts.append("添加 \(additions) 个标签") }
        if removals > 0 { parts.append("移除 \(removals) 个标签") }
        draftStatusLabel.stringValue = "\(parts.joined(separator: "，"))，尚未应用。"
    }

    private func updateTagSearchFieldVisibility() {
        guard isViewLoaded else { return }
        tagSearchField.isHidden = sectionControl.selectedSegment != 0
            || selectedVideos.isEmpty
    }

    private func clearContent() {
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    private func updateScrollDocumentSize() {
        guard isViewLoaded else { return }
        let width = contentScrollView.contentSize.width
        guard width > 0 else { return }
        contentStack.setFrameSize(NSSize(width: width, height: contentStack.frame.height))
        contentStack.layoutSubtreeIfNeeded()
        contentStack.setFrameSize(NSSize(
            width: width,
            height: max(1, contentStack.fittingSize.height)
        ))
    }

}

private final class InspectorContentStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class TagCheckbox: NSButton {
    let tagRecord: TagRecord
    init(tag: TagRecord, target: AnyObject?, action: Selector?) {
        self.tagRecord = tag
        super.init(frame: .zero)
        self.target = target
        self.action = action
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct NewTagParentOption {
    let id: String
    let title: String
}

@MainActor
private final class NewTagPopoverViewController: NSViewController {
    var onCancel: (() -> Void)?
    var onStage: ((String, String?) -> String?)?

    private let suggestedName: String
    private let parentOptions: [NewTagParentOption]
    private let nameField = NSTextField()
    private let parentPopup = NSPopUpButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    init(suggestedName: String, parentOptions: [NewTagParentOption]) {
        self.suggestedName = suggestedName
        self.parentOptions = parentOptions
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 300, height: 190)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        let titleLabel = NSTextField(labelWithString: "新建标签")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(titleLabel)

        nameField.stringValue = suggestedName
        nameField.placeholderString = "标签名称"
        nameField.target = self
        nameField.action = #selector(stageTag)
        addFormRow(title: "名称", control: nameField, to: stack)

        parentPopup.addItem(withTitle: "顶级（无父标签）")
        for option in parentOptions {
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            item.representedObject = option.id
            parentPopup.menu?.addItem(item)
        }
        addFormRow(title: "父标签", control: parentPopup, to: stack)

        let noteLabel = NSTextField(wrappingLabelWithString: "新标签将加入当前草稿。点击“应用”后创建标签并添加到当前视频。")
        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(noteLabel)
        noteLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        errorLabel.font = .systemFont(ofSize: 10)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        stack.addArrangedSubview(errorLabel)
        errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        let stageButton = NSButton(title: "加入草稿", target: self, action: #selector(stageTag))
        stageButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancelButton, stageButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -14),
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
        nameField.selectText(nil)
    }

    private func addFormRow(title: String, control: NSView, to stack: NSStackView) {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
    }

    @objc private func cancel() {
        onCancel?()
    }

    @objc private func stageTag() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else {
            showError("请输入标签名称。")
            return
        }
        let parentID = parentPopup.selectedItem?.representedObject as? String
        if let error = onStage?(name, parentID) {
            showError(error)
        }
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        nameField.selectText(nil)
    }
}
