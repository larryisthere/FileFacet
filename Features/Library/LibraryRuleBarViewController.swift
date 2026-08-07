import AppKit

struct LibraryRuleBarContext {
    let scopeTitle: String?
    let temporarySearch: String
    var rule: LibraryQueryRule
    let presetSort: LibraryVideoSort?
    let tags: [TagRecord]
    let smartCollection: SmartCollectionRecord?
    let isDirty: Bool
    let hasPersistableBaseScope: Bool
    let canSaveAsSmartCollection: Bool
    var grouping: VideoGroupingPreference
}

@MainActor
final class LibraryRuleBarViewController: NSViewController, NSPopoverDelegate {
    var onRuleChanged: ((LibraryQueryRule) -> Void)?
    var onClearTemporarySearch: (() -> Void)?
    var onClearRules: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onRevert: (() -> Void)?
    var onUpdate: (() -> Void)?
    var onGroupingChanged: ((VideoGroupingPreference) -> Void)?

    private var context = LibraryRuleBarContext(
        scopeTitle: nil,
        temporarySearch: "",
        rule: .standard,
        presetSort: nil,
        tags: [],
        smartCollection: nil,
        isDirty: false,
        hasPersistableBaseScope: false,
        canSaveAsSmartCollection: true,
        grouping: .standard
    )
    private let chipStack = NSStackView()
    private let actionStack = NSStackView()
    private weak var addFilterButton: NSButton?
    private var activePopover: NSPopover?

