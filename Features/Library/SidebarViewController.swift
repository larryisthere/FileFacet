import AppKit

@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    static let tagPasteboardType = NSPasteboard.PasteboardType("com.larryisthere.video-tag-manager.tag-id")
    static let videoPasteboardType = NSPasteboard.PasteboardType("com.larryisthere.video-tag-manager.video-ids")

    private let outlineView = NSOutlineView()
    private var tags: [TagRecord] = []
    private var filterCounts = SidebarFilterCounts.zero
    private var groups: [SidebarGroupNode] = []
    private let onFilterChanged: (LibraryFilter) -> Void
    private var onSelectionTitleChanged: (String, TagRecord?) -> Void
    private let onCreateTag: (String, String?) -> Void
    private let onRenameTag: (TagRecord, String) -> Void
    private let onDeleteTag: (TagRecord) -> Void
    private let onMoveTag: (TagRecord, String?, Int) -> Void
    private let onSetColor: (TagRecord, String?) -> Void
    private let onMergeTag: (TagRecord, TagRecord) -> Void
    private let onAssignVideos: (TagRecord, [String]) -> Void
    private var isRestoringSelection = false
    private var isTagGroupExpanded = true
    private var pendingRootTagDraft: SidebarDraftTagNode?
    private var isResolvingRootTagDraft = false
    private var editingTagID: String?
    private var editingTagName: String?
    private var hasEditedTagName = false
    private var isResolvingTagRename = false

    init(
        onFilterChanged: @escaping (LibraryFilter) -> Void,
        onSelectionTitleChanged: @escaping (String, TagRecord?) -> Void,
        onCreateTag: @escaping (String, String?) -> Void,
        onRenameTag: @escaping (TagRecord, String) -> Void,
        onDeleteTag: @escaping (TagRecord) -> Void,
        onMoveTag: @escaping (TagRecord, String?, Int) -> Void,
        onSetColor: @escaping (TagRecord, String?) -> Void,
        onMergeTag: @escaping (TagRecord, TagRecord) -> Void,
        onAssignVideos: @escaping (TagRecord, [String]) -> Void
    ) {
        self.onFilterChanged = onFilterChanged
        self.onSelectionTitleChanged = onSelectionTitleChanged
        self.onCreateTag = onCreateTag
        self.onRenameTag = onRenameTag
        self.onDeleteTag = onDeleteTag
        self.onMoveTag = onMoveTag
        self.onSetColor = onSetColor
        self.onMergeTag = onMergeTag
        self.onAssignVideos = onAssignVideos
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
        if let editingTagID, tags.contains(where: { $0.id == editingTagID }) == false {
            self.editingTagID = nil
            editingTagName = nil
        }
        rebuildNodes()
        loadViewIfNeeded()
        outlineView.reloadData()
        restoreExpansionState()
        restoreSelection(selection)
        refocusTagRenameIfNeeded()
    }

    func setFilterCounts(_ counts: SidebarFilterCounts) {
        guard counts != filterCounts else { return }
        let selection = selectedItemKeys()
        filterCounts = counts
        rebuildNodes()
        loadViewIfNeeded()
        outlineView.reloadData()
        restoreExpansionState()
        restoreSelection(selection)
        refocusTagRenameIfNeeded()
    }

    func setSelectionTitleHandler(_ handler: @escaping (String, TagRecord?) -> Void) {
        onSelectionTitleChanged = handler
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groups.count }
        if let group = item as? SidebarGroupNode { return group.children.count }
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
        return group.title != "标签"
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarFilterNode || item is TagNode
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        shouldEdit tableColumn: NSTableColumn?,
        item: Any
    ) -> Bool {
        if item is SidebarDraftTagNode { return true }
        guard let tag = item as? TagNode else { return false }
        return tag.tag.id == editingTagID
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = SidebarCountRowView()
        if let filter = item as? SidebarFilterNode {
            rowView.configure(count: filter.videoCount)
        } else if let tag = item as? TagNode {
            rowView.configure(count: tag.tag.videoCount)
        } else {
            rowView.configure(count: nil)
        }
        return rowView
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard isRestoringSelection == false else { return }
        let selectedItems = outlineView.selectedRowIndexes.map { outlineView.item(atRow: $0) }
        let selectedTags = selectedItems.compactMap { ($0 as? TagNode)?.tag }
        if selectedTags.count == 1, let tag = selectedTags.first {
            onSelectionTitleChanged(tag.name, tag)
            onFilterChanged(.tag(tag.id))
            return
        }
        if selectedTags.count > 1 {
            onSelectionTitleChanged("已选 \(selectedTags.count) 个标签", nil)
            onFilterChanged(.tags(selectedTags.map(\.id)))
            return
        }
        if let filter = selectedItems.compactMap({ $0 as? SidebarFilterNode }).first {
            onSelectionTitleChanged(filter.title, nil)
            onFilterChanged(filter.filter)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? SidebarGroupNode {
            if group.title == "标签" {
                let identifier = NSUserInterfaceItemIdentifier("SidebarTagGroupCell")
                let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarTagGroupCellView
                    ?? makeTagGroupCell(identifier: identifier)
                cell.configure(expanded: isTagGroupExpanded)
                cell.toggleButton.target = self
                cell.toggleButton.action = #selector(toggleTagGroup(_:))
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
        (cell.textField as? SidebarInlineTagTextField)?.onCancel = nil
        cell.imageView?.isHidden = false
        cell.imageView?.imageAlignment = .alignCenter
        cell.imageView?.contentTintColor = .secondaryLabelColor

        if let filter = item as? SidebarFilterNode {
            cell.textField?.stringValue = filter.title
            cell.imageView?.image = sidebarSymbol(named: filter.systemImageName, description: filter.title)
        } else if let tag = item as? TagNode {
            let name = tag.tag.name
            if tag.tag.id == editingTagID {
                cell.textField?.identifier = SidebarInlineTagTextField.renameIdentifier
                cell.textField?.stringValue = editingTagName ?? name
                cell.textField?.isEditable = true
                cell.textField?.isSelectable = true
                cell.textField?.isBordered = true
                cell.textField?.drawsBackground = true
                cell.textField?.backgroundColor = .controlBackgroundColor
                cell.textField?.focusRingType = .default
                cell.textField?.target = self
                cell.textField?.action = #selector(commitTagRename(_:))
                cell.textField?.delegate = self
                (cell.textField as? SidebarInlineTagTextField)?.onCancel = { [weak self] in
                    self?.cancelTagRename()
                }
            } else {
                cell.textField?.stringValue = name
            }
            cell.imageView?.image = tagDotSymbol(description: name)
            cell.imageView?.imageAlignment = .alignRight
            cell.imageView?.contentTintColor = color(named: tag.tag.color) ?? .secondaryLabelColor
        } else if item is SidebarDraftTagNode {
            cell.textField?.identifier = SidebarInlineTagTextField.draftIdentifier
            cell.textField?.stringValue = ""
            cell.textField?.placeholderString = "新标签"
            cell.textField?.isEditable = true
            cell.textField?.isSelectable = true
            cell.textField?.isBordered = true
            cell.textField?.drawsBackground = true
            cell.textField?.backgroundColor = .controlBackgroundColor
            cell.textField?.focusRingType = .default
            cell.textField?.target = self
            cell.textField?.action = #selector(commitRootTagDraft(_:))
            cell.textField?.delegate = self
            (cell.textField as? SidebarInlineTagTextField)?.onCancel = { [weak self] in
                self?.cancelRootTagDraft()
            }
            cell.imageView?.image = tagDotSymbol(description: "新标签")
            cell.imageView?.imageAlignment = .alignRight
            cell.imageView?.contentTintColor = .controlAccentColor
        } else if let placeholder = item as? SidebarPlaceholderNode {
            cell.textField?.stringValue = placeholder.title
            cell.textField?.textColor = .tertiaryLabelColor
            cell.imageView?.isHidden = true
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let tag = item as? TagNode else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(tag.tag.id, forType: Self.tagPasteboardType)
        return pasteboardItem
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if info.draggingPasteboard.availableType(from: [Self.videoPasteboardType]) != nil,
           item is TagNode,
           index == NSOutlineViewDropOnItemIndex {
            return .copy
        }
        if info.draggingPasteboard.availableType(from: [Self.tagPasteboardType]) != nil,
           item is TagNode || (item as? SidebarGroupNode)?.title == "标签" { return .move }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if let target = item as? TagNode,
           index == NSOutlineViewDropOnItemIndex,
           let rawVideoIDs = info.draggingPasteboard.string(forType: Self.videoPasteboardType) {
            onAssignVideos(target.tag, rawVideoIDs.split(separator: "\n").map(String.init))
            return true
        }
        guard let tagID = info.draggingPasteboard.string(forType: Self.tagPasteboardType),
              let tag = tags.first(where: { $0.id == tagID }) else { return false }
        let parentID = (item as? TagNode)?.tag.id
        onMoveTag(tag, parentID, max(0, index))
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tag = clickedTag() else {
            guard canCreateRootTagFromContextMenu else { return }
            let item = NSMenuItem(title: "新建标签…", action: #selector(createRootTag), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return
        }
        let createChildItem = NSMenuItem(
            title: "新建子标签…",
            action: #selector(createTag),
            keyEquivalent: ""
        )
        let renameItem = NSMenuItem(
            title: "重命名…",
            action: #selector(renameTag(_:)),
            keyEquivalent: ""
        )
        renameItem.representedObject = TagActionContext(tag: tag)
        let deleteItem = NSMenuItem(
            title: "删除…",
            action: #selector(deleteTag),
            keyEquivalent: ""
        )
        for item in [createChildItem, renameItem, deleteItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let colorMenu = NSMenu()
        for (title, value) in [("无", ""), ("红", "red"), ("橙", "orange"), ("黄", "yellow"), ("绿", "green"), ("蓝", "blue"), ("紫", "purple")] {
            let item = NSMenuItem(title: title, action: #selector(setColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = TagActionContext(tag: tag, value: value)
            colorMenu.addItem(item)
        }
        let colorItem = NSMenuItem(title: "颜色", action: nil, keyEquivalent: "")
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)
        let mergeMenu = NSMenu()
        for target in tags where target.id != tag.id {
            let item = NSMenuItem(title: target.name, action: #selector(mergeTag(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = TagActionContext(tag: tag, target: target)
            mergeMenu.addItem(item)
        }
        let mergeItem = NSMenuItem(title: "合并到", action: nil, keyEquivalent: "")
        mergeItem.submenu = mergeMenu
        mergeItem.isEnabled = mergeMenu.items.isEmpty == false
        menu.addItem(mergeItem)
    }

    private func rebuildNodes() {
        let library = SidebarGroupNode(title: "资料库", children: [
            SidebarFilterNode(
                title: "全部视频",
                systemImageName: "film",
                filter: .all,
                videoCount: filterCounts.all
            ),
            SidebarFilterNode(
                title: "最近添加",
                systemImageName: "clock",
                filter: .recent,
                videoCount: filterCounts.recent
            ),
            SidebarFilterNode(
                title: "未打标签",
                systemImageName: "tag.slash",
                filter: .untagged,
                videoCount: filterCounts.untagged
            ),
        ])
        let nodes = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, TagNode(tag: $0)) })
        var roots: [TagNode] = []
        for tag in tags {
            guard let node = nodes[tag.id] else { continue }
            if let parentID = tag.parentID, let parent = nodes[parentID] { parent.children.append(node) }
            else { roots.append(node) }
        }
        var tagChildren: [Any] = roots
        if let pendingRootTagDraft { tagChildren.insert(pendingRootTagDraft, at: 0) }
        if tagChildren.isEmpty { tagChildren = [SidebarPlaceholderNode(title: "尚无标签")] }
        groups = [library, SidebarGroupNode(title: "标签", children: tagChildren)]
    }

    private var tagGroup: SidebarGroupNode? {
        groups.first { $0.title == "标签" }
    }

    private func restoreExpansionState() {
        for group in groups {
            if group.title == "标签", isTagGroupExpanded == false {
                outlineView.collapseItem(group, collapseChildren: true)
            } else {
                outlineView.expandItem(group, expandChildren: true)
            }
        }
    }

    var canBeginCreatingRootTag: Bool {
        pendingRootTagDraft == nil
    }

    func beginCreatingRootTag() {
        guard resolveActiveTagRenameIfNeeded() else {
            focusTagRename(selectAll: true)
            return
        }
        guard canBeginCreatingRootTag else {
            focusRootTagDraft()
            return
        }
        let selection = selectedItemKeys()
        pendingRootTagDraft = SidebarDraftTagNode()
        isTagGroupExpanded = true
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
        if isTagGroupExpanded {
            if pendingRootTagDraft != nil { view.window?.makeFirstResponder(outlineView) }
            isTagGroupExpanded = false
            guard let currentTagGroup = tagGroup else { return }
            outlineView.collapseItem(currentTagGroup, collapseChildren: true)
            outlineView.reloadItem(currentTagGroup, reloadChildren: false)
        } else {
            isTagGroupExpanded = true
            guard let currentTagGroup = tagGroup else { return }
            outlineView.expandItem(currentTagGroup, expandChildren: true)
            outlineView.reloadItem(currentTagGroup, reloadChildren: false)
        }
    }

    @objc private func beginCreatingRootTagFromButton(_ sender: Any?) {
        beginCreatingRootTag()
    }

    @objc private func commitRootTagDraft(_ sender: NSTextField) {
        resolveRootTagDraft(name: sender.stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        switch field.identifier {
        case SidebarInlineTagTextField.draftIdentifier:
            resolveRootTagDraft(name: field.stringValue)
        case SidebarInlineTagTextField.renameIdentifier:
            resolveTagRename(name: field.stringValue)
        default:
            break
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field.identifier == SidebarInlineTagTextField.renameIdentifier else { return }
        editingTagName = field.stringValue
        hasEditedTagName = true
        field.toolTip = nil
        field.textColor = .labelColor
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

    private func beginRenamingTag(_ tag: TagRecord) {
        if pendingRootTagDraft != nil { cancelRootTagDraft() }
        if editingTagID == tag.id {
            focusTagRename(selectAll: true)
            return
        }
        guard resolveActiveTagRenameIfNeeded() else {
            focusTagRename(selectAll: true)
            return
        }

        editingTagID = tag.id
        editingTagName = tag.name
        hasEditedTagName = false
        isTagGroupExpanded = true
        restoreExpansionState()

        if let row = rowForTag(id: tag.id) {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.reloadItem(outlineView.item(atRow: row), reloadChildren: false)
        }
        DispatchQueue.main.async { [weak self] in
            self?.focusTagRename(selectAll: true)
        }
    }

    @objc private func commitTagRename(_ sender: NSTextField) {
        resolveTagRename(name: sender.stringValue)
    }

    private func resolveTagRename(name: String) {
        guard let tagID = editingTagID, isResolvingTagRename == false else { return }
        isResolvingTagRename = true
        editingTagName = name
        view.window?.makeFirstResponder(outlineView)

        guard let tag = tags.first(where: { $0.id == tagID }) else {
            finishTagRename(reloadTagID: tagID)
            return
        }
        guard hasEditedTagName else {
            finishTagRename(reloadTagID: tagID)
            return
        }

        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanName.isEmpty == false else {
            keepTagRenameActive(message: "标签名称不能为空")
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
            keepTagRenameActive(message: "同一级中已有同名标签")
            return
        }

        finishTagRename(reloadTagID: tagID)
        if cleanName != tag.name { onRenameTag(tag, cleanName) }
    }

    private func keepTagRenameActive(message: String) {
        NSSound.beep()
        isResolvingTagRename = false
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let field = self.tagRenameField() else { return }
            field.toolTip = message
            field.textColor = .systemRed
            self.view.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    private func cancelTagRename() {
        guard let tagID = editingTagID, isResolvingTagRename == false else { return }
        isResolvingTagRename = true
        view.window?.makeFirstResponder(outlineView)
        finishTagRename(reloadTagID: tagID)
    }

    private func resolveActiveTagRenameIfNeeded() -> Bool {
        guard editingTagID != nil else { return true }
        guard let field = tagRenameField() else {
            cancelTagRename()
            return true
        }
        resolveTagRename(name: field.stringValue)
        return editingTagID == nil
    }

    private func finishTagRename(reloadTagID tagID: String) {
        editingTagID = nil
        editingTagName = nil
        hasEditedTagName = false
        if let row = rowForTag(id: tagID) {
            outlineView.reloadItem(outlineView.item(atRow: row), reloadChildren: false)
        }
        isResolvingTagRename = false
    }

    private func refocusTagRenameIfNeeded() {
        guard editingTagID != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.focusTagRename(selectAll: false)
        }
    }

    private func focusTagRename(selectAll: Bool) {
        guard let editingTagID,
              let row = rowForTag(id: editingTagID) else { return }
        outlineView.editColumn(0, row: row, with: nil, select: selectAll)
    }

    private func tagRenameField() -> NSTextField? {
        guard let editingTagID,
              let row = rowForTag(id: editingTagID),
              let cell = outlineView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: true
              ) as? SidebarItemCellView else { return nil }
        return cell.textField
    }

    private func rowForTag(id: String) -> Int? {
        (0..<outlineView.numberOfRows).first { row in
            (outlineView.item(atRow: row) as? TagNode)?.tag.id == id
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
        if let tag = item as? TagNode {
            return .tag(tag.tag.id)
        }
        guard let filter = item as? SidebarFilterNode else { return nil }
        return switch filter.filter {
        case .all: .all
        case .untagged: .untagged
        case .recent: .recent
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
    private var canCreateRootTagFromContextMenu: Bool {
        guard outlineView.clickedRow >= 0 else { return true }
        if let group = outlineView.item(atRow: outlineView.clickedRow) as? SidebarGroupNode {
            return group.title == "标签"
        }
        return outlineView.item(atRow: outlineView.clickedRow) is SidebarPlaceholderNode
    }

    @objc private func createTag() {
        let parent = clickedTag() ?? selectedTag()
        if let name = prompt(title: parent == nil ? "新建标签" : "新建子标签", value: "") {
            onCreateTag(name, parent?.id)
        }
    }
    @objc private func createRootTag() {
        beginCreatingRootTag()
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
        alert.messageText = "删除“\(tag.name)”及其全部子标签？"
        alert.informativeText = "视频文件不会被删除，相关标签关系会被移除。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
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
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
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

    private func makeTagGroupCell(identifier: NSUserInterfaceItemIdentifier) -> SidebarTagGroupCellView {
        let cell = SidebarTagGroupCellView()
        cell.identifier = identifier
        return cell
    }

    private func makeItemCell(identifier: NSUserInterfaceItemIdentifier) -> SidebarItemCellView {
        let cell = SidebarItemCellView(); cell.identifier = identifier
        let imageView = NSImageView(); imageView.translatesAutoresizingMaskIntoConstraints = false; imageView.imageScaling = .scaleProportionallyDown
        let textField = SidebarInlineTagTextField(); textField.translatesAutoresizingMaskIntoConstraints = false; textField.lineBreakMode = .byTruncatingTail
        textField.isEditable = false; textField.isSelectable = false; textField.isBordered = false; textField.drawsBackground = false
        cell.addSubview(imageView); cell.addSubview(textField)
        cell.imageView = imageView; cell.textField = textField
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: -6),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -50),
        ])
        return cell
    }
}

private enum SidebarSelectionKey: Hashable {
    case all
    case untagged
    case recent
    case tag(String)
}

private final class SidebarItemCellView: NSTableCellView {}

private final class SidebarCountRowView: NSTableRowView {
    private let countLabel = NSTextField(labelWithString: "")

    override var isSelected: Bool {
        didSet { updateTextColor() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.alignment = .center
        addSubview(countLabel)
        updateTextColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = SidebarTagGroupCellView.trailingColumnWidth
        countLabel.frame = NSRect(
            x: bounds.maxX - SidebarTagGroupCellView.trailingInset - width,
            y: floor((bounds.height - 16) / 2),
            width: width,
            height: 16
        )
    }

    func configure(count: Int?) {
        countLabel.stringValue = count.map(String.init) ?? ""
        countLabel.isHidden = count == nil
    }

    private func updateTextColor() {
        countLabel.textColor = isSelected ? .selectedControlTextColor : .secondaryLabelColor
    }
}

private final class SidebarTagGroupCellView: NSTableCellView {
    static let trailingColumnWidth: CGFloat = 26
    static let trailingInset: CGFloat = 9

    let toggleButton: NSButton = {
        let button = NSButton(title: "标签", target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.contentTintColor = .secondaryLabelColor
        button.imagePosition = .imageTrailing
        button.imageHugsTitle = true
        button.focusRingType = .none
        button.setAccessibilityLabel("展开或收起标签")
        return button
    }()

    let addButton: NSButton = {
        let image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "新建标签"
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "新建标签"
        button.setAccessibilityLabel("新建标签")
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(toggleButton)
        addSubview(addButton)
        NSLayoutConstraint.activate([
            toggleButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            toggleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -4),
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
            accessibilityDescription: expanded ? "收起标签" : "展开标签"
        )?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        toggleButton.setAccessibilityLabel(expanded ? "收起标签" : "展开标签")
    }
}

private final class SidebarInlineTagTextField: NSTextField {
    static let draftIdentifier = NSUserInterfaceItemIdentifier("SidebarRootTagDraftField")
    static let renameIdentifier = NSUserInterfaceItemIdentifier("SidebarTagRenameField")
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

private final class TagActionContext: NSObject {
    let tag: TagRecord
    let value: String?
    let target: TagRecord?
    init(tag: TagRecord, value: String? = nil, target: TagRecord? = nil) { self.tag = tag; self.value = value; self.target = target }
}
