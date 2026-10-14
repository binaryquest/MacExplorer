import AppKit
import ExplorerCore

@MainActor
final class FolderNode: NSObject {
    let title: String
    let url: URL?
    let symbol: String
    let section: Bool
    var favoriteID: UUID?
    var finderColors = FinderColorSummary()
    var children: [FolderNode]?
    var loading: Task<[FileItem], Error>?
    lazy var placeholder = FolderNode(title: "Loading…", url: nil, symbol: "", section: false, children: [])
    init(title: String, url: URL?, symbol: String = "folder", section: Bool = false, children: [FolderNode]? = nil) {
        self.title = title; self.url = url; self.symbol = symbol; self.section = section; self.children = children
    }
}

@MainActor
final class FolderSidebar: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let outline = FolderOutlineView()
    var onNavigate: ((URL) -> Void)?
    var onNewTab: ((URL) -> Void)?
    var onOtherPane: ((URL) -> Void)?
    var showHidden = false
    private var roots: [FolderNode] = []
    private var syncing = false
    private var syncTask: Task<Void, Never>?
    private var generation = UUID()
    private var selectedURL: URL?
    private var storageIdentity: [String] = []

    override func loadView() {
        let surface = Surface(); surface.color = Palette.sidebar; view = surface
        let scroll = NSScrollView(); scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        outline.backgroundColor = Palette.sidebar; outline.headerView = nil
        outline.rowHeight = 29; outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.indentationPerLevel = 13
        outline.style = .plain
        outline.autoresizesOutlineColumn = false
        outline.autoresizingMask = [.width]; outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.floatsGroupRows = false
        outline.allowsEmptySelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder")); column.width = 215
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.dataSource = self; outline.delegate = self
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setAccessibilityLabel("Folder tree")
        let menu = NSMenu(); menu.delegate = self; outline.menu = menu
        scroll.documentView = outline
        scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        rebuild()
        NotificationCenter.default.addObserver(self, selector: #selector(favoritesChanged), name: FavoriteStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: StorageStore.changed, object: nil)
        StorageStore.shared.refreshIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let scroll = outline.enclosingScrollView { outline.tableColumns.first?.width = max(100, scroll.contentSize.width - 2) }
    }
    @objc private func favoritesChanged() { rebuild(); if let selectedURL { sync(to: selectedURL) } }
    @objc private func volumesChanged() {
        let identity = StorageStore.shared.locations.map { $0.id + $0.title + $0.kind.rawValue }
        guard identity != storageIdentity else { return }; storageIdentity = identity
        rebuild(); if let selectedURL { sync(to: selectedURL) }
    }

    func rebuild() {
        generation = UUID(); syncTask?.cancel()
        let pins = FavoriteStore.shared.favorites.items.map { favorite in
            let node = FolderNode(title: favorite.name, url: favorite.url, symbol: favoriteSymbol(favorite.url))
            node.favoriteID = favorite.id; return node
        }
        let locations = StorageStore.shared.locations
        var devices = locations.filter { !$0.isNetworkLocation }.map {
            FolderNode(title: $0.title, url: $0.url, symbol: $0.kind == .internalDrive ? "internaldrive" : "externaldrive")
        }
        if !DemoData.active && !devices.contains(where: { $0.url?.path == "/" }) {
            devices.insert(FolderNode(title: "Macintosh HD", url: URL(fileURLWithPath: "/"), symbol: "internaldrive"), at: 0)
        }
        let networks = locations.filter(\.isNetworkLocation).map {
            FolderNode(title: $0.title, url: $0.url, symbol: $0.kind == .network ? "network" : "cloud.fill")
        }
        roots = [FolderNode(title: "Favorites", url: nil, section: true, children: pins),
                 FolderNode(title: "This Mac", url: BrowserLocation.thisMac, symbol: "desktopcomputer", children: devices)]
        if !networks.isEmpty { roots.append(FolderNode(title: "Network locations", url: nil, section: true, children: networks)) }
        syncing = true; outline.reloadData(); roots.forEach { outline.expandItem($0) }; syncing = false
        let colorGeneration = generation
        let colorNodes = roots.flatMap { $0.children ?? [] }.filter { $0.url?.isFileURL == true }
        let urls = colorNodes.compactMap(\.url)
        Task { [weak self] in
            let summaries = await Task.detached(priority: .utility) { urls.map { FinderColors.summary(at: $0) } }.value
            guard let self, self.generation == colorGeneration else { return }
            for (node, summary) in zip(colorNodes, summaries) { node.finderColors = summary; self.outline.reloadItem(node) }
        }
    }

    func sync(to url: URL) {
        selectedURL = url; syncTask?.cancel()
        if BrowserLocation.isThisMac(url), let node = roots.first(where: { $0.url == url }) {
            let row = outline.row(forItem: node)
            if row >= 0 { syncing = true; outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); outline.scrollRowToVisible(row); syncing = false }
            return
        }
        let candidates = roots.flatMap { $0.children ?? [] }.filter {
            guard let path = $0.url?.path else { return false }
            return path == "/" || url.path == path || url.path.hasPrefix(path + "/")
        }.sorted { ($0.url?.path.count ?? 0) > ($1.url?.path.count ?? 0) }
        guard let root = candidates.first else { return }
        let generation = self.generation
        syncTask = Task { [weak self] in
            guard let self else { return }
            var node = root
            let base = root.url!.pathComponents.count
            let parts = Array(url.pathComponents.dropFirst(base))
            for part in parts {
                await self.loadChildren(node)
                guard !Task.isCancelled, self.generation == generation else { return }
                self.syncing = true; self.outline.expandItem(node); self.syncing = false
                var next = node.children?.first(where: { $0.url?.lastPathComponent == part })
                if next == nil, let parent = node.url {
                    // Explicit path navigation may enter a hidden ancestor such as /tmp.
                    // Show that branch without revealing unrelated hidden folders.
                    let candidate = parent.appendingPathComponent(part, isDirectory: true)
                    let exists = await Task.detached(priority: .utility) {
                        (try? FileSystem.validateDirectory(candidate)) != nil
                    }.value
                    guard !Task.isCancelled, self.generation == generation else { return }
                    if exists {
                        let child = FolderNode(title: part, url: candidate)
                        node.children = ((node.children ?? []).filter { $0.url != nil } + [child])
                            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                        self.syncing = true; self.outline.reloadItem(node, reloadChildren: true)
                        self.outline.expandItem(node); self.syncing = false
                        next = child
                    }
                }
                guard let next else { break }
                node = next
            }
            guard !Task.isCancelled, self.generation == generation else { return }
            let row = self.outline.row(forItem: node)
            if row >= 0 {
                self.syncing = true; self.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                self.outline.scrollRowToVisible(row); self.syncing = false
            }
        }
    }

    private func loadChildren(_ node: FolderNode) async {
        guard node.children == nil, let url = node.url, url.isFileURL else { return }
        if node.loading == nil {
            node.loading = Task.detached(priority: .utility) { try FileSystem.list(url).filter(\.isNavigable) }
        }
        let generation = self.generation
        let children: [FileItem]
        do { children = try await node.loading!.value }
        catch {
            guard self.generation == generation else { return }
            node.children = [FolderNode(title: "Cannot read folder", url: nil, symbol: "lock", children: [])]
            node.loading = nil; outline.reloadItem(node, reloadChildren: true); return
        }
        guard self.generation == generation, node.children == nil else { return }
        node.children = FileSort().apply(to: children, showHidden: showHidden).map {
            let child = FolderNode(title: $0.name, url: $0.url, symbol: "folder")
            child.finderColors = $0.finderColors; return child
        }
        node.loading = nil
        syncing = true; outline.reloadItem(node, reloadChildren: true); syncing = false
    }

    private func favoriteSymbol(_ url: URL) -> String {
        if DemoData.active, url == DemoData.root { return "house.fill" }
        if url == FileManager.default.homeDirectoryForCurrentUser { return "house.fill" }
        return ["Desktop": "desktopcomputer", "Downloads": "arrow.down.circle.fill", "Documents": "doc.text.fill", "Pictures": "photo.fill", "Music": "music.note", "Movies": "film.fill"][url.lastPathComponent] ?? "folder.fill"
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SidebarRowView() }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FolderNode else { return roots.count }
        return node.children?.count ?? 1
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FolderNode else { return false }
        return node.children.map { !$0.isEmpty } ?? (node.url != nil)
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FolderNode else { return roots[index] }
        if let children = node.children { return children[index] }
        return node.placeholder
    }
    func outlineViewItemWillExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? FolderNode, node.children == nil {
            Task { [weak self] in await self?.loadChildren(node) }
        }
    }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? FolderNode)?.section == true }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? FolderNode)?.url != nil }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { (item as? FolderNode)?.section == true ? 33 : 29 }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderNode else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: node.title); label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: node.section ? 11 : 12, weight: node.section ? .semibold : .regular)
        label.textColor = node.section || node.url == nil ? .secondaryLabelColor : .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false; cell.textField = label; cell.addSubview(label)
        let leading: NSLayoutXAxisAnchor
        if !node.section {
            let image = NSImageView(image: Palette.symbol(node.symbol) ?? NSImage()); image.translatesAutoresizingMaskIntoConstraints = false
            image.contentTintColor = node.symbol.hasPrefix("folder") ? .systemYellow : node.favoriteID != nil ? (node.symbol == "house.fill" ? .systemOrange : .systemBlue) : .secondaryLabelColor
            if let color = node.finderColors.colors.first { image.contentTintColor = FileColors.color(color) }
            cell.imageView = image; cell.addSubview(image)
            NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 17), image.heightAnchor.constraint(equalToConstant: 17)])
            leading = image.trailingAnchor
        } else { leading = cell.leadingAnchor }
        if node.favoriteID != nil {
            let pin = NSImageView(image: Palette.symbol("pin.fill", size: 9) ?? NSImage()); pin.contentTintColor = .tertiaryLabelColor
            cell.addSubview(pin); pin.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([pin.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), pin.centerYAnchor.constraint(equalTo: cell.centerYAnchor), pin.widthAnchor.constraint(equalToConstant: 10), pin.heightAnchor.constraint(equalToConstant: 12)])
        }
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leading, constant: 8), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: node.favoriteID == nil ? -5 : -24), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        cell.toolTip = [node.url?.path ?? "", FileColors.description(node.finderColors)].filter { !$0.isEmpty }.joined(separator: "\n")
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let node = outline.item(atRow: outline.selectedRow) as? FolderNode, let url = node.url else { return }
        onNavigate?(url)
    }
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard !FileOperationController.shared.busy, let url = (item as? FolderNode)?.url, url.isFileURL else { return nil }
        return url as NSURL
    }
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard view.window?.attachedSheet == nil, let node = item as? FolderNode, let url = node.url, url.isFileURL else { return [] }
        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return FileDrag.operation(info, to: url)
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let url = (item as? FolderNode)?.url, url.isFileURL else { return false }
        return FileDrag.accept(info, to: url, window: view.window)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        ContextMenu.configure(menu)
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard let node = outline.item(atRow: row) as? FolderNode, let url = node.url else { return }
        func add(_ title: String, _ action: Selector, value: Any, enabled: Bool = true, symbol: String = "folder") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = value; item.isEnabled = enabled
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); menu.addItem(item)
        }
        add("Open in New Tab", #selector(openNodeInTab(_:)), value: url)
        add("Open in Other Pane", #selector(openNodeInOtherPane(_:)), value: url)
        guard url.isFileURL else { return }
        menu.addItem(ContextMenu.item("Open in New Window", symbol: "macwindow.badge.plus") { (NSApp.delegate as? AppDelegate)?.newWindow(urls: [url]) })
        if let window = view.window { menu.addItem(FileColorMenu.shared.item(urls: [url], summaries: [node.finderColors], window: window)) }
        menu.addItem(.separator())
        add(FavoriteStore.shared.favorites.contains(url) ? "Unpin from Favorites" : "Pin to Favorites", #selector(pinNode(_:)), value: url, symbol: "pin")
        menu.addItem(ContextMenu.item("Copy as Path", symbol: "link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) })
        menu.addItem(.separator())
        menu.addItem(ExternalApplications.terminalItem(folder: url, window: view.window))
        if let id = node.favoriteID, let index = FavoriteStore.shared.favorites.items.firstIndex(where: { $0.id == id }) {
            menu.addItem(.separator())
            add("Move Favorite Up", #selector(favoriteUp(_:)), value: id, enabled: index > 0)
            add("Move Favorite Down", #selector(favoriteDown(_:)), value: id, enabled: index + 1 < FavoriteStore.shared.favorites.items.count)
        }
    }
    @objc private func pinNode(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { FavoriteStore.shared.toggle(url) } }
    @objc private func favoriteUp(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { FavoriteStore.shared.move(id, by: -1) } }
    @objc private func favoriteDown(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { FavoriteStore.shared.move(id, by: 1) } }
    @objc private func openNodeInTab(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { onNewTab?(url) } }
    @objc private func openNodeInOtherPane(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { onOtherPane?(url) } }
}