    override func loadView() {
        let root = RuleBarBackgroundView()

        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipStack.orientation = .horizontal
        chipStack.alignment = .centerY
        chipStack.spacing = 6

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = chipStack

        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 2

        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        root.addSubview(scrollView)
        root.addSubview(actionStack)
        root.addSubview(separator)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),
            scrollView.trailingAnchor.constraint(equalTo: actionStack.leadingAnchor, constant: -8),
            chipStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            chipStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            chipStack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            chipStack.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
            chipStack.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor),
            actionStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            actionStack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        render()
    }

    func configure(_ context: LibraryRuleBarContext) {
        self.context = context
        guard activePopover?.isShown != true else { return }
        if isViewLoaded { render() }
    }

    func popoverDidClose(_ notification: Notification) {
        activePopover = nil
        render()
    }

    private func render() {
        chipStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let heading = NSTextField(labelWithString: context.smartCollection?.name
            ?? String(localized: "filter.heading", defaultValue: "Filter"))
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        chipStack.addArrangedSubview(heading)

        var hasPreviousRule = false
        if let scopeTitle = context.scopeTitle {
            addConnectorIfNeeded(hasPreviousRule)
            chipStack.addArrangedSubview(staticChip(
                String(localized: "filter.scope", defaultValue: "Scope: \(scopeTitle)")
            ))
            hasPreviousRule = true
        }
        if context.temporarySearch.isEmpty == false {
            addConnectorIfNeeded(hasPreviousRule)
            chipStack.addArrangedSubview(removableChip(
                String(
                    localized: "filter.temporarySearch",
                    defaultValue: "Temporary search: \(context.temporarySearch)"
                ),
                action: #selector(clearTemporarySearch)
            ))
            hasPreviousRule = true
        }
        if context.rule.requiredTagIDs.isEmpty == false {
            addConnectorIfNeeded(hasPreviousRule)
            chipStack.addArrangedSubview(removableEditableChip(
                requiredTagsLabel(),
                editAction: #selector(editRequiredTags(_:)),
                removeAction: #selector(removeRequiredTags)
            ))
            hasPreviousRule = true
        }
        for (index, condition) in context.rule.requiredConditions.enumerated() {
            addConnectorIfNeeded(hasPreviousRule)
            let conditionView = removableEditableChip(
                conditionLabel(condition),
                tag: index,
                editAction: #selector(editRequiredCondition(_:)),
                removeAction: #selector(removeRequiredCondition(_:))
            )
            chipStack.addArrangedSubview(conditionView)
            hasPreviousRule = true
        }
        for (index, filenameRule) in context.rule.filenameContains.enumerated() {
            addConnectorIfNeeded(hasPreviousRule)
            let filenameView = removableEditableChip(
                String(
                    localized: "filter.filenameContains",
                    defaultValue: "Filename contains “\(filenameRule)”"
                ),
                tag: index,
                editAction: #selector(editFilename(_:)),
                removeAction: #selector(removeFilename(_:))
            )
            chipStack.addArrangedSubview(filenameView)
            hasPreviousRule = true
        }
        if context.rule.conditions.isEmpty == false {
            addConnectorIfNeeded(hasPreviousRule)
            let matchButton = chipButton(matchModeLabel(), style: .plain)
            matchButton.target = self
            matchButton.action = #selector(editMatchMode(_:))
            chipStack.addArrangedSubview(matchButton)
            for (index, condition) in context.rule.conditions.enumerated() {
                let conditionView = removableEditableChip(
                    conditionLabel(condition),
                    tag: index,
                    editAction: #selector(editCondition(_:)),
                    removeAction: #selector(removeCondition(_:))
                )
                conditionView.setAccessibilityIdentifier("filter.condition.\(index)")
                chipStack.addArrangedSubview(conditionView)
            }
        }

        let addFilterTitle = String(
            localized: "filter.add",
            defaultValue: "Add Filter Condition"
        )
        let hasVisibleFilterCondition = context.scopeTitle != nil
            || context.temporarySearch.isEmpty == false
            || context.rule.requiredTagIDs.isEmpty == false
            || context.rule.requiredConditions.isEmpty == false
            || context.rule.filenameContains.isEmpty == false
            || context.rule.conditions.isEmpty == false
        let addFilter: NSButton
        if hasVisibleFilterCondition {
            addFilter = actionIconButton(
                symbolName: "line.3.horizontal.decrease.circle",
                title: addFilterTitle,
                action: #selector(showAddFilterMenu(_:))
            )
        } else {
            addFilter = chipButton(addFilterTitle, style: .add)
            addFilter.target = self
            addFilter.action = #selector(showAddFilterMenu(_:))
            addFilter.setAccessibilityLabel(addFilterTitle)
        }
        addFilter.toolTip = String(
            localized: "filter.addShortcutTooltip",
            defaultValue: "Add Filter Condition (⇧⌘F)"
        )
        addFilterButton = addFilter
        chipStack.addArrangedSubview(addFilter)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 22).isActive = true
        chipStack.addArrangedSubview(divider)

        if let presetSort = context.presetSort {
            chipStack.addArrangedSubview(staticChip(sortLabel(presetSort)))
        } else if context.rule.sort == .standard {
            let addSortTitle = String(localized: "filter.addSort", defaultValue: "Add Sort")
            let addSort = chipButton(addSortTitle, style: .add)
            addSort.target = self
            addSort.action = #selector(editSort(_:))
            addSort.toolTip = addSortTitle
            addSort.setAccessibilityLabel(addSortTitle)
            chipStack.addArrangedSubview(addSort)
        } else {
            let sortButton = chipButton(sortLabel())
            sortButton.target = self
            sortButton.action = #selector(editSort(_:))
            chipStack.addArrangedSubview(removableChipView(
                mainButton: sortButton,
                removeAction: #selector(removeSort)
            ))
        }

        let groupingDivider = NSBox()
        groupingDivider.boxType = .separator
        groupingDivider.translatesAutoresizingMaskIntoConstraints = false
        groupingDivider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        groupingDivider.heightAnchor.constraint(equalToConstant: 22).isActive = true
        chipStack.addArrangedSubview(groupingDivider)

        let groupingButton = chipButton(
            groupingLabel(),
            style: context.grouping.key == .none ? .add : .plain
        )
        groupingButton.target = self
        groupingButton.action = #selector(showGroupingMenu(_:))
        groupingButton.toolTip = groupingTooltip()
        groupingButton.setAccessibilityLabel(groupingTooltip())
        if context.grouping.key == .none {
            chipStack.addArrangedSubview(groupingButton)
        } else {
            chipStack.addArrangedSubview(removableChipView(
                mainButton: groupingButton,
                removeAction: #selector(removeGrouping),
                appearance: .accent,
                removeTitle: String(localized: "grouping.clear", defaultValue: "Clear Grouping")
            ))
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chipStack.addArrangedSubview(spacer)

        renderActions()
    }

    private func renderActions() {
        let hasEditableRule = context.temporarySearch.isEmpty == false || context.rule.isStandard == false
        let hasSavableRule = context.hasPersistableBaseScope || hasEditableRule
        if context.smartCollection != nil, context.isDirty {
            let status = NSTextField(
                labelWithString: String(localized: "filter.modified", defaultValue: "Rule Modified")
            )
            status.font = .systemFont(ofSize: 11)
            status.textColor = .systemOrange
            actionStack.addArrangedSubview(status)
            actionStack.addArrangedSubview(actionButton(
                String(localized: "filter.revert", defaultValue: "Revert"),
                action: #selector(revertRule)
            ))
            actionStack.addArrangedSubview(actionButton(
                String(localized: "filter.saveAs", defaultValue: "Save As…"),
                action: #selector(saveAs)
            ))
            actionStack.addArrangedSubview(actionButton(
                String(localized: "filter.update", defaultValue: "Update"),
                action: #selector(updateRule)
            ))
        } else if context.smartCollection == nil {
            let clearTitle = String(
                localized: "filter.clearTooltip",
                defaultValue: "Clear search, filters, and sort"
            )
            let clear = actionIconButton(
                symbolName: "xmark.circle",
                title: clearTitle,
                action: #selector(clearRules)
            )
            clear.isEnabled = hasEditableRule
            let saveTitle = String(localized: "action.save", defaultValue: "Save")
            let saveDescription = String(
                localized: "filter.saveSmartCollection",
                defaultValue: "Save as Smart Collection…"
            )
            let save = actionButton(saveTitle, action: #selector(saveAs))
            save.toolTip = saveDescription
            save.setAccessibilityLabel(saveDescription)
            save.isEnabled = hasSavableRule && context.canSaveAsSmartCollection
            if context.canSaveAsSmartCollection == false {
                save.toolTip = String(
                    localized: "filter.unavailableCannotSave",
                    defaultValue: "Unavailable status cannot be saved as a smart collection."
                )
            }
            actionStack.addArrangedSubview(clear)
            actionStack.addArrangedSubview(save)
        }
    }

    private func chipButton(
        _ title: String,
        style: RuleBarButton.Style = .plain
    ) -> RuleBarButton {
        let button = RuleBarButton(title: title, style: style)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func actionButton(_ title: String, action: Selector) -> NSButton {
        let button = RuleBarButton(title: title, style: .link)
        button.target = self
        button.action = action
        return button
    }

    private func actionIconButton(
        symbolName: String,
        title: String,
        action: Selector
    ) -> NSButton {
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: title
        ) ?? NSImage()
        let button = RuleBarActionIconButton(image: image)
        button.target = self
        button.action = action
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }

    private func staticChip(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return RuleBarChipContainer(contentView: label)
    }

    private func removableChip(_ title: String, action: Selector) -> NSView {
        removableChipView(
            mainButton: chipButton(title),
            removeAction: action,
            appearance: .accent
        )
    }

    private func removableEditableChip(
        _ title: String,
        tag: Int? = nil,
        editAction: Selector,
        removeAction: Selector
    ) -> NSView {
        let button = chipButton(title)
        if let tag { button.tag = tag }
        button.target = self
        button.action = editAction
        return removableChipView(
            mainButton: button,
            removeAction: removeAction,
            tag: tag
        )
    }

    private func removableChipView(
        mainButton: NSButton,
        removeAction: Selector,
        tag: Int? = nil,
        appearance: RuleBarChipContainer.Appearance = .neutral,
        removeTitle: String = String(localized: "filter.remove", defaultValue: "Remove")
    ) -> NSView {
        let remove = RuleBarIconButton(
            image: NSImage(
                systemSymbolName: "xmark",
                accessibilityDescription: removeTitle
            ) ?? NSImage()
        )
        if let tag { remove.tag = tag }
        remove.target = self
        remove.action = removeAction
        remove.toolTip = removeTitle
        remove.setAccessibilityLabel(removeTitle)
        let stack = NSStackView(views: [mainButton, remove])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        return RuleBarChipContainer(contentView: stack, appearance: appearance)
    }

    private func addConnectorIfNeeded(_ needed: Bool) {
        guard needed else { return }
        let label = NSTextField(
            labelWithString: String(localized: "filter.and", defaultValue: "and")
        )
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        chipStack.addArrangedSubview(label)
    }

    private func tagName(_ id: String) -> String {
        context.tags.first(where: { $0.id == id })?.name
            ?? String(localized: "filter.deletedTag", defaultValue: "Deleted Tag")
    }

    private func requiredTagsLabel() -> String {
        let names = joinedTagNames(context.rule.requiredTagIDs)
        return String(localized: "filter.requiredTags", defaultValue: "Tags include \(names)")
    }

    private func matchModeLabel() -> String {
        context.rule.matchMode == .all
            ? String(localized: "filter.matchAll", defaultValue: "Match All Conditions")
            : String(localized: "filter.matchAny", defaultValue: "Match Any Condition")
    }

    private func conditionLabel(_ condition: LibraryFilterCondition) -> String {
        switch condition {
        case let .tags(tagOperator, tagIDs):
            let names = joinedTagNames(tagIDs)
            switch tagOperator {
            case .all:
                return String(localized: "filter.tagsAll", defaultValue: "Tags include all: \(names)")
            case .any:
                return String(localized: "filter.tagsAny", defaultValue: "Tags include any: \(names)")
            case .exclude:
                return String(localized: "filter.tagsExclude", defaultValue: "Exclude tags: \(names)")
            }
        case .untagged:
            return String(localized: "filter.untagged", defaultValue: "Untagged")
        case let .addedWithinDays(days):
            return String(localized: "filter.addedDays", defaultValue: "Added in last \(days) days")
        case let .createdWithinDays(days):
            return String(localized: "filter.createdDays", defaultValue: "Created in last \(days) days")
        case let .durationAtLeast(seconds):
            return String(localized: "filter.duration", defaultValue: "Duration ≥ \(Int(seconds / 60)) min")
        case let .fileSizeAtLeast(bytes):
            return String(localized: "filter.fileSize", defaultValue: "Size ≥ \(formatBytes(bytes))")
        case let .resolutionWidthAtLeast(width):
            return width >= 3840
                ? String(localized: "filter.resolution4K", defaultValue: "Resolution ≥ 4K")
                : String(localized: "filter.resolution1080", defaultValue: "Resolution ≥ 1080p")
        }
    }

    private func joinedTagNames(_ tagIDs: [String]) -> String {
        ListFormatter.localizedString(byJoining: tagIDs.map(tagName))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func sortLabel() -> String {
        sortLabel(context.rule.sort)
    }

    private func sortLabel(_ sort: LibraryVideoSort) -> String {
        guard sort != .standard else {
            return String(localized: "filter.addSort", defaultValue: "Add Sort")
        }
        let key = sortKeyTitle(sort.key)
        let direction = sortDirectionTitle(sort)
        return String(localized: "filter.sortSummary", defaultValue: "Sort: \(key) · \(direction)")
    }

    private func sortKeyTitle(_ key: LibraryVideoSortKey) -> String {
        switch key {
        case .filename: String(localized: "filter.sort.filename", defaultValue: "Filename")
        case .added: String(localized: "filter.sort.added", defaultValue: "Date Added")
        case .created: String(localized: "filter.sort.created", defaultValue: "Date Created")
        case .modified: String(localized: "filter.sort.modified", defaultValue: "Date Modified")
        case .duration: String(localized: "filter.sort.duration", defaultValue: "Duration")
        case .fileSize: String(localized: "filter.sort.fileSize", defaultValue: "File Size")
        case .resolution: String(localized: "filter.sort.resolution", defaultValue: "Resolution")
        }
    }

    private func sortDirectionTitle(_ sort: LibraryVideoSort) -> String {
        if sort.key == .filename {
            return sort.direction == .ascending
                ? String(localized: "filter.sort.az", defaultValue: "A to Z")
                : String(localized: "filter.sort.za", defaultValue: "Z to A")
        }
        if [.added, .created, .modified].contains(sort.key) {
            return sort.direction == .descending
                ? String(localized: "filter.sort.newest", defaultValue: "Newest First")
                : String(localized: "filter.sort.oldest", defaultValue: "Oldest First")
        }
        return sort.direction == .ascending
            ? String(localized: "filter.sort.smallest", defaultValue: "Smallest First")
            : String(localized: "filter.sort.largest", defaultValue: "Largest First")
    }

    private func groupingLabel() -> String {
        guard context.grouping.key != .none else {
            return String(localized: "grouping.add", defaultValue: "Add Grouping")
        }
        let key = groupingKeyTitle(context.grouping.key)
        return String(localized: "grouping.summary", defaultValue: "Group: \(key)")
    }

    private func groupingTooltip() -> String {
        guard context.grouping.key != .none else {
            return String(localized: "grouping.add", defaultValue: "Add Grouping")
        }
        let key = groupingKeyTitle(context.grouping.key)
        let direction = groupingDirectionTitle(context.grouping)
        return String(localized: "grouping.tooltip", defaultValue: "Group by \(key), \(direction)")
    }

    private func groupingKeyTitle(_ key: VideoGroupingKey) -> String {
        switch key {
        case .none:
            String(localized: "grouping.none", defaultValue: "No Grouping")
        case .addedDate:
            String(localized: "filter.sort.added", defaultValue: "Date Added")
        case .createdDate:
            String(localized: "filter.sort.created", defaultValue: "Date Created")
        case .modifiedDate:
            String(localized: "filter.sort.modified", defaultValue: "Date Modified")
        case .duration:
            String(localized: "filter.sort.duration", defaultValue: "Duration")
        case .fileSize:
            String(localized: "filter.sort.fileSize", defaultValue: "File Size")
        case .resolution:
            String(localized: "filter.sort.resolution", defaultValue: "Resolution")
        }
    }

    private func groupingDirectionTitle(_ grouping: VideoGroupingPreference) -> String {
        let usesDateDirection = [.addedDate, .createdDate, .modifiedDate].contains(grouping.key)
        if usesDateDirection {
            return grouping.direction == .descending
                ? String(localized: "filter.sort.newest", defaultValue: "Newest First")
                : String(localized: "filter.sort.oldest", defaultValue: "Oldest First")
        }
        return grouping.direction == .descending
            ? String(localized: "filter.sort.largest", defaultValue: "Largest First")
            : String(localized: "filter.sort.smallest", defaultValue: "Smallest First")
    }

    private func mutateRule(_ mutation: (inout LibraryQueryRule) -> Void) {
        activePopover?.close()
        mutation(&context.rule)
        context.rule = context.rule.normalized()
        onRuleChanged?(context.rule)
        render()
    }

    func presentAddFilterMenu() {
        loadViewIfNeeded()
        activePopover?.close()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let addFilterButton,
                  addFilterButton.isEnabled else { return }
            showAddFilterMenu(addFilterButton)
        }
    }

    @objc private func clearTemporarySearch() {
        onClearTemporarySearch?()
    }

    @objc private func removeRequiredTags() {
        mutateRule { $0.requiredTagIDs = [] }
    }

    @objc private func removeFilename(_ sender: NSButton) {
        mutateRule { rule in
            guard rule.filenameContains.indices.contains(sender.tag) else { return }
            rule.filenameContains.remove(at: sender.tag)
        }
    }

    @objc private func removeRequiredCondition(_ sender: NSButton) {
        mutateRule { rule in
            guard rule.requiredConditions.indices.contains(sender.tag) else { return }
            rule.requiredConditions.remove(at: sender.tag)
        }
    }

    @objc private func removeCondition(_ sender: NSButton) {
        mutateRule { rule in
            guard rule.conditions.indices.contains(sender.tag) else { return }
            rule.conditions.remove(at: sender.tag)
        }
    }

    @objc private func removeSort() {
        mutateRule { $0.sort = .standard }
    }

    @objc private func removeGrouping() {
        context.grouping.key = .none
        onGroupingChanged?(context.grouping)
        render()
    }

    @objc private func showGroupingMenu(_ sender: NSButton) {
        activePopover?.close()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for key in VideoGroupingKey.allCases {
            let item = NSMenuItem(
                title: groupingKeyTitle(key),
                action: #selector(selectGroupingKey(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = key.rawValue
            item.state = context.grouping.key == key ? .on : .off
            item.isEnabled = true
            menu.addItem(item)
            if key == .none { menu.addItem(.separator()) }
        }

        menu.addItem(.separator())
        for direction in VideoGroupingDirection.allCases.reversed() {
            let candidate = VideoGroupingPreference(key: context.grouping.key, direction: direction)
            let item = NSMenuItem(
                title: groupingDirectionTitle(candidate),
                action: #selector(selectGroupingDirection(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = direction.rawValue
            item.state = context.grouping.direction == direction ? .on : .off
            item.isEnabled = context.grouping.key != .none
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func selectGroupingKey(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let key = VideoGroupingKey(rawValue: rawValue) else { return }
        context.grouping.key = key
        onGroupingChanged?(context.grouping)
        render()
    }

    @objc private func selectGroupingDirection(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let direction = VideoGroupingDirection(rawValue: rawValue) else { return }
        context.grouping.direction = direction
        onGroupingChanged?(context.grouping)
        render()
    }

    @objc private func showAddFilterMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let entries: [(String, String)] = [
            ("filename", String(localized: "filter.type.filename", defaultValue: "Filename")),
            ("tags", String(localized: "filter.type.tags", defaultValue: "Tags")),
            ("untagged", String(localized: "filter.type.untagged", defaultValue: "Untagged")),
            ("added", String(localized: "filter.type.added", defaultValue: "Date Added")),
            ("created", String(localized: "filter.type.created", defaultValue: "Date Created")),
            ("duration", String(localized: "filter.type.duration", defaultValue: "Duration")),
            ("fileSize", String(localized: "filter.type.fileSize", defaultValue: "File Size")),
            ("resolution", String(localized: "filter.type.resolution", defaultValue: "Resolution")),
        ]
        for (kind, title) in entries {
            let item = NSMenuItem(title: title, action: #selector(addFilter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind
            if kind == "tags" {
                item.isEnabled = context.tags.isEmpty == false
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func addFilter(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String else { return }
        if kind == "filename" {
            guard let addFilterButton else { return }
            var editorRule = context.rule
            editorRule.filenameContains.append("")
            presentEditor(
                .filename(editorRule.filenameContains.count - 1),
                rule: editorRule,
                relativeTo: addFilterButton,
                isNew: true
            )
            return
        }
        guard let addFilterButton else { return }
        var editorRule = context.rule
        let condition: LibraryFilterCondition
        switch kind {
        case "tags":
            guard context.tags.isEmpty == false else { return }
            condition = .tags(operator: .all, tagIDs: [])
        case "untagged":
            condition = .untagged
        case "added":
            condition = .addedWithinDays(30)
        case "created":
            condition = .createdWithinDays(30)
        case "duration":
            condition = .durationAtLeast(60)
        case "fileSize":
            condition = .fileSizeAtLeast(1_000_000_000)
        case "resolution":
            condition = .resolutionWidthAtLeast(3840)
        default:
            return
        }
        editorRule.conditions.append(condition)
        presentEditor(
            .condition(editorRule.conditions.count - 1),
            rule: editorRule,
            relativeTo: addFilterButton,
            isNew: true
        )
    }

    @objc private func editFilename(_ sender: NSButton) {
        presentEditor(.filename(sender.tag), relativeTo: sender)
    }

    @objc private func editRequiredTags(_ sender: NSButton) {
        presentEditor(.requiredTags, relativeTo: sender)
    }

    @objc private func editRequiredCondition(_ sender: NSButton) {
        presentEditor(.requiredCondition(sender.tag), relativeTo: sender)
    }

    @objc private func editMatchMode(_ sender: NSButton) {
        presentEditor(.matchMode, relativeTo: sender)
    }

    @objc private func editCondition(_ sender: NSButton) {
        presentEditor(.condition(sender.tag), relativeTo: sender)
    }

    @objc private func editSort(_ sender: NSButton) {
        presentEditor(
            .sort,
            relativeTo: sender,
            isNew: context.rule.sort == .standard
        )
    }

    private func presentEditor(
        _ mode: LibraryRuleEditorViewController.Mode,
        rule: LibraryQueryRule? = nil,
        relativeTo view: NSView,
        isNew: Bool = false
    ) {
        activePopover?.close()
        let editorRule = rule ?? context.rule
        let editor = LibraryRuleEditorViewController(
            mode: mode,
            rule: editorRule,
            tags: context.tags,
            allowsDeletion: isNew == false,
            isDuplicate: { [weak self] rule in
                guard let self else { return false }
                return self.hasDuplicateCondition(
                    in: rule,
                    editing: mode
                )
            },
            onCommit: { [weak self] rule in
                guard let self else { return false }
                guard self.hasDuplicateCondition(
                    in: rule,
                    editing: mode
                ) == false else {
                    return false
                }
                let normalizedRule = rule.normalized()
                guard normalizedRule != context.rule else { return true }
                context.rule = normalizedRule
                onRuleChanged?(context.rule)
                return true
            },
            onDelete: { [weak self] in
                guard let self else { return }
                switch mode {
                case let .filename(index):
                    if context.rule.filenameContains.indices.contains(index) {
                        context.rule.filenameContains.remove(at: index)
                    }
                case .requiredTags:
                    context.rule.requiredTagIDs = []
                case let .requiredCondition(index):
                    if context.rule.requiredConditions.indices.contains(index) {
                        context.rule.requiredConditions.remove(at: index)
                    }
                case let .condition(index):
                    if context.rule.conditions.indices.contains(index) {
                        context.rule.conditions.remove(at: index)
                    }
                case .sort:
                    context.rule.sort = .standard
                case .matchMode:
                    break
                }
                context.rule = context.rule.normalized()
                onRuleChanged?(context.rule)
                activePopover?.close()
            }
        )
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = editor
        editor.onCancel = { [weak popover] in
            popover?.close()
        }
        activePopover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    private func hasDuplicateCondition(
        in rule: LibraryQueryRule,
        editing mode: LibraryRuleEditorViewController.Mode
    ) -> Bool {
        switch mode {
        case let .filename(index):
            guard rule.filenameContains.indices.contains(index) else { return false }
            let candidate = rule.filenameContains[index]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return rule.filenameContains.enumerated().contains { otherIndex, value in
                otherIndex != index
                    && value.trimmingCharacters(in: .whitespacesAndNewlines)
                        .caseInsensitiveCompare(candidate) == .orderedSame
            }
        case let .requiredCondition(index):
            guard rule.requiredConditions.indices.contains(index) else { return false }
            let candidate = rule.requiredConditions[index]
            return rule.requiredConditions.enumerated().contains { otherIndex, condition in
                otherIndex != index && conditionsAreEquivalent(condition, candidate)
            }
        case let .condition(index):
            guard rule.conditions.indices.contains(index) else { return false }
            let candidate = rule.conditions[index]
            return rule.conditions.enumerated().contains { otherIndex, condition in
                otherIndex != index && conditionsAreEquivalent(condition, candidate)
            }
        case .requiredTags, .matchMode, .sort:
            return false
        }
    }

    private func conditionsAreEquivalent(
        _ lhs: LibraryFilterCondition,
        _ rhs: LibraryFilterCondition
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.tags(lhsOperator, lhsIDs), .tags(rhsOperator, rhsIDs)):
            return lhsOperator == rhsOperator && Set(lhsIDs) == Set(rhsIDs)
        default:
            return lhs == rhs
        }
    }

    @objc private func clearRules() {
        onClearRules?()
    }

    @objc private func saveAs() {
        onSaveAs?()
    }

    @objc private func revertRule() {
        onRevert?()
    }

    @objc private func updateRule() {
        onUpdate?()
    }
}

@MainActor
private final class RuleBarBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}

@MainActor
private final class RuleBarButton: NSButton {
    enum Style {
        case plain
        case add
        case link
    }

    private let ruleBarStyle: Style
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(title: String, style: Style) {
        ruleBarStyle = style
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        controlSize = .small
        font = .systemFont(ofSize: 11)
        wantsLayer = true
        layer?.cornerRadius = 5
        focusRingType = .default
        contentTintColor = style == .plain ? .labelColor : .controlAccentColor
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override var intrinsicContentSize: NSSize {
        let titleSize = (title as NSString).size(withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 11),
        ])
        return NSSize(width: ceil(titleSize.width) + 16, height: 27)
    }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.48
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func updateLayer() {
        guard isHovered, isEnabled else {
            layer?.backgroundColor = NSColor.clear.cgColor
            return
        }
        switch ruleBarStyle {
        case .plain:
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        case .add, .link:
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        }
    }
}

@MainActor
private final class RuleBarActionIconButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(image: NSImage) {
        super.init(frame: .zero)
        self.image = image
        imageScaling = .scaleProportionallyDown
        symbolConfiguration = .init(pointSize: 13, weight: .regular)
        isBordered = false
        bezelStyle = .regularSquare
        controlSize = .small
        contentTintColor = .controlAccentColor
        wantsLayer = true
        layer?.cornerRadius = 5
        focusRingType = .default
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 28, height: 28)
    }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.48
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func updateLayer() {
        layer?.backgroundColor = isHovered && isEnabled
            ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
    }
}

@MainActor
private final class RuleBarIconButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(image: NSImage) {
        super.init(frame: .zero)
        self.image = image
        imageScaling = .scaleProportionallyDown
        symbolConfiguration = .init(pointSize: 8, weight: .medium)
        isBordered = false
        bezelStyle = .regularSquare
        controlSize = .mini
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = 4
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 21, height: 24)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func updateLayer() {
        layer?.backgroundColor = isHovered
            ? NSColor.labelColor.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
    }
}

@MainActor
private final class RuleBarChipContainer: NSView {
    enum Appearance {
        case neutral
        case accent
    }

    private let chipAppearance: Appearance

    init(contentView: NSView, appearance: Appearance = .neutral) {
        chipAppearance = appearance
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        let isLabel = contentView is NSTextField
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: isLabel ? 8 : 0),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: isLabel ? -8 : 0),
            contentView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        switch chipAppearance {
        case .neutral:
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor
                .withAlphaComponent(0.34)
                .cgColor
        case .accent:
            layer?.borderColor = NSColor.controlAccentColor
                .withAlphaComponent(0.42)
                .cgColor
            layer?.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(0.10)
                .cgColor
        }
    }
}

