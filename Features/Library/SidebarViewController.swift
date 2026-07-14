import AppKit

@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    static let tagPasteboardType = NSPasteboard.PasteboardType("com.larryisthere.video-tag-manager.tag-id")
    static let videoPasteboardType = NSPasteboard.PasteboardType("com.larryisthere.video-tag-manager.video-ids")

    private let outlineView = NSOutlineView()
    private var tags: [TagRecord] = []
    private var groups: [SidebarGroupNode] = []
    private let onFilterChanged: (LibraryFilter) -> Void
    private let onCreateTag: (String, String?) -> Void
    private let onRenameTag: (TagRecord, String) -> Void
    private let onDeleteTag: (TagRecord) -> Void
    private let onMoveTag: (TagRecord, String?, Int) -> Void
    private let onSetColor: (TagRecord, String?) -> Void
    private let onMergeTag: (TagRecord, TagRecord) -> Void
    private let onAssignVideos: (TagRecord, [String]) -> Void

    init(
        onFilterChanged: @escaping (LibraryFilter) -> Void,
        onCreateTag: @escaping (String, String?) -> Void,
        onRenameTag: @escaping (TagRecord, String) -> Void,
        onDeleteTag: @escaping (TagRecord) -> Void,
        onMoveTag: @escaping (TagRecord, String?, Int) -> Void,
        onSetColor: @escaping (TagRecord, String?) -> Void,
        onMergeTag: @escaping (TagRecord, TagRecord) -> Void,
        onAssignVideos: @escaping (TagRecord, [String]) -> Void
    ) {
        self.onFilterChanged = onFilterChanged
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
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.registerForDraggedTypes([Self.tagPasteboardType, Self.videoPasteboardType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        scrollView.documentView = outlineView

        let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "新建标签") ?? NSImage(), target: self, action: #selector(createTag))
        addButton.isBordered = false
        let renameButton = NSButton(image: NSImage(systemSymbolName: "pencil", accessibilityDescription: "重命名标签") ?? NSImage(), target: self, action: #selector(renameTag))
        renameButton.isBordered = false
        let deleteButton = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "删除标签") ?? NSImage(), target: self, action: #selector(deleteTag))
        deleteButton.isBordered = false
        let footer = NSStackView(views: [addButton, renameButton, deleteButton, NSView()])
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .horizontal
        footer.spacing = 4
        footer.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 6, right: 8)
        container.addSubview(scrollView)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        expandAll()
        if outlineView.selectedRow < 0, outlineView.numberOfRows > 1 {
            outlineView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        }
    }

    func setTags(_ tags: [TagRecord]) {
        self.tags = tags
        rebuildNodes()
        loadViewIfNeeded()
        outlineView.reloadData()
        expandAll()
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

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarFilterNode || item is TagNode
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard outlineView.selectedRow >= 0 else { return }
        let item = outlineView.item(atRow: outlineView.selectedRow)
        if let filter = item as? SidebarFilterNode { onFilterChanged(filter.filter) }
        if let tag = item as? TagNode { onFilterChanged(.tag(tag.tag.id)) }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeCell(identifier: identifier)
        if let group = item as? SidebarGroupNode {
            cell.textField?.stringValue = group.title
            cell.imageView?.image = nil
        } else if let filter = item as? SidebarFilterNode {
            cell.textField?.stringValue = filter.title
            cell.imageView?.image = NSImage(systemSymbolName: filter.systemImageName, accessibilityDescription: filter.title)
        } else if let tag = item as? TagNode {
            cell.textField?.stringValue = "\(tag.tag.name)  \(tag.tag.videoCount)"
            cell.imageView?.image = NSImage(systemSymbolName: "tag.fill", accessibilityDescription: tag.tag.name)
            cell.imageView?.contentTintColor = color(named: tag.tag.color) ?? .secondaryLabelColor
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
        if info.draggingPasteboard.availableType(from: [Self.videoPasteboardType]) != nil, item is TagNode { return .copy }
        if info.draggingPasteboard.availableType(from: [Self.tagPasteboardType]) != nil,
           item is TagNode || (item as? SidebarGroupNode)?.title == "标签" { return .move }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if let target = item as? TagNode,
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
        guard let tag = clickedTag() else { return }
        for item in [
            NSMenuItem(title: "新建子标签…", action: #selector(createTag), keyEquivalent: ""),
            NSMenuItem(title: "重命名…", action: #selector(renameTag), keyEquivalent: ""),
            NSMenuItem(title: "删除…", action: #selector(deleteTag), keyEquivalent: ""),
        ] {
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
            SidebarFilterNode(title: "全部视频", systemImageName: "film", filter: .all),
            SidebarFilterNode(title: "未打标签", systemImageName: "tag.slash", filter: .untagged),
            SidebarFilterNode(title: "最近新增", systemImageName: "clock", filter: .recent),
            SidebarFilterNode(title: "无法访问", systemImageName: "exclamationmark.triangle", filter: .missing),
        ])
        let nodes = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, TagNode(tag: $0)) })
        var roots: [TagNode] = []
        for tag in tags {
            guard let node = nodes[tag.id] else { continue }
            if let parentID = tag.parentID, let parent = nodes[parentID] { parent.children.append(node) }
            else { roots.append(node) }
        }
        groups = [library, SidebarGroupNode(title: "标签", children: roots)]
    }

    private func expandAll() { groups.forEach { outlineView.expandItem($0, expandChildren: true) } }
    private func selectedTag() -> TagRecord? {
        guard outlineView.selectedRow >= 0 else { return nil }
        return (outlineView.item(atRow: outlineView.selectedRow) as? TagNode)?.tag
    }
    private func clickedTag() -> TagRecord? {
        guard outlineView.clickedRow >= 0 else { return selectedTag() }
        return (outlineView.item(atRow: outlineView.clickedRow) as? TagNode)?.tag
    }

    @objc private func createTag() {
        let parent = clickedTag() ?? selectedTag()
        if let name = prompt(title: parent == nil ? "新建标签" : "新建子标签", value: "") {
            onCreateTag(name, parent?.id)
        }
    }
    @objc private func renameTag() {
        guard let tag = clickedTag() ?? selectedTag(), let name = prompt(title: "重命名标签", value: tag.name) else { return }
        onRenameTag(tag, name)
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

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView(); cell.identifier = identifier
        let imageView = NSImageView(); imageView.translatesAutoresizingMaskIntoConstraints = false
        let textField = NSTextField(labelWithString: ""); textField.translatesAutoresizingMaskIntoConstraints = false; textField.lineBreakMode = .byTruncatingTail
        cell.addSubview(imageView); cell.addSubview(textField); cell.imageView = imageView; cell.textField = textField
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor), imageView.widthAnchor.constraint(equalToConstant: 18),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6), textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

private final class TagActionContext: NSObject {
    let tag: TagRecord
    let value: String?
    let target: TagRecord?
    init(tag: TagRecord, value: String? = nil, target: TagRecord? = nil) { self.tag = tag; self.value = value; self.target = target }
}
