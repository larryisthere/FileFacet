import AppKit

@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    static let tagPasteboardType = NSPasteboard.PasteboardType("com.larryisthere.tagivy.tag-id")
    static let videoPasteboardType = NSPasteboard.PasteboardType("com.larryisthere.tagivy.video-ids")
    private static let tagSortModeDefaultsKey = "sidebar.tagSortMode"

    private let outlineView = NSOutlineView()
    private var tags: [TagRecord] = []
    private var smartCollections: [SmartCollectionRecord] = []
    private var filterCounts = SidebarFilterCounts.zero
    private var scanResultCount: Int?
    private var scanResultsCloseEnabled = true
    private var groups: [SidebarGroupNode] = []
    private var onFilterChanged: (LibraryFilter) -> Void
    private var onSmartCollectionSelected: (SmartCollectionRecord) -> Void
    private var onRenameSmartCollection: (SmartCollectionRecord, String) -> Void
    private var onDeleteSmartCollection: (SmartCollectionRecord) -> Void
    private var onScanResultsSelected: () -> Void
    private var onCloseScanResults: () -> Void
    private let onCreateTag: (String, String?) -> Void
    private let onRenameTag: (TagRecord, String) -> Void
    private let onDeleteTag: (TagRecord) -> Void
    private let onMoveTags: ([TagRecord], String?, Int) -> Void
    private let onSetColor: (TagRecord, String?) -> Void
    private let onMergeTag: (TagRecord, TagRecord) -> Void
    private let onAssignVideos: (TagRecord, [String]) -> Void
    private var isRestoringSelection = false
    private var tagGroupExpansionPreference = true
    private var pendingRootTagDraft: SidebarDraftTagNode?
    private var isResolvingRootTagDraft = false
    private var inlineRenameTarget: SidebarInlineRenameTarget?
    private var inlineRenameName: String?
    private var hasEditedInlineRenameName = false
    private var isResolvingInlineRename = false
    private var tagSortMode: TagSortMode
    private var showsPresetShortcutHints = false

    init(
        onFilterChanged: @escaping (LibraryFilter) -> Void,
        onSmartCollectionSelected: @escaping (SmartCollectionRecord) -> Void,
        onRenameSmartCollection: @escaping (SmartCollectionRecord, String) -> Void,
        onDeleteSmartCollection: @escaping (SmartCollectionRecord) -> Void,
        onScanResultsSelected: @escaping () -> Void,
        onCloseScanResults: @escaping () -> Void,
        onCreateTag: @escaping (String, String?) -> Void,
        onRenameTag: @escaping (TagRecord, String) -> Void,
        onDeleteTag: @escaping (TagRecord) -> Void,
        onMoveTags: @escaping ([TagRecord], String?, Int) -> Void,
        onSetColor: @escaping (TagRecord, String?) -> Void,
        onMergeTag: @escaping (TagRecord, TagRecord) -> Void,
        onAssignVideos: @escaping (TagRecord, [String]) -> Void
    ) {
        self.onFilterChanged = onFilterChanged
        self.onSmartCollectionSelected = onSmartCollectionSelected
        self.onRenameSmartCollection = onRenameSmartCollection
        self.onDeleteSmartCollection = onDeleteSmartCollection
        self.onScanResultsSelected = onScanResultsSelected
        self.onCloseScanResults = onCloseScanResults
        self.onCreateTag = onCreateTag
        self.onRenameTag = onRenameTag
        self.onDeleteTag = onDeleteTag
        self.onMoveTags = onMoveTags
        self.onSetColor = onSetColor
        self.onMergeTag = onMergeTag
        self.onAssignVideos = onAssignVideos
        tagSortMode = UserDefaults.standard.string(forKey: Self.tagSortModeDefaultsKey)
            .flatMap(TagSortMode.init(rawValue:)) ?? .custom
        super.init(nibName: nil, bundle: nil)
        rebuildNodes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let container = NSView()
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowHeight = 28
        outlineView.intercellSpacing = .zero
        outlineView.indentationPerLevel = 16
        outlineView.floatsGroupRows = false
        outlineView.backgroundColor = .clear
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(beginInlineRenameFromDoubleClick(_:))
        outlineView.allowsMultipleSelection = true
        outlineView.registerForDraggedTypes([Self.tagPasteboardType, Self.videoPasteboardType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        scrollView.documentView = outlineView

        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        restoreExpansionState()
        if outlineView.selectedRow < 0, outlineView.numberOfRows > 1 {
            outlineView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        }
    }

    func setTags(_ tags: [TagRecord]) {
        let selection = selectedItemKeys()
        self.tags = tags
        if case let .tag(tagID) = inlineRenameTarget,
           tags.contains(where: { $0.id == tagID }) == false {
            clearInlineRenameState()
        }
        rebuildNodes()
        loadViewIfNeeded()
        outlineView.reloadData()
        restoreExpansionState()
        restoreSelection(selection)
        refocusInlineRenameIfNeeded()
    }

    func setSmartCollections(_ collections: [SmartCollectionRecord]) {
        let selection = selectedItemKeys()
        smartCollections = collections
        if case let .smartCollection(collectionID) = inlineRenameTarget,
           collections.contains(where: { $0.id == collectionID }) == false {
            clearInlineRenameState()
        }
        rebuildNodes()
        loadViewIfNeeded()
        outlineView.reloadData()
        restoreExpansionState()
        restoreSelection(selection)
        refocusInlineRenameIfNeeded()
    }

    func setFilterCounts(_ counts: SidebarFilterCounts) {
        guard counts != filterCounts else { return }
        let selection = selectedItemKeys()
        filterCounts = counts
        rebuildNodes()
        loadViewIfNeeded()
        isRestoringSelection = true
        defer { isRestoringSelection = false }
        outlineView.reloadData()
        restoreExpansionState()
        restoreSelection(selection)
        refocusInlineRenameIfNeeded()
    }

    func setScanResultCount(_ count: Int?) {
        guard scanResultCount != count else { return }
        let selection = selectedItemKeys()
        scanResultCount = count
        rebuildNodes()
        loadViewIfNeeded()
        outlineView.reloadData()
        restoreExpansionState()
        restoreSelection(selection)
    }

    func selectScanResults() {
        loadViewIfNeeded()
        guard let row = (0..<outlineView.numberOfRows).first(where: { row in
            outlineView.item(atRow: row) is ScanResultsNode
        }) else { return }
        isRestoringSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isRestoringSelection = false
    }

    func setScanResultsCloseEnabled(_ enabled: Bool) {
        guard scanResultsCloseEnabled != enabled else { return }
        scanResultsCloseEnabled = enabled
        guard isViewLoaded,
              let group = groups.first(where: { $0.kind == .scanResults }) else { return }
        outlineView.reloadItem(group)
    }

    func setPresetShortcutHintsVisible(_ visible: Bool) {
        guard showsPresetShortcutHints != visible else { return }
        showsPresetShortcutHints = visible
        guard isViewLoaded else { return }
        for row in 0..<outlineView.numberOfRows {
            guard let filter = outlineView.item(atRow: row) as? SidebarFilterNode,
                  let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false)
                    as? SidebarCountRowView else { continue }
            let trailingText = trailingText(for: filter)
            rowView.configure(text: trailingText)
            let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? SidebarItemCellView
            cell?.configureTrailingLayout(text: trailingText, showsActionButton: false)
        }
    }

    func selectFilter(_ filter: LibraryFilter) {
        loadViewIfNeeded()
        guard let row = (0..<outlineView.numberOfRows).first(where: { row in
            (outlineView.item(atRow: row) as? SidebarFilterNode)?.filter == filter
        }) else { return }
        isRestoringSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isRestoringSelection = false
    }

    func selectSmartCollection(id: String) {
        loadViewIfNeeded()
        guard let row = (0..<outlineView.numberOfRows).first(where: { row in
            (outlineView.item(atRow: row) as? SmartCollectionNode)?.collection.id == id
        }) else { return }
        isRestoringSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isRestoringSelection = false
    }

    func setNavigationHandlers(
        filter: @escaping (LibraryFilter) -> Void,
        smartCollection: @escaping (SmartCollectionRecord) -> Void,
        renameSmartCollection: @escaping (SmartCollectionRecord, String) -> Void,
        deleteSmartCollection: @escaping (SmartCollectionRecord) -> Void,
        scanResults: @escaping () -> Void,
        closeScanResults: @escaping () -> Void
    ) {
        onFilterChanged = filter
        onSmartCollectionSelected = smartCollection
        onRenameSmartCollection = renameSmartCollection
        onDeleteSmartCollection = deleteSmartCollection
        onScanResultsSelected = scanResults
        onCloseScanResults = closeScanResults
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groups.count }
        if let group = item as? SidebarGroupNode {
            if group.kind == .tags, tagGroupExpansionPreference == false { return 0 }
            return group.children.count
        }
        if let tag = item as? TagNode { return tag.children.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? SidebarGroupNode { return group.children[index] }
        if let tag = item as? TagNode { return tag.children[index] }
        return groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarGroupNode || (item as? TagNode)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is SidebarGroupNode }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        guard let group = item as? SidebarGroupNode else { return true }
        return group.kind != .tags
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarFilterNode
            || item is SmartCollectionNode
            || item is TagNode
            || item is ScanResultsNode
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        shouldEdit tableColumn: NSTableColumn?,
        item: Any
    ) -> Bool {
        if item is SidebarDraftTagNode { return true }
        if let smartCollection = item as? SmartCollectionNode {
            return inlineRenameTarget == .smartCollection(smartCollection.collection.id)
        }
        if let tag = item as? TagNode { return inlineRenameTarget == .tag(tag.tag.id) }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = SidebarCountRowView()
        rowView.configure(text: trailingText(for: item))
        return rowView
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard isRestoringSelection == false else { return }
        let selectedItems = outlineView.selectedRowIndexes.map { outlineView.item(atRow: $0) }
        if selectedItems.contains(where: { $0 is ScanResultsNode }) {
            onScanResultsSelected()
            return
        }
        if let smartCollection = selectedItems.compactMap({ $0 as? SmartCollectionNode }).first {
            onSmartCollectionSelected(smartCollection.collection)
            return
        }
        let selectedTags = selectedItems.compactMap { ($0 as? TagNode)?.tag }
        if selectedTags.count == 1, let tag = selectedTags.first {
            onFilterChanged(.tag(tag.id))
            return
        }
        if selectedTags.count > 1 {
            onFilterChanged(.tags(selectedTags.map(\.id)))
            return
        }
        if let filter = selectedItems.compactMap({ $0 as? SidebarFilterNode }).first {
            onFilterChanged(filter.filter)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? SidebarGroupNode {
            if group.kind == .scanResults {
                let identifier = NSUserInterfaceItemIdentifier("SidebarScanGroupCell")
                let cell = outlineView.makeView(withIdentifier: identifier, owner: self)
                    as? SidebarScanGroupCellView
                    ?? makeScanGroupCell(identifier: identifier)
                cell.closeButton.target = self
                cell.closeButton.action = #selector(closeScanResults(_:))
                cell.closeButton.isEnabled = scanResultsCloseEnabled
                return cell
            }
            if group.kind == .tags {
                let identifier = NSUserInterfaceItemIdentifier("SidebarTagGroupCell")
                let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarTagGroupCellView
                    ?? makeTagGroupCell(identifier: identifier)
                cell.configure(expanded: tagGroupExpansionPreference)
                cell.toggleButton.target = self
                cell.toggleButton.action = #selector(toggleTagGroup(_:))
                cell.sortButton.target = self
                cell.sortButton.action = #selector(showTagSortMenu(_:))
                cell.sortButton.toolTip = String(localized: .tagSortTooltip(tagSortMode.title))
                cell.sortButton.setAccessibilityLabel(
                    String(localized: .tagSortVoiceover(tagSortMode.title))
                )
                cell.sortButton.contentTintColor = tagSortMode == .custom
                    ? .secondaryLabelColor
                    : .controlAccentColor
                cell.addButton.target = self
                cell.addButton.action = #selector(beginCreatingRootTagFromButton(_:))
                return cell
            }
            let identifier = NSUserInterfaceItemIdentifier("SidebarGroupCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? makeGroupCell(identifier: identifier)
            cell.textField?.stringValue = group.title
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("SidebarItemCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarItemCellView
            ?? makeItemCell(identifier: identifier)
        cell.textField?.font = .systemFont(ofSize: 13)
        cell.textField?.textColor = .labelColor
        cell.textField?.identifier = nil
        cell.textField?.placeholderString = nil
        cell.textField?.isEditable = false
        cell.textField?.isSelectable = false
        cell.textField?.isBordered = false
        cell.textField?.drawsBackground = false
        cell.textField?.backgroundColor = .clear
        cell.textField?.focusRingType = .none
        cell.textField?.target = nil
        cell.textField?.action = nil
        cell.textField?.delegate = nil
        cell.imageView?.isHidden = false
        cell.imageView?.imageAlignment = .alignCenter
        cell.imageView?.contentTintColor = .secondaryLabelColor
        cell.smartCollectionActionButton.isHidden = true
        cell.smartCollectionActionButton.identifier = nil
        cell.smartCollectionActionButton.target = nil
        cell.smartCollectionActionButton.action = nil
        cell.setAccessibilityHelp(nil)
        let showsActionButton: Bool
        if let smartCollection = item as? SmartCollectionNode {
            showsActionButton = inlineRenameTarget != .smartCollection(smartCollection.collection.id)
        } else {
            showsActionButton = false
        }
        cell.configureTrailingLayout(
            text: trailingText(for: item),
            showsActionButton: showsActionButton
        )

        if let scanResults = item as? ScanResultsNode {
            let title = String(
                localized: "scan.sidebar.pending",
                defaultValue: "Videos to Import"
            )
            cell.textField?.stringValue = title
            cell.imageView?.image = sidebarSymbol(
                named: "folder.badge.plus",
                description: title
            )
            cell.configureTrailingLayout(
                text: String(scanResults.videoCount),
                showsActionButton: false
            )
        } else if let filter = item as? SidebarFilterNode {
            cell.textField?.stringValue = filter.title
            cell.imageView?.image = sidebarSymbol(named: filter.systemImageName, description: filter.title)
            if let shortcutHint = filter.shortcutHint {
                cell.setAccessibilityHelp(String(
                    localized: "sidebar.presetShortcutHelp",
                    defaultValue: "Keyboard shortcut: \(shortcutHint)"
                ))
            }
        } else if let smartCollection = item as? SmartCollectionNode {
            let name = smartCollection.collection.name
            if inlineRenameTarget == .smartCollection(smartCollection.collection.id) {
                cell.textField?.identifier = SidebarInlineTextField.renameIdentifier
                cell.textField?.stringValue = inlineRenameName ?? name
                configureInlineRenameField(cell.textField, action: #selector(commitInlineRename(_:)))
            } else {
                cell.textField?.stringValue = name
            }
            cell.imageView?.image = sidebarSymbol(
                named: "line.3.horizontal.decrease.circle",
                description: name
            )
            if inlineRenameTarget != .smartCollection(smartCollection.collection.id) {
                cell.smartCollectionActionButton.isHidden = false
                cell.smartCollectionActionButton.identifier = NSUserInterfaceItemIdentifier(
                    smartCollection.collection.id
                )
                cell.smartCollectionActionButton.target = self
                cell.smartCollectionActionButton.action = #selector(showSmartCollectionActions(_:))
            }
        } else if let tag = item as? TagNode {
            let name = tag.tag.name
            if inlineRenameTarget == .tag(tag.tag.id) {
                cell.textField?.identifier = SidebarInlineTextField.renameIdentifier
                cell.textField?.stringValue = inlineRenameName ?? name
                configureInlineRenameField(cell.textField, action: #selector(commitInlineRename(_:)))
            } else {
                cell.textField?.stringValue = name
            }
            cell.imageView?.image = tagDotSymbol(description: name)
            cell.imageView?.imageAlignment = .alignRight
            cell.imageView?.contentTintColor = color(named: tag.tag.color) ?? .secondaryLabelColor
        } else if item is SidebarDraftTagNode {
            cell.textField?.identifier = SidebarInlineTextField.draftIdentifier
            cell.textField?.stringValue = ""
            cell.textField?.placeholderString = String(localized: .tagCreateTitle)
            cell.textField?.isEditable = true
            cell.textField?.isSelectable = true
            cell.textField?.isBordered = true
            cell.textField?.drawsBackground = true
            cell.textField?.backgroundColor = .controlBackgroundColor
            cell.textField?.focusRingType = .default
            cell.textField?.target = self
            cell.textField?.action = #selector(commitRootTagDraft(_:))
            cell.textField?.delegate = self
            cell.imageView?.image = tagDotSymbol(description: String(localized: .tagCreateTitle))
            cell.imageView?.imageAlignment = .alignRight
            cell.imageView?.contentTintColor = .controlAccentColor
        } else if let placeholder = item as? SidebarPlaceholderNode {
            cell.textField?.stringValue = placeholder.title
            cell.textField?.textColor = .tertiaryLabelColor
            cell.imageView?.isHidden = true
        }
        return cell
    }

    private func trailingText(for item: Any) -> String? {
        if let scanResults = item as? ScanResultsNode {
            return String(scanResults.videoCount)
        }
        if let filter = item as? SidebarFilterNode {
            if showsPresetShortcutHints, let shortcutHint = filter.shortcutHint {
                return shortcutHint
            }
            return String(filter.videoCount)
        }
        if let smartCollection = item as? SmartCollectionNode {
            return smartCollection.collection.videoCount.map(String.init)
        }
        if let tag = item as? TagNode {
            return String(tag.tag.videoCount)
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let tag = item as? TagNode else { return nil }
        let draggedTags: [TagRecord]
        if let row = row(for: .tag(tag.tag.id)), outlineView.selectedRowIndexes.contains(row) {
            draggedTags = topLevelTags(
                from: outlineView.selectedRowIndexes.compactMap { selectedRow in
                    (outlineView.item(atRow: selectedRow) as? TagNode)?.tag
                }
            )
        } else {
            draggedTags = [tag.tag]
        }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(draggedTags.map(\.id).joined(separator: "\n"), forType: Self.tagPasteboardType)
        return pasteboardItem
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if info.draggingPasteboard.availableType(from: [Self.videoPasteboardType]) != nil,
           item is TagNode,
           index == NSOutlineViewDropOnItemIndex {
            return .copy
        }
        if let rawTagIDs = info.draggingPasteboard.string(forType: Self.tagPasteboardType),
           item is TagNode || (item as? SidebarGroupNode)?.kind == .tags {
            let tagIDs = Set(rawTagIDs.split(separator: "\n").map(String.init))
            let parentID = (item as? TagNode)?.tag.id
            if canMoveTags(tagIDs, toParentID: parentID),
               canDropTagsInCurrentSortMode(tagIDs, toParentID: parentID) {
                return .move
            }
        }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if let target = item as? TagNode,
           index == NSOutlineViewDropOnItemIndex,
           let rawVideoIDs = info.draggingPasteboard.string(forType: Self.videoPasteboardType) {
            onAssignVideos(target.tag, rawVideoIDs.split(separator: "\n").map(String.init))
            return true
        }
        guard let rawTagIDs = info.draggingPasteboard.string(forType: Self.tagPasteboardType) else { return false }
        let tagIDs = Set(rawTagIDs.split(separator: "\n").map(String.init))
        let parentID = (item as? TagNode)?.tag.id
        guard canMoveTags(tagIDs, toParentID: parentID),
              canDropTagsInCurrentSortMode(tagIDs, toParentID: parentID) else { return false }
        let dragOrder = tagSortMode == .custom
            ? tagsInOutlineOrder()
            : tags.sorted { TagSortMode.custom.orders($0, before: $1) }
        let draggedTags = topLevelTags(from: dragOrder.filter { tagIDs.contains($0.id) })
        guard draggedTags.isEmpty == false else { return false }
        let sortOrder = tagSortMode == .custom
            ? max(0, index)
            : tags.filter { $0.parentID == parentID && tagIDs.contains($0.id) == false }.count
        onMoveTags(draggedTags, parentID, sortOrder)
        return true
    }

    private func tagsInOutlineOrder() -> [TagRecord] {
        (0..<outlineView.numberOfRows).compactMap { row in
            (outlineView.item(atRow: row) as? TagNode)?.tag
        }
    }

    private func topLevelTags(from candidates: [TagRecord]) -> [TagRecord] {
        let candidateIDs = Set(candidates.map(\.id))
        let tagsByID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        return candidates.filter { tag in
            var ancestorID = tag.parentID
            while let currentID = ancestorID {
                if candidateIDs.contains(currentID) { return false }
                ancestorID = tagsByID[currentID]?.parentID
            }
            return true
        }
    }

    private func canMoveTags(_ tagIDs: Set<String>, toParentID parentID: String?) -> Bool {
        guard tagIDs.isEmpty == false else { return false }
        let tagsByID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        guard tagIDs.allSatisfy({ tagsByID[$0] != nil }) else { return false }
        var ancestorID = parentID
        while let currentID = ancestorID {
            if tagIDs.contains(currentID) { return false }
            ancestorID = tagsByID[currentID]?.parentID
        }
        return true
    }

    private func configureInlineRenameField(_ field: NSTextField?, action: Selector) {
        field?.isEditable = true
        field?.isSelectable = true
        field?.isBordered = true
        field?.drawsBackground = true
        field?.backgroundColor = .controlBackgroundColor
        field?.focusRingType = .default
        field?.target = self
        field?.action = action
        field?.delegate = self
    }

    private func canDropTagsInCurrentSortMode(_ tagIDs: Set<String>, toParentID parentID: String?) -> Bool {
        guard tagSortMode != .custom else { return true }
        let tagsByID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        return tagIDs.allSatisfy { tagsByID[$0]?.parentID != parentID }
    }

    @objc private func beginInlineRenameFromDoubleClick(_ sender: NSOutlineView) {
        guard sender.clickedRow >= 0 else { return }
        if let collection = (sender.item(atRow: sender.clickedRow) as? SmartCollectionNode)?.collection {
            beginRenamingSmartCollection(collection)
        } else if let tag = (sender.item(atRow: sender.clickedRow) as? TagNode)?.tag {
            beginRenamingTag(tag)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let smartCollection = clickedSmartCollection() {
            let renameItem = NSMenuItem(
                title: String(localized: "smartCollection.rename.action", defaultValue: "Rename"),
                action: #selector(renameSmartCollection(_:)),
                keyEquivalent: ""
            )
            renameItem.target = self
            renameItem.representedObject = smartCollection
            let deleteItem = NSMenuItem(
                title: String(localized: "smartCollection.delete.action", defaultValue: "Delete"),
                action: #selector(deleteSmartCollection(_:)),
                keyEquivalent: ""
            )
            deleteItem.target = self
            deleteItem.representedObject = smartCollection
            menu.addItem(renameItem)
            menu.addItem(.separator())
            menu.addItem(deleteItem)
            return
        }
        guard let tag = clickedTag() else {
            guard canCreateRootTagFromContextMenu else { return }
            let item = NSMenuItem(
                title: String(localized: .tagActionCreateMenu),
                action: #selector(createRootTag),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            return
        }
        let createChildItem = NSMenuItem(
            title: String(localized: .tagActionCreateChild),
            action: #selector(createTag),
            keyEquivalent: ""
        )
        let renameItem = NSMenuItem(
            title: String(localized: .tagActionRenameMenu),
            action: #selector(renameTag(_:)),
            keyEquivalent: ""
        )
        renameItem.representedObject = TagActionContext(tag: tag)
        let deleteItem = NSMenuItem(
            title: String(localized: .tagActionDeleteMenu),
            action: #selector(deleteTag),
            keyEquivalent: ""
        )
        for item in [createChildItem, renameItem, deleteItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let colorMenu = NSMenu()
        let colorOptions = [
            (String(localized: .colorNone), ""),
            (String(localized: .colorRed), "red"),
            (String(localized: .colorOrange), "orange"),
            (String(localized: .colorYellow), "yellow"),
            (String(localized: .colorGreen), "green"),
            (String(localized: .colorBlue), "blue"),
            (String(localized: .colorPurple), "purple"),
        ]
        for (title, value) in colorOptions {
            let item = NSMenuItem(title: title, action: #selector(setColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = TagActionContext(tag: tag, value: value)
            colorMenu.addItem(item)
        }
        let colorItem = NSMenuItem(title: String(localized: .tagActionColor), action: nil, keyEquivalent: "")
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)
        let mergeMenu = NSMenu()
        for target in tags where target.id != tag.id {
            let item = NSMenuItem(title: target.name, action: #selector(mergeTag(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = TagActionContext(tag: tag, target: target)
            mergeMenu.addItem(item)
        }
        let mergeItem = NSMenuItem(
            title: String(localized: .tagActionMergeInto),
            action: nil,
            keyEquivalent: ""
        )
        mergeItem.submenu = mergeMenu
        mergeItem.isEnabled = mergeMenu.items.isEmpty == false
        menu.addItem(mergeItem)
    }

    private func rebuildNodes() {
        let libraryChildren: [SidebarFilterNode] = [
            SidebarFilterNode(
                title: String(localized: .libraryAllVideos),
                systemImageName: "film",
                filter: .all,
                videoCount: filterCounts.all
            ),
            SidebarFilterNode(
                title: String(localized: .libraryRecent),
                systemImageName: "clock",
                filter: .recent,
                videoCount: filterCounts.recent
            ),
            SidebarFilterNode(
                title: String(localized: .libraryUntagged),
                systemImageName: "tag.slash",
                filter: .untagged,
                videoCount: filterCounts.untagged
            ),
            SidebarFilterNode(
                title: String(
                    localized: "library.unavailable",
                    defaultValue: "Unavailable Videos"
                ),
                systemImageName: "externaldrive.badge.xmark",
                filter: .unavailable,
                videoCount: filterCounts.unavailable
            )
        ].filter { node in
            switch node.filter {
            case .untagged, .unavailable: node.videoCount > 0
            default: true
            }
        }
        let library = SidebarGroupNode(
            kind: .library,
            title: String(localized: .libraryGroup),
            children: libraryChildren
        )
        let nodes = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, TagNode(tag: $0)) })
        var roots: [TagNode] = []
        for tag in tags {
            guard let node = nodes[tag.id] else { continue }
            if let parentID = tag.parentID, let parent = nodes[parentID] { parent.children.append(node) }
            else { roots.append(node) }
        }
        sortTagNodes(&roots)
        var tagChildren: [Any] = roots
        if let pendingRootTagDraft { tagChildren.insert(pendingRootTagDraft, at: 0) }
        if tagChildren.isEmpty {
            tagChildren = [SidebarPlaceholderNode(title: String(localized: .sidebarNoTags))]
        }
        groups = []
        if let scanResultCount {
            groups.append(SidebarGroupNode(
                kind: .scanResults,
                title: String(
                    localized: "scan.sidebar.group",
                    defaultValue: "Scan Results"
                ),
                children: [ScanResultsNode(videoCount: scanResultCount)]
            ))
        }
        groups.append(library)
        if smartCollections.isEmpty == false {
            groups.append(SidebarGroupNode(
                kind: .smartCollections,
                title: String(
                    localized: "smartCollection.group",
                    defaultValue: "Smart Collections"
                ),
                children: smartCollections.map(SmartCollectionNode.init)
            ))
        }
        groups.append(
            SidebarGroupNode(kind: .tags, title: String(localized: .sidebarTags), children: tagChildren)
        )
    }

    private func sortTagNodes(_ nodes: inout [TagNode]) {
        nodes.sort { tagSortMode.orders($0.tag, before: $1.tag) }
        for node in nodes { sortTagNodes(&node.children) }
    }

    private func restoreExpansionState() {
        for group in groups {
            if group.kind != .tags || tagGroupExpansionPreference {
                outlineView.expandItem(group, expandChildren: true)
            }
            updateTagGroupCell(for: group)
        }
    }

    var canBeginCreatingRootTag: Bool {
        pendingRootTagDraft == nil
    }

    func beginCreatingRootTag() {
        guard resolveActiveInlineRenameIfNeeded() else {
            focusInlineRename(selectAll: true)
            return
        }
        guard canBeginCreatingRootTag else {
            focusRootTagDraft()
            return
        }
        let selection = selectedItemKeys()
        pendingRootTagDraft = SidebarDraftTagNode()
        tagGroupExpansionPreference = true
        rebuildNodes()
        loadViewIfNeeded()
        outlineView.reloadData()
        restoreExpansionState()
        restoreSelection(selection)
        DispatchQueue.main.async { [weak self] in self?.focusRootTagDraft() }
    }

    private func focusRootTagDraft() {
        guard pendingRootTagDraft != nil else { return }
        for row in 0..<outlineView.numberOfRows where outlineView.item(atRow: row) is SidebarDraftTagNode {
            outlineView.editColumn(0, row: row, with: nil, select: true)
            return
        }
    }

    @objc private func toggleTagGroup(_ sender: Any?) {
        guard let currentTagGroup = displayedTagGroup else { return }
        if tagGroupExpansionPreference, pendingRootTagDraft != nil {
            view.window?.makeFirstResponder(outlineView)
        }
        tagGroupExpansionPreference.toggle()
        outlineView.reloadItem(currentTagGroup, reloadChildren: true)
        if tagGroupExpansionPreference {
            outlineView.expandItem(currentTagGroup, expandChildren: true)
        }
        updateTagGroupCell(for: currentTagGroup)
    }

    private var displayedTagGroup: SidebarGroupNode? {
        for row in 0..<outlineView.numberOfRows {
            guard let group = outlineView.item(atRow: row) as? SidebarGroupNode else { continue }
            if group.kind == .tags { return group }
        }
        return nil
    }

    private func updateTagGroupCell(for group: SidebarGroupNode) {
        let row = outlineView.row(forItem: group)
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? SidebarTagGroupCellView else { return }
        cell.configure(expanded: tagGroupExpansionPreference)
    }

    @objc private func beginCreatingRootTagFromButton(_ sender: Any?) {
        beginCreatingRootTag()
    }

    @objc private func showTagSortMenu(_ sender: NSButton) {
        let menu = NSMenu(title: String(localized: .tagSortMenu))
        for mode in TagSortMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectTagSortMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == tagSortMode ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: menu.items.first(where: { $0.state == .on }), at: .zero, in: sender)
    }

    @objc private func selectTagSortMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = TagSortMode(rawValue: rawValue),
              mode != tagSortMode else { return }
        let selection = selectedItemKeys()
        let expandedTagIDs = currentExpandedTagIDs()
        tagSortMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.tagSortModeDefaultsKey)
        rebuildNodes()
        outlineView.reloadData()
        restoreExpansionState(expandedTagIDs: expandedTagIDs)
        restoreSelection(selection)
    }

    private func currentExpandedTagIDs() -> Set<String> {
        Set((0..<outlineView.numberOfRows).compactMap { row in
            guard let node = outlineView.item(atRow: row) as? TagNode,
                  outlineView.isItemExpanded(node) else { return nil }
            return node.tag.id
        })
    }

    private func restoreExpansionState(expandedTagIDs: Set<String>) {
        for group in groups {
            if group.kind != .tags || tagGroupExpansionPreference {
                outlineView.expandItem(group)
            }
            restoreExpansionState(in: group.children, expandedTagIDs: expandedTagIDs)
            updateTagGroupCell(for: group)
        }
    }

    private func restoreExpansionState(in items: [Any], expandedTagIDs: Set<String>) {
        for case let node as TagNode in items {
            if expandedTagIDs.contains(node.tag.id) { outlineView.expandItem(node) }
            restoreExpansionState(in: node.children, expandedTagIDs: expandedTagIDs)
        }
    }

    @objc private func commitRootTagDraft(_ sender: NSTextField) {
        resolveRootTagDraft(name: sender.stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        switch field.identifier {
        case SidebarInlineTextField.draftIdentifier:
            resolveRootTagDraft(name: field.stringValue)
        case SidebarInlineTextField.renameIdentifier:
            resolveInlineRename(name: field.stringValue, endEditing: false)
        default:
            break
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        guard field.identifier == SidebarInlineTextField.renameIdentifier else { return }
        inlineRenameName = field.stringValue
        hasEditedInlineRenameName = true
        field.toolTip = nil
        field.textColor = .labelColor
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
              let field = control as? NSTextField else { return false }
        switch field.identifier {
        case SidebarInlineTextField.draftIdentifier:
            cancelRootTagDraft()
        case SidebarInlineTextField.renameIdentifier:
            cancelInlineRename()
        default:
            return false
        }
        return true
    }

    private func cancelRootTagDraft() {
        resolveRootTagDraft(name: nil)
    }

    private func resolveRootTagDraft(name: String?) {
        guard pendingRootTagDraft != nil, isResolvingRootTagDraft == false else { return }
        isResolvingRootTagDraft = true
        view.window?.makeFirstResponder(outlineView)
        let selection = selectedItemKeys()
        pendingRootTagDraft = nil
        rebuildNodes()
        outlineView.reloadData()
        restoreExpansionState()
        restoreSelection(selection)
        isResolvingRootTagDraft = false

        guard let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              cleanName.isEmpty == false else { return }
        onCreateTag(cleanName, nil)
    }

    private func beginRenamingSmartCollection(_ collection: SmartCollectionRecord) {
        beginInlineRename(.smartCollection(collection.id), currentName: collection.name)
    }

    private func beginRenamingTag(_ tag: TagRecord) {
        tagGroupExpansionPreference = true
        restoreExpansionState()
        beginInlineRename(.tag(tag.id), currentName: tag.name)
    }

    private func beginInlineRename(_ target: SidebarInlineRenameTarget, currentName: String) {
        if pendingRootTagDraft != nil { cancelRootTagDraft() }
        if inlineRenameTarget == target {
            focusInlineRename(selectAll: true)
            return
        }
        guard resolveActiveInlineRenameIfNeeded() else {
            focusInlineRename(selectAll: true)
            return
        }

        inlineRenameTarget = target
        inlineRenameName = currentName
        hasEditedInlineRenameName = false
        if let row = row(for: target) {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.reloadItem(outlineView.item(atRow: row), reloadChildren: false)
        }
        DispatchQueue.main.async { [weak self] in
            self?.focusInlineRename(selectAll: true)
        }
    }

    @objc private func commitInlineRename(_ sender: NSTextField) {
        resolveInlineRename(name: sender.stringValue, endEditing: true)
    }

    private func resolveInlineRename(name: String, endEditing: Bool) {
        guard let target = inlineRenameTarget, isResolvingInlineRename == false else { return }
        isResolvingInlineRename = true
        inlineRenameName = name
        if endEditing { view.window?.makeFirstResponder(outlineView) }

        guard hasEditedInlineRenameName else {
            finishInlineRename(target)
            return
        }

        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanName.isEmpty == false else {
            keepInlineRenameActive(message: emptyNameMessage(for: target))
            return
        }

        switch target {
        case let .smartCollection(collectionID):
            guard let collection = smartCollections.first(where: { $0.id == collectionID }) else {
                finishInlineRename(target)
                return
            }
            let normalizedName = normalizedSmartCollectionName(cleanName)
            let hasDuplicateName = smartCollections.contains { candidate in
                candidate.id != collection.id
                    && normalizedSmartCollectionName(candidate.name) == normalizedName
            }
            guard hasDuplicateName == false else {
                keepInlineRenameActive(message: String(
                    localized: "smartCollection.name.duplicate",
                    defaultValue: "A smart collection with this name already exists."
                ))
                return
            }
            finishInlineRename(target)
            if cleanName != collection.name { onRenameSmartCollection(collection, cleanName) }

        case let .tag(tagID):
            guard let tag = tags.first(where: { $0.id == tagID }) else {
                finishInlineRename(target)
                return
            }
            let hasSiblingWithSameName = tags.contains { candidate in
                candidate.id != tag.id
                    && candidate.parentID == tag.parentID
                    && candidate.name.compare(
                        cleanName,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) == .orderedSame
            }
            guard hasSiblingWithSameName == false else {
                keepInlineRenameActive(message: String(localized: .tagValidationDuplicate))
                return
            }
            finishInlineRename(target)
            if cleanName != tag.name { onRenameTag(tag, cleanName) }
        }
    }

    private func emptyNameMessage(for target: SidebarInlineRenameTarget) -> String {
        switch target {
        case .smartCollection:
            String(localized: "smartCollection.name.empty", defaultValue: "Enter a name.")
        case .tag:
            String(localized: .tagValidationEmpty)
        }
    }

    private func keepInlineRenameActive(message: String) {
        NSSound.beep()
        isResolvingInlineRename = false
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let field = self.inlineRenameField() else { return }
            field.toolTip = message
            field.textColor = .systemRed
            self.view.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    private func cancelInlineRename() {
        guard let target = inlineRenameTarget, isResolvingInlineRename == false else { return }
        isResolvingInlineRename = true
        view.window?.makeFirstResponder(outlineView)
        finishInlineRename(target)
    }

    private func resolveActiveInlineRenameIfNeeded() -> Bool {
        guard inlineRenameTarget != nil else { return true }
        guard let field = inlineRenameField() else {
            cancelInlineRename()
            return true
        }
        resolveInlineRename(name: field.stringValue, endEditing: true)
        return inlineRenameTarget == nil
    }

    private func finishInlineRename(_ target: SidebarInlineRenameTarget) {
        clearInlineRenameState()
        if let row = row(for: target) {
            outlineView.reloadItem(outlineView.item(atRow: row), reloadChildren: false)
        }
    }

    private func clearInlineRenameState() {
        inlineRenameTarget = nil
        inlineRenameName = nil
        hasEditedInlineRenameName = false
        isResolvingInlineRename = false
    }

    private func refocusInlineRenameIfNeeded() {
        guard inlineRenameTarget != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.focusInlineRename(selectAll: false) }
    }

    private func focusInlineRename(selectAll: Bool) {
        guard let inlineRenameTarget,
              let row = row(for: inlineRenameTarget) else { return }
        outlineView.editColumn(0, row: row, with: nil, select: selectAll)
    }

    private func inlineRenameField() -> NSTextField? {
        guard let inlineRenameTarget,
              let row = row(for: inlineRenameTarget),
              let cell = outlineView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: true
              ) as? SidebarItemCellView else { return nil }
        return cell.textField
    }

    private func row(for target: SidebarInlineRenameTarget) -> Int? {
        (0..<outlineView.numberOfRows).first { row in
            switch target {
            case let .smartCollection(collectionID):
                (outlineView.item(atRow: row) as? SmartCollectionNode)?.collection.id == collectionID
            case let .tag(tagID):
                (outlineView.item(atRow: row) as? TagNode)?.tag.id == tagID
            }
        }
    }

    private func selectedItemKeys() -> Set<SidebarSelectionKey> {
        guard isViewLoaded else { return [] }
        return Set(outlineView.selectedRowIndexes.compactMap { row in
            selectionKey(for: outlineView.item(atRow: row))
        })
    }
    private func restoreSelection(_ selection: Set<SidebarSelectionKey>) {
        guard selection.isEmpty == false else { return }
        let rows = IndexSet((0..<outlineView.numberOfRows).filter { row in
            guard let key = selectionKey(for: outlineView.item(atRow: row)) else { return false }
            return selection.contains(key)
        })
        guard rows.isEmpty == false else { return }
        isRestoringSelection = true
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        isRestoringSelection = false
    }
    private func selectionKey(for item: Any?) -> SidebarSelectionKey? {
        if item is ScanResultsNode { return .scanResults }
        if let smartCollection = item as? SmartCollectionNode {
            return .smartCollection(smartCollection.collection.id)
        }
        if let tag = item as? TagNode {
            return .tag(tag.tag.id)
        }
        guard let filter = item as? SidebarFilterNode else { return nil }
        return switch filter.filter {
        case .all: .all
        case .untagged: .untagged
        case .recent: .recent
        case .unavailable: .unavailable
        case .tag, .tags: nil
        }
    }
    private func selectedTag() -> TagRecord? {
        guard outlineView.selectedRow >= 0 else { return nil }
        return (outlineView.item(atRow: outlineView.selectedRow) as? TagNode)?.tag
    }
    private func clickedTag() -> TagRecord? {
        guard outlineView.clickedRow >= 0 else { return nil }
        return (outlineView.item(atRow: outlineView.clickedRow) as? TagNode)?.tag
    }
    private func clickedSmartCollection() -> SmartCollectionRecord? {
        guard outlineView.clickedRow >= 0 else { return nil }
        return (outlineView.item(atRow: outlineView.clickedRow) as? SmartCollectionNode)?.collection
    }
    private var canCreateRootTagFromContextMenu: Bool {
        guard outlineView.clickedRow >= 0 else { return true }
        if let group = outlineView.item(atRow: outlineView.clickedRow) as? SidebarGroupNode {
            return group.kind == .tags
        }
        return outlineView.item(atRow: outlineView.clickedRow) is SidebarPlaceholderNode
    }

    @objc private func createTag() {
        let parent = clickedTag() ?? selectedTag()
        let title = parent == nil
            ? String(localized: .tagCreateTitle)
            : String(localized: .tagCreateChildTitle)
        if let name = prompt(title: title, value: "") {
            onCreateTag(name, parent?.id)
        }
    }
    @objc private func createRootTag() {
        beginCreatingRootTag()
    }
    @objc private func renameSmartCollection(_ sender: NSMenuItem) {
        guard let collection = sender.representedObject as? SmartCollectionRecord else { return }
        beginRenamingSmartCollection(collection)
    }
    @objc private func showSmartCollectionActions(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let collection = smartCollections.first(where: { $0.id == id }) else { return }
        let menu = NSMenu()
        let rename = NSMenuItem(
            title: String(localized: "smartCollection.rename.action", defaultValue: "Rename"),
            action: #selector(renameSmartCollection(_:)),
            keyEquivalent: ""
        )
        rename.target = self
        rename.representedObject = collection
        menu.addItem(rename)
        let delete = NSMenuItem(
            title: String(localized: "smartCollection.delete.action", defaultValue: "Delete"),
            action: #selector(deleteSmartCollection(_:)),
            keyEquivalent: ""
        )
        delete.target = self
        delete.representedObject = collection
        menu.addItem(delete)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.height + 4),
            in: sender
        )
    }
    @objc private func deleteSmartCollection(_ sender: NSMenuItem) {
        guard let collection = sender.representedObject as? SmartCollectionRecord else { return }
        onDeleteSmartCollection(collection)
    }
    @objc private func renameTag(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? TagActionContext else { return }
        let tagID = context.tag.id
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let tag = self.tags.first(where: { $0.id == tagID }) else { return }
            self.beginRenamingTag(tag)
        }
    }
    @objc private func deleteTag() {
        guard let tag = clickedTag() ?? selectedTag() else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: .tagDeleteTitle(tag.name))
        alert.informativeText = String(localized: .tagDeleteDetail)
        alert.addButton(withTitle: String(localized: .tagActionDelete))
        alert.addButton(withTitle: String(localized: .actionCancel))
        if alert.runModal() == .alertFirstButtonReturn { onDeleteTag(tag) }
    }
    @objc private func setColor(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? TagActionContext else { return }
        onSetColor(context.tag, context.value?.isEmpty == true ? nil : context.value)
    }
    @objc private func mergeTag(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? TagActionContext, let target = context.target else { return }
        onMergeTag(context.tag, target)
    }

    private func prompt(title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: .actionSave))
        alert.addButton(withTitle: String(localized: .actionCancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let result = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func color(named name: String?) -> NSColor? {
        switch name { case "red": .systemRed; case "orange": .systemOrange; case "yellow": .systemYellow; case "green": .systemGreen; case "blue": .systemBlue; case "purple": .systemPurple; default: nil }
    }

    private func sidebarSymbol(named name: String, description: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
    }

    private func tagDotSymbol(description: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
    }

    private func makeGroupCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView(); cell.identifier = identifier
        let textField = NSTextField(labelWithString: ""); textField.translatesAutoresizingMaskIntoConstraints = false; textField.lineBreakMode = .byTruncatingTail
        cell.addSubview(textField); cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeScanGroupCell(
        identifier: NSUserInterfaceItemIdentifier
    ) -> SidebarScanGroupCellView {
        let cell = SidebarScanGroupCellView()
        cell.identifier = identifier
        return cell
    }

    @objc private func closeScanResults(_ sender: Any?) {
        onCloseScanResults()
    }

    private func makeTagGroupCell(identifier: NSUserInterfaceItemIdentifier) -> SidebarTagGroupCellView {
        let cell = SidebarTagGroupCellView()
        cell.identifier = identifier
        return cell
    }

    private func makeItemCell(identifier: NSUserInterfaceItemIdentifier) -> SidebarItemCellView {
        let cell = SidebarItemCellView(); cell.identifier = identifier
        let imageView = NSImageView(); imageView.translatesAutoresizingMaskIntoConstraints = false; imageView.imageScaling = .scaleProportionallyDown
        let textField = SidebarInlineTextField(); textField.translatesAutoresizingMaskIntoConstraints = false; textField.lineBreakMode = .byTruncatingTail
        textField.isEditable = false; textField.isSelectable = false; textField.isBordered = false; textField.drawsBackground = false
        cell.addSubview(imageView); cell.addSubview(textField); cell.addSubview(cell.smartCollectionActionButton)
        cell.imageView = imageView; cell.textField = textField
        let actionButtonTrailingConstraint = cell.smartCollectionActionButton.trailingAnchor.constraint(
            equalTo: cell.trailingAnchor,
            constant: -SidebarTagGroupCellView.trailingInset
        )
        let actionButtonWidthConstraint = cell.smartCollectionActionButton.widthAnchor.constraint(equalToConstant: 0)
        cell.actionButtonTrailingConstraint = actionButtonTrailingConstraint
        cell.actionButtonWidthConstraint = actionButtonWidthConstraint
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: -6),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            textField.trailingAnchor.constraint(
                lessThanOrEqualTo: cell.smartCollectionActionButton.leadingAnchor,
                constant: -4
            ),
            actionButtonTrailingConstraint,
            cell.smartCollectionActionButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            actionButtonWidthConstraint,
            cell.smartCollectionActionButton.heightAnchor.constraint(equalToConstant: 22),
        ])
        return cell
    }
}