@MainActor
private final class LibraryRuleEditorViewController: NSViewController, NSTextFieldDelegate {
    private static let popoverWidth: CGFloat = 320
    private static let fieldWidth: CGFloat = 292
    private static let maximumPopoverHeight: CGFloat = 320
    private static let maximumTagListHeight: CGFloat = 120

    enum Mode {
        case filename(Int)
        case requiredTags
        case requiredCondition(Int)
        case matchMode
        case condition(Int)
        case sort
    }

    private let mode: Mode
    private var rule: LibraryQueryRule
    private let tags: [TagRecord]
    private let allowsDeletion: Bool
    private let isDuplicate: (LibraryQueryRule) -> Bool
    private let onCommit: (LibraryQueryRule) -> Bool
    private let onDelete: () -> Void
    private weak var validationLabel: NSTextField?
    private weak var doneButton: NSButton?
    private weak var sortDirectionPopup: NSPopUpButton?
    var onCancel: (() -> Void)?

    init(
        mode: Mode,
        rule: LibraryQueryRule,
        tags: [TagRecord],
        allowsDeletion: Bool,
        isDuplicate: @escaping (LibraryQueryRule) -> Bool,
        onCommit: @escaping (LibraryQueryRule) -> Bool,
        onDelete: @escaping () -> Void
    ) {
        self.mode = mode
        self.rule = rule
        self.tags = tags
        self.allowsDeletion = allowsDeletion
        self.isDuplicate = isDuplicate
        self.onCommit = onCommit
        self.onDelete = onDelete
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: Self.popoverWidth, height: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)

