import AppKit
import ExplorerCore
import Quartz

extension BrowserViewController: NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    func buildIconGrid() {
        iconLayout.scrollDirection = .vertical
        iconLayout.sectionInset = NSEdgeInsets(top: 4, left: 12, bottom: 12, right: 12)
        iconLayout.minimumInteritemSpacing = 6; iconLayout.minimumLineSpacing = 6
        collection.collectionViewLayout = iconLayout
        collection.isSelectable = true; collection.allowsMultipleSelection = true
        collection.backgroundColors = [.controlBackgroundColor]
        collection.register(FileIconItem.self, forItemWithIdentifier: FileIconItem.identifier)
        collection.register(FileGroupHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: FileGroupHeader.identifier)
        collection.dataSource = self; collection.delegate = self
        collection.autoresizingMask = [.width]
        collection.setAccessibilityLabel("Files, icon view")
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu(); menu.delegate = self; collection.menu = menu
        collection.onOpen = { [weak self] in self?.openSelected(inNewTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true) }
        collection.onBack = { [weak self] in self?.goBack() }
        collection.onPreview = { [weak self] in self?.toggleQuickLook() }
        collection.onFileAction = { [weak self] in self?.performFileAction($0) }
        collection.canFileAction = { [weak self] in self?.canPerformFileAction($0) == true }
        collection.onContext = { [weak self] index in
            guard let self else { return }
            if let index, self.file(at: index) != nil {
                if !self.collection.selectionIndexPaths.contains(index) { self.collection.selectionIndexPaths = [index] }
            } else { self.collection.selectionIndexPaths = [] }
            self.iconSelectionChanged()
        }
        collection.onTypeSelect = { [weak self] prefix in
            guard let self, let index = self.tab.visible.indices.first(where: { self.iconPath(for: $0) != nil && self.tab.visible[$0].name.lowercased().hasPrefix(prefix.lowercased()) }), let path = self.iconPath(for: index) else { return }
            let paths: Set<IndexPath> = [path]
            self.collection.selectionIndexPaths = paths
            self.collection.scrollToItems(at: paths, scrollPosition: .nearestVerticalEdge)
            self.iconSelectionChanged()
        }
        collectionScroll.documentView = collection
        collectionScroll.hasVerticalScroller = true; collectionScroll.hasHorizontalScroller = false
        collectionScroll.drawsBackground = false
    }
    func presentationMenu() -> NSMenu {
        let menu = NSMenu(); menu.addItem(withTitle: "View", action: nil, keyEquivalent: "")
        for mode in FileViewMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(changePresentation(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = mode.rawValue; menu.addItem(item)
        }
        return menu
    }
    @objc func changePresentation(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = FileViewMode(rawValue: raw) { setViewMode(mode) }
    }
    @objc func changeIconSort(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = FileSortKey(rawValue: raw) else { return }
        rememberSelection(); tab.sort.key = key; updateSortPresentation(); applyView(); saveSession()
    }
    func updateSortPresentation() {
        let wasSuppressed = suppressSelection; suppressSelection = true
        table.sortDescriptors = [NSSortDescriptor(key: tab.sort.key.rawValue, ascending: tab.sort.ascending)]
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("created"))?.isHidden = viewMode == .content || (tab.sort.key != .created && tab.grouping.key != .created)
        suppressSelection = wasSuppressed
        for item in sortPicker.menu?.items ?? [] {
            if item.action == #selector(changeIconSort(_:)) { item.state = (item.representedObject as? String) == tab.sort.key.rawValue ? .on : .off }
            if item.action == #selector(setSortDirection(_:)) { item.state = (item.representedObject as? Bool) == tab.sort.ascending ? .on : .off }
            for group in item.submenu?.items ?? [] {
                if group.action == #selector(changeGrouping(_:)) { group.state = (group.representedObject as? String) == tab.grouping.key.rawValue ? .on : .off }
                if group.action == #selector(setGroupDirection(_:)) {
                    group.state = (group.representedObject as? Bool) == tab.grouping.ascending ? .on : .off
                    group.isEnabled = tab.grouping.key != .none
                }
            }
        }
    }
    func setViewMode(_ mode: FileViewMode) {
        guard !tab.isThisMac, view.window?.attachedSheet == nil, viewMode != mode else { return }
        rememberSelection(); cancelVisibleThumbnails()
        if tab.hasSearchQuery { tab.searchViewMode = mode }
        else { tab.viewMode = mode; AppPreferences.shared.viewMode = mode }
        applyPresentationMode(); applyView(); saveSession(); view.window?.makeFirstResponder(activeFileView)
    }
    func applyPresentationMode() {
        thisMacView.isHidden = !tab.isThisMac
        tableScroll.isHidden = tab.isThisMac || !viewMode.usesTable; collectionScroll.isHidden = tab.isThisMac || viewMode.usesTable
        sortPicker.isEnabled = !tab.isThisMac; viewPicker.isEnabled = !tab.isThisMac; hiddenButton?.isEnabled = !tab.isThisMac
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("location"))?.isHidden = !tab.isRecursiveSearch
        if tab.isRecursiveSearch {
            let index = table.column(withIdentifier: NSUserInterfaceItemIdentifier("location"))
            if index != 1 { table.moveColumn(index, toColumn: 1) }
        }
        var size: NSSize
        switch viewMode {
        case .extraLarge: size = NSSize(width: 208, height: 218)
        case .large: size = NSSize(width: 152, height: 154)
        case .medium: size = NSSize(width: 112, height: 120)
        case .small: size = NSSize(width: 210, height: 36)
        case .details, .content: size = iconLayout.itemSize
        }
        if tab.isRecursiveSearch && !viewMode.usesTable { size.height += 20 }
        if iconLayout.itemSize != size { iconLayout.itemSize = size; iconLayout.invalidateLayout() }
        for item in viewPicker.menu?.items ?? [] {
            if let mode = item.representedObject as? String { item.state = mode == viewMode.rawValue ? .on : .off }
        }
        updateSortPresentation(); configureTablePresentation()
    }
    func restoreScroll() {
        view.layoutSubtreeIfNeeded(); activeFileView.layoutSubtreeIfNeeded()
        if viewMode.usesTable, (tab.scrollPositions[scrollKey] ?? 0) <= 0, !tab.visible.isEmpty {
            table.scrollRowToVisible(0); return
        }
        let maxY = max(0, activeFileView.frame.height - activeScroll.contentSize.height)
        let y = min(maxY, max(0, tab.scrollPositions[scrollKey] ?? 0))
        activeScroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        activeScroll.reflectScrolledClipView(activeScroll.contentView)
    }
    func numberOfSections(in collectionView: NSCollectionView) -> Int { tab.groups.count }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { tab.displayIndex.count(inSection: section) }
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, insetForSectionAt section: Int) -> NSEdgeInsets {
        tab.displayIndex.collapsed.contains(section) ? NSEdgeInsetsZero : iconLayout.sectionInset
    }
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> NSSize {
        NSSize(width: collectionView.bounds.width, height: tab.grouping.key == .none ? 0 : 36)
    }
    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: FileGroupHeader.identifier, for: indexPath) as! FileGroupHeader
        return makeGroupHeader(section: indexPath.section, header: header)
    }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: FileIconItem.identifier, for: indexPath) as! FileIconItem
        configureIcon(cell, at: indexPath); return cell
    }
    func configureIcon(_ cell: FileIconItem, at indexPath: IndexPath) {
        guard let item = file(at: indexPath), !viewMode.usesTable else { cell.cancelThumbnail(); return }
        cell.onAccessibilityPress { [weak self] in
            guard let self else { return }
            self.collection.selectionIndexPaths = [indexPath]
            self.view.window?.makeFirstResponder(self.collection); self.iconSelectionChanged()
        }
        let key = FileColors.cacheKey(item)
        let icon = iconCache.object(forKey: key) ?? FileColors.icon(item)
        iconCache.setObject(icon, forKey: key)
        cell.configure(item, mode: viewMode, fallback: icon, dimmed: operations.cutPaths.contains(FileOperationController.itemPath(item.url)), scale: view.window?.backingScaleFactor ?? 2, location: tab.isRecursiveSearch ? DirectorySearch.location(of: item.url, relativeTo: tab.history.current) : nil, query: tab.query,
                       onReveal: { [weak self] in self?.revealInContainingFolder(item.url) })
    }
    func configureVisibleIcons() {
        for case let cell as FileIconItem in collection.visibleItems() {
            if let index = collection.indexPath(for: cell) { configureIcon(cell, at: index) }
        }
    }
    func cancelVisibleThumbnails() { for case let cell as FileIconItem in collection.visibleItems() { cell.cancelThumbnail() } }
    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) { (item as? FileIconItem)?.cancelThumbnail() }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { iconSelectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { iconSelectionChanged() }
    func iconSelectionChanged() {
        guard !suppressSelection else { return }
        rememberSelection(); updateStatus()
        // AppKit reports deselection before the replacement selection. Preview the
        // final selection after the event, without briefly closing the panel.
        Task { @MainActor [weak self] in self?.updateQuickLookSelection() }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard !operations.busy, let item = file(atRow: row) else { return nil }
        return item.url as NSURL
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard view.window?.attachedSheet == nil else { return [] }
        if operation == .on, let item = file(atRow: row), item.isNavigable {
            return FileDrag.operation(info, to: item.url)
        }
        tableView.setDropRow(-1, dropOperation: .on)
        guard let destination = folderDestination else { return [] }
        return FileDrag.operation(info, to: destination)
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        let item = file(atRow: row)
        let destination = operation == .on && item?.isNavigable == true ? item?.url : folderDestination
        guard let destination else { return false }
        return FileDrag.accept(info, to: destination, window: view.window)
    }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard !operations.busy, let item = file(at: indexPath) else { return nil }
        return item.url as NSURL
    }
    func collectionView(_ collectionView: NSCollectionView, validateDrop info: NSDraggingInfo, proposedIndexPath proposed: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation operation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard view.window?.attachedSheet == nil else { return [] }
        let point = collectionView.convert(info.draggingLocation, from: nil)
        if let index = collectionView.indexPathForItem(at: point), let item = file(at: index), item.isNavigable {
            proposed.pointee = index as NSIndexPath; operation.pointee = .on
            return FileDrag.operation(info, to: item.url)
        }
        let lastSection = max(0, tab.groups.count - 1)
        proposed.pointee = IndexPath(item: tab.displayIndex.count(inSection: lastSection), section: lastSection) as NSIndexPath; operation.pointee = .before
        guard let destination = folderDestination else { return [] }
        return FileDrag.operation(info, to: destination)
    }
    func collectionView(_ collectionView: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath: IndexPath, dropOperation operation: NSCollectionView.DropOperation) -> Bool {
        let item = file(at: indexPath)
        let destination = operation == .on && item?.isNavigable == true ? item?.url : folderDestination
        guard let destination else { return false }
        return FileDrag.accept(info, to: destination, window: view.window)
    }
}