private enum SidebarSelectionKey: Hashable {
    case scanResults
    case all
    case untagged
    case recent
    case unavailable
    case smartCollection(String)
    case tag(String)
}

private enum SidebarInlineRenameTarget: Equatable {
    case smartCollection(String)
    case tag(String)
}

private final class SidebarItemCellView: NSTableCellView {
    fileprivate var actionButtonTrailingConstraint: NSLayoutConstraint?
    fileprivate var actionButtonWidthConstraint: NSLayoutConstraint?

    let smartCollectionActionButton: NSButton = {
        let description = String(
            localized: "smartCollection.actions",
            defaultValue: "Smart collection actions"
        )
        let image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: description
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = description
        button.setAccessibilityLabel(description)
        button.isHidden = true
        return button
    }()

    func configureTrailingLayout(text: String?, showsActionButton: Bool) {
        actionButtonTrailingConstraint?.constant = -(
            SidebarCountRowView.trailingInset(for: text) + SidebarCountRowView.width(for: text)
        )
        actionButtonWidthConstraint?.constant = showsActionButton ? 22 : 0
    }
}

private final class SidebarCountRowView: NSTableRowView {
    private static let selectedBackgroundClearance: CGFloat = 7

    private let countLabel = NSTextField(labelWithString: "")
    private var countLabelWidth: CGFloat = 0