        let title = NSTextField(labelWithString: editorTitle)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(title)

        switch mode {
        case .filename:
            addFilenameEditor(to: stack)
        case .requiredTags:
            addTagCheckboxes(
                selected: Set(rule.requiredTagIDs),
                action: #selector(toggleRequiredTag(_:)),
                to: stack
            )
        case .requiredCondition, .condition:
            addConditionEditor(to: stack)
        case .matchMode:
            addMatchModeEditor(to: stack)
        case .sort:
            addSortEditor(to: stack)
        }

        let validation = NSTextField(wrappingLabelWithString: "")
        validation.font = .systemFont(ofSize: 10)
        validation.textColor = .secondaryLabelColor
        validation.isHidden = true
        validation.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        if reservesValidationSpace {
            validation.heightAnchor.constraint(greaterThanOrEqualToConstant: 13).isActive = true
        }
        stack.addArrangedSubview(validation)
        validationLabel = validation

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        actionRow.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        let showsDelete: Bool
        if case .matchMode = mode {
            showsDelete = false
        } else {
            showsDelete = allowsDeletion
        }
        if showsDelete {
            let delete = NSButton(
                title: deleteTitle,
                target: self,
                action: #selector(deleteRule)
            )
            delete.bezelStyle = .roundRect
            delete.controlSize = .small
            actionRow.addArrangedSubview(delete)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionRow.addArrangedSubview(spacer)
        let cancel = NSButton(
            title: String(localized: .actionCancel),
            target: self,
            action: #selector(cancelEditor)
        )
        cancel.bezelStyle = .roundRect
        cancel.controlSize = .small
        cancel.keyEquivalent = "\u{1b}"
        actionRow.addArrangedSubview(cancel)
        let done = NSButton(
            title: String(localized: .actionDone),
            target: self,
            action: #selector(commitEditor)
        )
        done.bezelStyle = .roundRect
        done.controlSize = .small
        done.keyEquivalent = "\r"
        actionRow.addArrangedSubview(done)
        doneButton = done
        stack.addArrangedSubview(actionRow)

        let validationMessage = draftValidationMessage
        done.isEnabled = validationMessage == nil
        validation.stringValue = validationMessage ?? ""
        validation.isHidden = validationMessage == nil && reservesValidationSpace == false
        let fittedHeight = ceil(stack.fittingSize.height)

        view = stack
        preferredContentSize = NSSize(
            width: Self.popoverWidth,
            height: min(Self.maximumPopoverHeight, fittedHeight)
        )
    }