extension BrowserViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    var canQuickLook: Bool { !selectedItems.isEmpty && view.window?.attachedSheet == nil }
    @objc func contextPreview() { toggleQuickLook() }
    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, panel.dataSource === self { panel.orderOut(nil); return }
        guard canQuickLook else { return }
        previewURLs = selectedItems.map { $0.url as NSURL }
        panel.makeKeyAndOrderFront(nil)
        beginQuickLook(panel)
    }
    func beginQuickLook(_ panel: QLPreviewPanel) {
        previewURLs = selectedItems.map { $0.url as NSURL }
        panel.dataSource = self; panel.delegate = self; panel.reloadData()
    }
    func endQuickLook(_ panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil; panel.delegate = nil }
        previewURLs = []
    }
    func closeQuickLook() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.dataSource === self { panel.orderOut(nil) }
    }
    func updateQuickLookSelection() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible, panel.dataSource === self else { return }
        let urls = selectedItems.map { $0.url as NSURL }
        guard !urls.isEmpty else { panel.orderOut(nil); return }
        guard urls != previewURLs else { return }
        let current = previewURLs.indices.contains(panel.currentPreviewItemIndex) ? previewURLs[panel.currentPreviewItemIndex] : nil
        previewURLs = urls; panel.reloadData()
        panel.currentPreviewItemIndex = current.flatMap { urls.firstIndex(of: $0) } ?? 0
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURLs.indices.contains(index) ? previewURLs[index] : nil
    }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 49 || event.keyCode == 53 { panel.orderOut(nil); view.window?.makeFirstResponder(activeFileView); return true }
        if previewURLs.count == 1, [123, 124, 125, 126].contains(event.keyCode) {
            suppressSelection = true
            activeFileView.keyDown(with: event)
            suppressSelection = false; rememberSelection(); updateStatus(); updateQuickLookSelection(); return true
        }
        return false
    }
}