    override var isSelected: Bool {
        didSet { updateTextColor() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.alignment = .right
        addSubview(countLabel)
        updateTextColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        countLabel.frame = NSRect(
            x: bounds.maxX - Self.trailingInset(for: countLabel.stringValue) - countLabelWidth,
            y: floor((bounds.height - 16) / 2),
            width: countLabelWidth,
            height: 16
        )
    }

    func configure(text: String?) {
        countLabel.stringValue = text ?? ""
        countLabel.isHidden = text == nil
        countLabelWidth = Self.width(for: text)
        needsLayout = true
    }

    static func width(for text: String?) -> CGFloat {
        guard let text, text.isEmpty == false else { return 0 }
        let measurementField = NSTextField(labelWithString: text)
        measurementField.font = .systemFont(ofSize: 11)
        return ceil(measurementField.fittingSize.width) + 1
    }

    static func trailingInset(for text: String?) -> CGFloat {
        guard let text, text.isEmpty == false else {
            return SidebarTagGroupCellView.trailingInset
        }
        return SidebarTagGroupCellView.trailingInset + selectedBackgroundClearance
    }

    private func updateTextColor() {
        countLabel.textColor = isSelected ? .selectedControlTextColor : .secondaryLabelColor
    }
}

private final class SidebarScanGroupCellView: NSTableCellView {
    let closeButton: NSButton = {
        let title = String(
            localized: "scan.sidebar.close",
            defaultValue: "Close Scan Results"
        )
        let image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: title
        )?.withSymbolConfiguration(.init(pointSize: 9, weight: .medium)) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let titleLabel = NSTextField(labelWithString: String(
            localized: "scan.sidebar.group",
            defaultValue: "Scan Results"
        ))
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        addSubview(titleLabel)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor,
                constant: -4
            ),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class SidebarTagGroupCellView: NSTableCellView {
    static let trailingColumnWidth: CGFloat = 28
    static let trailingInset: CGFloat = 9

    let toggleButton: NSButton = {
        let button = NSButton(title: String(localized: .sidebarTags), target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.contentTintColor = .secondaryLabelColor
        button.imagePosition = .imageTrailing
        button.imageHugsTitle = true
        button.focusRingType = .none
        button.setAccessibilityLabel(String(localized: .accessibilityTagToggle))
        return button
    }()

    let addButton: NSButton = {
        let image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: String(localized: .tagActionCreate)
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = String(localized: .tagActionCreate)
        button.setAccessibilityLabel(String(localized: .tagActionCreate))
        return button
    }()

    let sortButton: NSButton = {
        let image = NSImage(
            systemSymbolName: "line.3.horizontal.decrease",
            accessibilityDescription: String(localized: .tagActionSort)
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(toggleButton)
        addSubview(sortButton)
        addSubview(addButton)
        NSLayoutConstraint.activate([
            toggleButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            toggleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleButton.trailingAnchor.constraint(equalTo: sortButton.leadingAnchor, constant: -4),
            sortButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            sortButton.widthAnchor.constraint(equalToConstant: Self.trailingColumnWidth),
            sortButton.heightAnchor.constraint(equalToConstant: 22),
            sortButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor),
            addButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Self.trailingInset
            ),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: Self.trailingColumnWidth),
            addButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(expanded: Bool) {
        let symbolName = expanded ? "chevron.down" : "chevron.right"
        toggleButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: expanded
                ? String(localized: .accessibilityTagCollapse)
                : String(localized: .accessibilityTagExpand)
        )?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        toggleButton.setAccessibilityLabel(
            expanded
                ? String(localized: .accessibilityTagCollapse)
                : String(localized: .accessibilityTagExpand)
        )
    }
}

private final class SidebarInlineTextField: NSTextField {
    static let draftIdentifier = NSUserInterfaceItemIdentifier("SidebarRootTagDraftField")
    static let renameIdentifier = NSUserInterfaceItemIdentifier("SidebarInlineRenameField")
}

private final class TagActionContext: NSObject {
    let tag: TagRecord
    let value: String?
    let target: TagRecord?
    init(tag: TagRecord, value: String? = nil, target: TagRecord? = nil) { self.tag = tag; self.value = value; self.target = target }
}