    private var editorTitle: String {
        switch mode {
        case .filename:
            String(localized: "filter.editor.filename", defaultValue: "Edit Filename Filter")
        case .requiredTags:
            String(localized: "filter.editor.requiredTags", defaultValue: "Edit Required Tags")
        case .requiredCondition, .condition:
            String(localized: "filter.editor.condition", defaultValue: "Edit Filter")
        case .matchMode:
            String(localized: "filter.editor.match", defaultValue: "Filter Relationship")
        case .sort:
            String(localized: "filter.editor.sort", defaultValue: "Sort Videos")
        }
    }

    private var deleteTitle: String {
        if case .sort = mode {
            return String(localized: "filter.sort.reset", defaultValue: "Reset to Default")
        }
        return String(localized: "filter.removeCondition", defaultValue: "Remove Filter")
    }

    private var reservesValidationSpace: Bool {
        if case .matchMode = mode { return false }
        return true
    }

    private func addFilenameEditor(to stack: NSStackView) {
        guard case let .filename(index) = mode,
              rule.filenameContains.indices.contains(index) else { return }
        let field = NSTextField(string: rule.filenameContains[index])
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = String(localized: "filter.filenamePlaceholder", defaultValue: "Text in filename")
        field.delegate = self
        addLabeledControl(
            field,
            title: String(localized: "filter.field.text", defaultValue: "Text"),
            to: stack
        )
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field else { return }
            view.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    private func addTagCheckboxes(
        selected: Set<String>,
        action: Selector,
        to stack: NSStackView
    ) {
        if tags.isEmpty {
            let empty = NSTextField(
                labelWithString: String(localized: "filter.noTags", defaultValue: "No tags available")
            )
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
            return
        }
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.layer?.cornerRadius = 6
        scroll.layer?.masksToBounds = true
        let list = FlippedRuleEditorStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        for tag in tags {
            let checkbox = NSButton(
                checkboxWithTitle: tag.name,
                target: self,
                action: action
            )
            checkbox.identifier = NSUserInterfaceItemIdentifier(tag.id)
            checkbox.state = selected.contains(tag.id) ? .on : .off
            list.addArrangedSubview(checkbox)
        }
        let listHeight = ceil(list.fittingSize.height)
        let visibleHeight = min(
            Self.maximumTagListHeight,
            max(24, listHeight)
        )
        list.frame = NSRect(
            x: 6,
            y: 6,
            width: Self.fieldWidth - 18,
            height: max(visibleHeight - 12, listHeight)
        )
        list.autoresizingMask = [.width]
        scroll.documentView = list
        scroll.hasVerticalScroller = listHeight > visibleHeight - 12
        scroll.heightAnchor.constraint(equalToConstant: visibleHeight).isActive = true
        addLabeledControl(
            scroll,
            title: String(localized: "filter.field.tags", defaultValue: "Tags"),
            to: stack
        )
    }

    private func addMatchModeEditor(to stack: NSStackView) {
        let all = NSButton(
            radioButtonWithTitle: String(localized: "filter.matchAll", defaultValue: "Match All Conditions"),
            target: self,
            action: #selector(changeMatchMode(_:))
        )
        all.tag = 0
        all.state = rule.matchMode == .all ? .on : .off
        let any = NSButton(
            radioButtonWithTitle: String(localized: "filter.matchAny", defaultValue: "Match Any Condition"),
            target: self,
            action: #selector(changeMatchMode(_:))
        )
        any.tag = 1
        any.state = rule.matchMode == .any ? .on : .off
        stack.addArrangedSubview(all)
        stack.addArrangedSubview(any)
    }

    private func addConditionEditor(to stack: NSStackView) {
        guard let condition = editedCondition else { return }
        let typePopup = NSPopUpButton()
        let types: [(String, String)] = [
            ("tags", String(localized: "filter.type.tags", defaultValue: "Tags")),
            ("untagged", String(localized: "filter.type.untagged", defaultValue: "Untagged")),
            ("added", String(localized: "filter.type.added", defaultValue: "Date Added")),
            ("created", String(localized: "filter.type.created", defaultValue: "Date Created")),
            ("duration", String(localized: "filter.type.duration", defaultValue: "Duration")),
            ("fileSize", String(localized: "filter.type.fileSize", defaultValue: "File Size")),
            ("resolution", String(localized: "filter.type.resolution", defaultValue: "Resolution")),
        ]
        types.forEach { key, title in
            typePopup.addItem(withTitle: title)
            typePopup.lastItem?.representedObject = key
            if key == "tags", tags.isEmpty, conditionKind(condition) != "tags" {
                typePopup.lastItem?.isEnabled = false
            }
        }
        typePopup.selectItem(at: types.firstIndex { $0.0 == conditionKind(condition) } ?? 0)
        typePopup.target = self
        typePopup.action = #selector(changeConditionType(_:))
        addLabeledControl(
            typePopup,
            title: String(localized: "filter.field.condition", defaultValue: "Condition"),
            to: stack
        )

        switch condition {
        case let .tags(tagOperator, tagIDs):
            let operatorPopup = NSPopUpButton()
            let operators: [(LibraryTagConditionOperator, String)] = [
                (.all, String(localized: "filter.operator.all", defaultValue: "Include All")),
                (.any, String(localized: "filter.operator.any", defaultValue: "Include Any")),
                (.exclude, String(localized: "filter.operator.exclude", defaultValue: "Exclude")),
            ]
            operators.forEach { value, title in
                operatorPopup.addItem(withTitle: title)
                operatorPopup.lastItem?.representedObject = value.rawValue
            }
            operatorPopup.selectItem(at: operators.firstIndex { $0.0 == tagOperator } ?? 0)
            operatorPopup.target = self
            operatorPopup.action = #selector(changeTagOperator(_:))
            addLabeledControl(
                operatorPopup,
                title: String(localized: "filter.field.relationship", defaultValue: "Relationship"),
                to: stack
            )
            addTagCheckboxes(
                selected: Set(tagIDs),
                action: #selector(toggleConditionTag(_:)),
                to: stack
            )
        case .untagged:
            break
        case let .addedWithinDays(days):
            addLabeledControl(
                valuePopup(
                    values: [7, 30, 90].map { ($0, dayOptionTitle($0)) },
                    selected: days,
                    action: #selector(changeIntegerValue(_:))
                ),
                title: String(localized: "filter.field.range", defaultValue: "Range"),
                to: stack
            )
        case let .createdWithinDays(days):
            addLabeledControl(
                valuePopup(
                    values: [7, 30, 90].map { ($0, dayOptionTitle($0)) },
                    selected: days,
                    action: #selector(changeIntegerValue(_:))
                ),
                title: String(localized: "filter.field.range", defaultValue: "Range"),
                to: stack
            )
        case let .durationAtLeast(seconds):
            addLabeledControl(
                valuePopup(
                    values: [1, 2, 5].map { minutes in
                        (minutes * 60, minuteOptionTitle(minutes))
                    },
                    selected: Int(seconds),
                    action: #selector(changeIntegerValue(_:))
                ),
                title: String(localized: "filter.field.range", defaultValue: "Range"),
                to: stack
            )
        case let .fileSizeAtLeast(bytes):
            addLabeledControl(
                valuePopup(
                    values: [500_000_000, 1_000_000_000, 2_000_000_000].map {
                        ($0, ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))
                    },
                    selected: Int(bytes),
                    action: #selector(changeIntegerValue(_:))
                ),
                title: String(localized: "filter.field.range", defaultValue: "Range"),
                to: stack
            )
        case let .resolutionWidthAtLeast(width):
            addLabeledControl(
                valuePopup(
                    values: [(1920, "1080p"), (3840, "4K")],
                    selected: width,
                    action: #selector(changeIntegerValue(_:))
                ),
                title: String(localized: "filter.field.range", defaultValue: "Range"),
                to: stack
            )
        }
    }

