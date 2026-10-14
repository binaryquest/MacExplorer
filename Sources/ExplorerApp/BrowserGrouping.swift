import AppKit
import ExplorerCore

@MainActor
final class FileGroupHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("FileGroupHeader")
    private let button = NSButton()
    var onToggle: (() -> Void)?
    private(set) var collapsed = false
    var accessibilityButton: NSView { button }
    override init(frame: NSRect) {
        super.init(frame: frame)
        button.isBordered = false; button.bezelStyle = .regularSquare
        button.alignment = .left; button.font = .systemFont(ofSize: 13)
        button.contentTintColor = Palette.groupText; button.imagePosition = .imageLeading; button.imageHugsTitle = true
        button.target = self; button.action = #selector(toggle)
        addSubview(button); button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), button.topAnchor.constraint(equalTo: topAnchor), button.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ group: FileGroup, collapsed: Bool) {
        configure(title: group.title, count: group.items.count, collapsed: collapsed)
    }
    func configure(title: String, count: Int, collapsed: Bool) {
        self.collapsed = collapsed
        button.title = "  \(title) (\(count.formatted()))"
        button.image = Palette.symbol(collapsed ? "chevron.right" : "chevron.down", size: 10)
        button.setAccessibilityLabel("\(collapsed ? "Expand" : "Collapse") \(title) group, \(count) \(count == 1 ? "item" : "items")")
    }
    @objc private func toggle() { onToggle?() }
}

extension BrowserViewController {
    func file(atRow row: Int) -> FileItem? {
        guard let index = tab.displayIndex.item(atRow: row), tab.visible.indices.contains(index) else { return nil }; return tab.visible[index]
    }
    func file(at indexPath: IndexPath) -> FileItem? {
        guard let index = tab.displayIndex.item(section: indexPath.section, offset: indexPath.item), tab.visible.indices.contains(index) else { return nil }; return tab.visible[index]
    }
    func iconPath(for index: Int) -> IndexPath? {
        tab.displayIndex.position(forItem: index).map { IndexPath(item: $0.item, section: $0.section) }
    }
    func reloadFilePresentation(selected: Set<String>, pending: Set<String>? = nil) {
        // Reveal an explicitly requested item even if its group was collapsed.
        if let pending {
            for group in tab.groups where group.items.contains(where: { pending.contains(FileOperationController.itemPath($0.url)) }) { tab.collapsedGroups.remove(group.id) }
        }
        tab.displayIndex = FileDisplayIndex(groups: tab.groups, grouped: tab.grouping.key != .none, collapsedIDs: tab.collapsedGroups)
        suppressSelection = true; cancelVisibleThumbnails(); table.reloadData(); collection.reloadData()
        iconLayout.invalidateLayout()
        let indexes = tab.visible.enumerated().filter {
            tab.displayIndex.row(forItem: $0.offset) != nil && (pending?.contains(FileOperationController.itemPath($0.element.url)) ?? selected.contains($0.element.id))
        }.map(\.offset)
        table.selectRowIndexes(IndexSet(indexes.compactMap { tab.displayIndex.row(forItem: $0) }), byExtendingSelection: false)
        collection.selectionIndexPaths = Set(indexes.compactMap(iconPath))
        let restored = Set(indexes.map { tab.visible[$0].id })
        tab.selections[tab.selectionKey] = tab.isRecursiveSearch && tab.loading ? selected.union(restored) : restored
        tab.pendingSelections.removeValue(forKey: tab.selectionKey)
        restoreScroll()
        if pending != nil, let first = indexes.first {
            if viewMode.usesTable, let row = tab.displayIndex.row(forItem: first) { table.scrollRowToVisible(row) }
            else if let path = iconPath(for: first) { collection.scrollToItems(at: [path], scrollPosition: .nearestVerticalEdge) }
        }
        suppressSelection = false
        updateStatus(); updateEmptyState(); updateQuickLookSelection()
    }
    func toggleGroup(_ id: String) {
        workspace?.activate(self); rememberSelection()
        if tab.collapsedGroups.contains(id) { tab.collapsedGroups.remove(id) } else { tab.collapsedGroups.insert(id) }
        reloadFilePresentation(selected: tab.selections[tab.selectionKey] ?? [])
        view.window?.makeFirstResponder(activeFileView)
    }
    func makeGroupHeader(section: Int, header: FileGroupHeader = FileGroupHeader()) -> FileGroupHeader {
        guard tab.groups.indices.contains(section) else { return header }
        let group = tab.groups[section]
        header.configure(group, collapsed: tab.collapsedGroups.contains(group.id))
        header.onToggle = { [weak self] in self?.toggleGroup(group.id) }
        return header
    }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard tab.displayIndex.rows.indices.contains(row) else { return false }
        if case .header = tab.displayIndex.rows[row] { return true }; return false
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        file(atRow: row) == nil ? 36 : viewMode == .content ? ContentResultCell.rowHeight(for: tableScroll.contentSize.width) : 29
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = FileRowView(); view.contentSeparator = viewMode == .content && file(atRow: row) != nil
        return view
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { file(atRow: row) != nil }
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        IndexSet(proposedSelectionIndexes.filter { tab.displayIndex.item(atRow: $0) != nil })
    }
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? { file(atRow: row)?.name }

    func sortingMenu() -> NSMenu {
        let menu = NSMenu(); menu.addItem(withTitle: "Sort", action: nil, keyEquivalent: "")
        for (key, title) in [(FileSortKey.name, "Name"), (.modified, "Date modified"), (.kind, "Type"), (.size, "Size"), (.created, "Date created")] {
            let item = NSMenuItem(title: title, action: #selector(changeIconSort(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = key.rawValue; menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, ascending) in [("Ascending", true), ("Descending", false)] {
            let item = NSMenuItem(title: title, action: #selector(setSortDirection(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = ascending; menu.addItem(item)
        }
        menu.addItem(.separator())
        let group = NSMenuItem(title: "Group by", action: nil, keyEquivalent: ""), submenu = NSMenu()
        for key in FileGroupKey.allCases.filter({ $0 != .none }) + [.none] {
            if key == .none { submenu.addItem(.separator()) }
            let item = NSMenuItem(title: key == .none ? "(None)" : key.title, action: #selector(changeGrouping(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = key.rawValue; submenu.addItem(item)
        }
        submenu.addItem(.separator())
        for (title, ascending) in [("Groups ascending", true), ("Groups descending", false)] {
            let item = NSMenuItem(title: title, action: #selector(setGroupDirection(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = ascending; submenu.addItem(item)
        }
        group.submenu = submenu; menu.addItem(group)
        return menu
    }
    @objc func setSortDirection(_ sender: NSMenuItem) {
        guard let ascending = sender.representedObject as? Bool else { return }
        rememberSelection(); tab.sort.ascending = ascending; updateSortPresentation(); applyView(); saveSession()
    }
    @objc func changeGrouping(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = FileGroupKey(rawValue: raw) else { return }
        rememberSelection(); tab.grouping = FileGrouping(key: key); tab.collapsedGroups = []
        tab.scrollPositions[scrollKey] = 0; updateSortPresentation(); applyView(); saveSession()
    }
    @objc func setGroupDirection(_ sender: NSMenuItem) {
        guard let ascending = sender.representedObject as? Bool else { return }
        rememberSelection(); tab.grouping.ascending = ascending; updateSortPresentation(); applyView(); saveSession()
    }
}