    private func addSortEditor(to stack: NSStackView) {
        let keyPopup = NSPopUpButton()
        let keys: [(LibraryVideoSortKey, String)] = [
            (.filename, String(localized: "filter.sort.filename", defaultValue: "Filename")),
            (.added, String(localized: "filter.sort.added", defaultValue: "Date Added")),
            (.created, String(localized: "filter.sort.created", defaultValue: "Date Created")),
            (.modified, String(localized: "filter.sort.modified", defaultValue: "Date Modified")),
            (.duration, String(localized: "filter.sort.duration", defaultValue: "Duration")),
            (.fileSize, String(localized: "filter.sort.fileSize", defaultValue: "File Size")),
            (.resolution, String(localized: "filter.sort.resolution", defaultValue: "Resolution")),
        ]
        keys.forEach { key, title in
            keyPopup.addItem(withTitle: title)
            keyPopup.lastItem?.representedObject = key.rawValue
        }
        keyPopup.selectItem(at: keys.firstIndex { $0.0 == rule.sort.key } ?? 0)
        keyPopup.target = self
        keyPopup.action = #selector(changeSortKey(_:))
        addLabeledControl(
            keyPopup,
            title: String(localized: "filter.field.sortBy", defaultValue: "Sort By"),
            to: stack
        )

        let directionPopup = NSPopUpButton()
        let directions = sortDirectionOptions(for: rule.sort.key)
        directions.forEach { direction, title in
            directionPopup.addItem(withTitle: title)
            directionPopup.lastItem?.representedObject = direction.rawValue
        }
        directionPopup.selectItem(at: directions.firstIndex { $0.0 == rule.sort.direction } ?? 0)
        directionPopup.target = self
        directionPopup.action = #selector(changeSortDirection(_:))
        sortDirectionPopup = directionPopup
        addLabeledControl(
            directionPopup,
            title: String(localized: "filter.field.order", defaultValue: "Order"),
            to: stack
        )
    }

    private func addLabeledControl(
        _ control: NSView,
        title: String,
        to stack: NSStackView
    ) {
        let field = NSStackView()
        field.orientation = .vertical
        field.alignment = .leading
        field.spacing = 4
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabelColor
        field.addArrangedSubview(label)
        control.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        field.addArrangedSubview(control)
        field.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        stack.addArrangedSubview(field)
    }

    private func valuePopup(
        values: [(Int, String)],
        selected: Int,
        action: Selector
    ) -> NSPopUpButton {
        let popup = NSPopUpButton()
        values.forEach { value, title in
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
        popup.selectItem(at: values.firstIndex { $0.0 == selected } ?? 0)
        popup.target = self
        popup.action = action
        return popup
    }

    private func dayOptionTitle(_ days: Int) -> String {
        String(localized: "filter.days", defaultValue: "\(days) days")
    }

    private func minuteOptionTitle(_ minutes: Int) -> String {
        String(localized: "filter.minutes", defaultValue: "\(minutes) min")
    }

    private func conditionKind(_ condition: LibraryFilterCondition) -> String {
        switch condition {
        case .tags: "tags"
        case .untagged: "untagged"
        case .addedWithinDays: "added"
        case .createdWithinDays: "created"
        case .durationAtLeast: "duration"
        case .fileSizeAtLeast: "fileSize"
        case .resolutionWidthAtLeast: "resolution"
        }
    }

    private var editedConditionLocation: (required: Bool, index: Int)? {
        switch mode {
        case let .requiredCondition(index): (true, index)
        case let .condition(index): (false, index)
        case .filename, .requiredTags, .matchMode, .sort: nil
        }
    }

    private var editedCondition: LibraryFilterCondition? {
        guard let location = editedConditionLocation else { return nil }
        let conditions = location.required ? rule.requiredConditions : rule.conditions
        guard conditions.indices.contains(location.index) else { return nil }
        return conditions[location.index]
    }

    private func setEditedCondition(_ condition: LibraryFilterCondition) {
        guard let location = editedConditionLocation else { return }
        if location.required {
            guard rule.requiredConditions.indices.contains(location.index) else { return }
            rule.requiredConditions[location.index] = condition
        } else {
            guard rule.conditions.indices.contains(location.index) else { return }
            rule.conditions[location.index] = condition
        }
    }

    private func sortDirectionOptions(
        for key: LibraryVideoSortKey
    ) -> [(LibraryVideoSortDirection, String)] {
        if key == .filename {
            return [
                (.ascending, String(localized: "filter.sort.az", defaultValue: "A to Z")),
                (.descending, String(localized: "filter.sort.za", defaultValue: "Z to A")),
            ]
        }
        if [.added, .created, .modified].contains(key) {
            return [
                (.descending, String(localized: "filter.sort.newest", defaultValue: "Newest First")),
                (.ascending, String(localized: "filter.sort.oldest", defaultValue: "Oldest First")),
            ]
        }
        return [
            (.ascending, String(localized: "filter.sort.smallest", defaultValue: "Smallest First")),
            (.descending, String(localized: "filter.sort.largest", defaultValue: "Largest First")),
        ]
    }

    private func refreshSortDirectionPopup() {
        guard let sortDirectionPopup else { return }
        let directions = sortDirectionOptions(for: rule.sort.key)
        sortDirectionPopup.removeAllItems()
        directions.forEach { direction, title in
            sortDirectionPopup.addItem(withTitle: title)
            sortDirectionPopup.lastItem?.representedObject = direction.rawValue
        }
        sortDirectionPopup.selectItem(
            at: directions.firstIndex { $0.0 == rule.sort.direction } ?? 0
        )
    }

    private func draftDidChange(rebuild: Bool = false) {
        if rebuild {
            loadView()
        } else {
            updateDoneAvailability()
        }
    }

    private var draftValidationMessage: String? {
        switch mode {
        case let .filename(index):
            guard rule.filenameContains.indices.contains(index),
                  rule.filenameContains[index]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty == false else {
                return String(
                    localized: "filter.validation.enterText",
                    defaultValue: "Enter filename text before applying this filter."
                )
            }
        case .requiredTags:
            guard rule.requiredTagIDs.isEmpty == false else {
                return String(
                    localized: "filter.validation.selectTag",
                    defaultValue: "Select at least one tag."
                )
            }
        case .requiredCondition, .condition:
            if case let .tags(_, tagIDs) = editedCondition, tagIDs.isEmpty {
                return String(
                    localized: "filter.validation.selectTag",
                    defaultValue: "Select at least one tag."
                )
            }
        case .sort:
            if allowsDeletion == false, rule.sort == .standard {
                return String(
                    localized: "filter.validation.selectSort",
                    defaultValue: "Choose a non-default sort order."
                )
            }
        case .matchMode:
            break
        }
        if isDuplicate(rule) {
            return String(
                localized: "filter.validation.duplicate",
                defaultValue: "An identical filter condition already exists."
            )
        }
        return nil
    }

    private func updateDoneAvailability() {
        let message = draftValidationMessage
        doneButton?.isEnabled = message == nil
        validationLabel?.stringValue = message ?? ""
        validationLabel?.textColor = .secondaryLabelColor
        validationLabel?.isHidden = message == nil && reservesValidationSpace == false
        if isViewLoaded {
            let fittedHeight = ceil(view.fittingSize.height)
            preferredContentSize = NSSize(
                width: Self.popoverWidth,
                height: min(Self.maximumPopoverHeight, fittedHeight)
            )
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard case let .filename(index) = mode,
              rule.filenameContains.indices.contains(index),
              let field = notification.object as? NSTextField else { return }
        rule.filenameContains[index] = field.stringValue
        draftDidChange()
    }

    @objc private func toggleRequiredTag(_ sender: NSButton) {
        guard let tagID = sender.identifier?.rawValue else { return }
        var selected = Set(rule.requiredTagIDs)
        if sender.state == .on { selected.insert(tagID) } else { selected.remove(tagID) }
        rule.requiredTagIDs = tags.map(\.id).filter { selected.contains($0) }
        draftDidChange()
    }

    @objc private func changeMatchMode(_ sender: NSButton) {
        rule.matchMode = sender.tag == 0 ? .all : .any
        draftDidChange(rebuild: true)
    }

    @objc private func changeConditionType(_ sender: NSPopUpButton) {
        guard editedCondition != nil,
              let kind = sender.selectedItem?.representedObject as? String else { return }
        let condition: LibraryFilterCondition
        switch kind {
        case "tags":
            condition = .tags(operator: .all, tagIDs: [])
        case "untagged": condition = .untagged
        case "added": condition = .addedWithinDays(30)
        case "created": condition = .createdWithinDays(30)
        case "duration": condition = .durationAtLeast(60)
        case "fileSize": condition = .fileSizeAtLeast(1_000_000_000)
        case "resolution": condition = .resolutionWidthAtLeast(3840)
        default: return
        }
        setEditedCondition(condition)
        draftDidChange(rebuild: true)
    }

    @objc private func changeTagOperator(_ sender: NSPopUpButton) {
        guard case let .tags(_, tagIDs) = editedCondition,
              let rawValue = sender.selectedItem?.representedObject as? String,
              let tagOperator = LibraryTagConditionOperator(rawValue: rawValue) else { return }
        setEditedCondition(.tags(operator: tagOperator, tagIDs: tagIDs))
        draftDidChange()
    }

    @objc private func toggleConditionTag(_ sender: NSButton) {
        guard case let .tags(tagOperator, tagIDs) = editedCondition,
              let tagID = sender.identifier?.rawValue else { return }
        var selected = Set(tagIDs)
        if sender.state == .on {
            selected.insert(tagID)
        } else {
            selected.remove(tagID)
        }
        setEditedCondition(.tags(
            operator: tagOperator,
            tagIDs: tags.map(\.id).filter { selected.contains($0) }
        ))
        draftDidChange()
    }

    @objc private func changeIntegerValue(_ sender: NSPopUpButton) {
        guard let condition = editedCondition,
              let value = sender.selectedItem?.representedObject as? Int else { return }
        switch condition {
        case .addedWithinDays: setEditedCondition(.addedWithinDays(value))
        case .createdWithinDays: setEditedCondition(.createdWithinDays(value))
        case .durationAtLeast: setEditedCondition(.durationAtLeast(Double(value)))
        case .fileSizeAtLeast: setEditedCondition(.fileSizeAtLeast(Int64(value)))
        case .resolutionWidthAtLeast: setEditedCondition(.resolutionWidthAtLeast(value))
        case .tags, .untagged: return
        }
        draftDidChange()
    }

    @objc private func changeSortKey(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let key = LibraryVideoSortKey(rawValue: rawValue) else { return }
        let defaultDirection: LibraryVideoSortDirection = [.added, .created, .modified].contains(key)
            ? .descending
            : .ascending
        rule.sort = LibraryVideoSort(key: key, direction: defaultDirection)
        refreshSortDirectionPopup()
        draftDidChange()
    }

    @objc private func changeSortDirection(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let direction = LibraryVideoSortDirection(rawValue: rawValue) else { return }
        rule.sort = LibraryVideoSort(key: rule.sort.key, direction: direction)
        draftDidChange()
    }

    @objc private func deleteRule() {
        onDelete()
    }

    @objc private func cancelEditor() {
        onCancel?()
    }

    @objc private func commitEditor() {
        guard draftValidationMessage == nil else {
            updateDoneAvailability()
            return
        }
        guard onCommit(rule) else {
            doneButton?.isEnabled = false
            validationLabel?.stringValue = String(
                localized: "filter.validation.duplicate",
                defaultValue: "An identical filter condition already exists."
            )
            validationLabel?.textColor = .systemRed
            validationLabel?.isHidden = false
            return
        }
        onCancel?()
    }
}

@MainActor
private final class FlippedRuleEditorStackView: NSStackView {
    override var isFlipped: Bool { true }
}
