import AppKit
import ExplorerCore
import Quartz

@MainActor
final class BrowserTab {
    let id = UUID()
    var history: NavigationHistory
    var items: [FileItem] = []
    var visible: [FileItem] = []
    var groups: [FileGroup] = []
    var grouping = FileGrouping()
    var collapsedGroups: Set<String> = []
    var displayIndex = FileDisplayIndex()
    func clearVisible() { visible = []; groups = []; displayIndex = FileDisplayIndex() }
    var query = ""
    var searchScope = AppPreferences.shared.searchScope
    var searchTask: Task<Void, Never>?
    var searchGeneration = UUID()
    var searchScanned = 0
    var searchSkipped = 0
    var searchLimited = false
    var searchStopped = false
    var isThisMac: Bool { BrowserLocation.isThisMac(history.current) }
    var hasSearchQuery: Bool { !isThisMac && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isRecursiveSearch: Bool { hasSearchQuery && searchScope == .subfolders }
    var searchViewMode = FileViewMode.content
    var selectionKey: String { history.current.path + (hasSearchQuery ? "\nsearch:" + searchScope.rawValue + ":" + query : "") }
    var sort = FileSort()
    var viewMode = AppPreferences.shared.viewMode
    var selections: [String: Set<String>] = [:]
    var pendingSelections: [String: Set<String>] = [:]
    var scrollPositions: [String: CGFloat] = [:]
    var loading = false
    var changedDuringLoad = false
    var error: String?
    var loadTask: Task<Void, Never>?
    var sortTask: Task<Void, Never>?
    var generation = UUID()
    var sortGeneration = UUID()
    init(url: URL) { history = NavigationHistory(url) }
}

@MainActor
final class BrowserViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate {
    var tabs: [BrowserTab]
    var activeIndex: Int
    var tab: BrowserTab { tabs[activeIndex] }
    var canGoBack: Bool { tab.history.canGoBack }
    var canGoForward: Bool { tab.history.canGoForward }
    var canGoUp: Bool { !tab.isThisMac }
    private(set) var showHidden = UserDefaults.standard.bool(forKey: "explorer.showHidden")
    var onCloseWindow: (() -> Void)?

    let headerView = Surface()
    var tabStripWidth: NSLayoutConstraint?
    var tabBarLeading: NSLayoutConstraint?
    private var newTabCenterY: NSLayoutConstraint?
    var navigationWide: [NSLayoutConstraint] = []
    var navigationNarrow: [NSLayoutConstraint] = []
    var compactNavigation: Bool?
    let tabsScroll = TabStripScrollView()
    let tabsDocument = TabStripDocumentView()
    let pathBar = PathBar()
    let search = SearchBox()
    weak var workspace: WorkspaceViewController?
    var commandBar: NSView!
    let paneBadge = NSTextField(labelWithString: "")
    var paneBadgeWidth: NSLayoutConstraint?
    var paneHeader: Surface?
    var tabBar: TabBarView?
    let searchOptions = FlatMenuButton(frame: .zero, pullsDown: true)
    var closeSearchButton: ActionButton!
    var searchOptionsWidth: NSLayoutConstraint?
    var closeSearchWidth: NSLayoutConstraint?
    var pinButton: ActionButton!
    var dualButton: ActionButton!
    var copyOtherButton: ActionButton!
    var moveOtherButton: ActionButton!
    var folderDestination: URL? { !tab.isThisMac && !tab.isRecursiveSearch && !tab.loading && tab.error == nil ? tab.history.current : nil }
    let thisMacView = ThisMacView()
    let table = FileTableView()
    let tableScroll = NSScrollView()
    var detailsHeaderView: NSTableHeaderView?
    var detailColumnWidths: [String: CGFloat] = [:]
    var tableShowsContent = false
    var compactContentRows = false
    let collection = FileCollectionView()
    let collectionScroll = NSScrollView()
    let iconLayout = NSCollectionViewFlowLayout()
    let viewPicker = FlatMenuButton(frame: .zero, pullsDown: true)
    let sortPicker = FlatMenuButton(frame: .zero, pullsDown: true)
    var previewButton: ActionButton!
    var previewURLs: [NSURL] = []
    var tabChips: [UUID: BrowserTabView] = [:]
    var viewMode: FileViewMode { tab.hasSearchQuery ? tab.searchViewMode : tab.viewMode }
    var activeFileView: NSView { tab.isThisMac ? thisMacView.collection : viewMode.usesTable ? table : collection }
    var activeScroll: NSScrollView { viewMode.usesTable ? tableScroll : collectionScroll }
    var scrollKey: String { tab.selectionKey + "|" + viewMode.rawValue + "|" + tab.grouping.key.rawValue }
    let status = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    let emptyStack = NSStackView()
    let emptyTitle = NSTextField(labelWithString: "")
    let emptyDescription = NSTextField(wrappingLabelWithString: "")
    var backButton: ActionButton!
    var forwardButton: ActionButton!
    var upButton: ActionButton!
    var hiddenButton: ActionButton!
    var operationButtons: [FileAction: ActionButton] = [:]
    let operations = FileOperationController.shared
    var watcher: DirectoryWatcher?
    var watcherURL: URL?
    var watcherTabID: UUID?
    var refreshTask: Task<Void, Never>?
    var suppressSelection = false
    let iconCache = NSCache<NSString, NSImage>()
    let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short; return formatter
    }()

    init(urls: [URL], active: Int) {
        let urls = urls.isEmpty ? [BrowserLocation.thisMac] : urls
        self.tabs = urls.map { BrowserTab(url: $0) }; self.activeIndex = min(max(active, 0), urls.count - 1)
        super.init(nibName: nil, bundle: nil)
    }
    convenience init(session: PaneSession) {
        self.init(urls: session.paths.compactMap(BrowserLocation.restored), active: session.active)
        for (index, raw) in session.modes.enumerated() where tabs.indices.contains(index) {
            if let mode = FileViewMode(rawValue: raw) { tabs[index].viewMode = mode }
        }
        for (index, presentation) in (session.presentations ?? []).enumerated() where tabs.indices.contains(index) {
            tabs[index].sort = presentation.sort; tabs[index].grouping = presentation.grouping
        }
    }
    convenience init(transferredTab: BrowserTab, showHidden: Bool) {
        self.init(urls: [transferredTab.history.current], active: 0)
        tabs = [transferredTab]; self.showHidden = showHidden
    }
    var session: PaneSession { PaneSession(paths: tabs.map { BrowserLocation.stored($0.history.current) }, active: activeIndex, modes: tabs.map { $0.viewMode.rawValue }, presentations: tabs.map { TabPresentation(sort: $0.sort, grouping: $0.grouping) }) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = Surface(frame: NSRect(x: 0, y: 0, width: 1160, height: 760))
        root.color = .controlBackgroundColor; view = root
        iconCache.countLimit = 600
        _ = buildTabsBar()
        let navigation = buildNavigationBar(), footer = buildFooter()
        commandBar = buildCommandBar()
        headerView.color = Palette.navigation
        headerView.addSubview(navigation); navigation.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            navigation.leadingAnchor.constraint(equalTo: headerView.leadingAnchor), navigation.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            navigation.topAnchor.constraint(equalTo: headerView.topAnchor), navigation.bottomAnchor.constraint(equalTo: headerView.bottomAnchor)
        ])
        buildFileTable(); buildIconGrid()
        let fileArea = buildFileArea()
        for child in [fileArea, footer] { view.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            fileArea.topAnchor.constraint(equalTo: view.topAnchor), fileArea.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.heightAnchor.constraint(equalToConstant: 27), footer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        for child in [fileArea, footer] {
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor).isActive = true
        }
        pathBar.onNavigate = { [weak self] in self?.navigate($0) }
        pathBar.onCommit = { [weak self] text in
            guard let self, let url = FolderPath.resolve(text, relativeTo: self.tab.history.current) else { return }
            self.navigate(url); self.view.window?.makeFirstResponder(self.activeFileView)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(operationsChanged), name: FileOperationController.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(operationsFinished(_:)), name: FileOperationController.finished, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(operationsChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(favoritesChanged), name: FavoriteStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(storageChanged), name: StorageStore.changed, object: nil)
        updateChrome(); loadFolder(clear: true)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Keep metadata columns readable; let only the name column absorb resizing.
        let metadataWidths = ["modified": CGFloat(185), "kind": CGFloat(100), "size": CGFloat(75)]
        for column in table.tableColumns {
            if let width = metadataWidths[column.identifier.rawValue] { column.width = width }
        }
        table.tableColumns.first?.width = max(180, tableScroll.contentSize.width - 360)
        table.setFrameSize(NSSize(width: max(tableScroll.contentSize.width, 540), height: table.frame.height))
        updateChrome(); fitContentTable()
        if workspace?.activeBrowser === self { view.window?.makeFirstResponder(activeFileView) }
    }

    func buildTabsBar() -> NSView {
        let bar = TabBarView(); bar.browser = self; tabBar = bar; paneHeader = bar; bar.color = Palette.chrome
        bar.onLayout = { [weak self] in self?.layoutTabStrip() }
        tabsScroll.drawsBackground = false; tabsScroll.hasHorizontalScroller = false; tabsScroll.hasVerticalScroller = false
        // This scroll view intentionally occupies the titlebar safe area.
        tabsScroll.automaticallyAdjustsContentInsets = false
        tabsScroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        tabsScroll.horizontalScrollElasticity = .allowed; tabsScroll.verticalScrollElasticity = .none
        tabsScroll.documentView = tabsDocument
        let add = ActionButton(symbol: "plus", tooltip: "New tab (⌘T)") { [weak self] in self?.newTab() }
        paneBadge.font = .systemFont(ofSize: 11, weight: .semibold)
        paneBadgeWidth = paneBadge.widthAnchor.constraint(equalToConstant: 0); paneBadgeWidth?.isActive = true
        for child in [paneBadge, tabsScroll, add] { bar.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        tabBarLeading = paneBadge.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8)
        tabBarLeading?.isActive = true
        newTabCenterY = add.centerYAnchor.constraint(equalTo: bar.bottomAnchor, constant: -19)
        newTabCenterY?.isActive = true
        NSLayoutConstraint.activate([
            paneBadge.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            tabsScroll.leadingAnchor.constraint(equalTo: paneBadge.trailingAnchor, constant: 4),
            add.leadingAnchor.constraint(equalTo: tabsScroll.trailingAnchor, constant: 4),
            tabsScroll.topAnchor.constraint(equalTo: bar.topAnchor), tabsScroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            // Leave a draggable patch even when the tab strip overflows.
            add.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -48)
        ])
        tabStripWidth = tabsScroll.widthAnchor.constraint(equalToConstant: 216)
        tabStripWidth?.priority = .defaultHigh; tabStripWidth?.isActive = true
        return bar
    }

    func buildCommandBar() -> NSView {
        let bar = Surface(); bar.color = .controlBackgroundColor; bar.border = true
        func button(_ action: FileAction, _ symbol: String, _ tooltip: String, title: String = "") -> ActionButton {
            let button = ActionButton(title, symbol: symbol, tooltip: tooltip) { [weak self] in self?.performFileAction(action) }
            operationButtons[action] = button; return button
        }
        let new = button(.newFolder, "folder.badge.plus", "New folder (⇧⌘N or Ctrl+Shift+N)", title: "New")
        let cut = button(.cut, "scissors", "Cut (⌘X or Ctrl+X)")
        let copy = button(.copy, "doc.on.doc", "Copy (⌘C or Ctrl+C)")
        let paste = button(.paste, "doc.on.clipboard", "Paste (⌘V or Ctrl+V)")
        let rename = button(.rename, "pencil", "Rename (F2)")
        let move = button(.move, "folder", "Move to folder… (⇧⌘M)")
        let trash = button(.trash, "trash", "Move to Trash (Delete or ⌘Backspace)")
        let undo = button(.undo, "arrow.uturn.backward", "Undo (⌘Z or Ctrl+Z)")
        let cancel = button(.cancel, "xmark.circle", "Cancel operation or pending cut (Escape)")
        hiddenButton = ActionButton(symbol: "eye.slash", tooltip: "Show hidden files (⇧⌘.)") { [weak self] in self?.toggleHidden() }
        previewButton = ActionButton(symbol: "eye", tooltip: "Quick Look (Space)") { [weak self] in self?.toggleQuickLook() }
        viewPicker.menu = presentationMenu(); viewPicker.font = .systemFont(ofSize: 12)
        viewPicker.setAccessibilityLabel("View options"); viewPicker.widthAnchor.constraint(equalToConstant: 86).isActive = true
        viewPicker.menu?.items.first?.image = Palette.buttonSymbol("list.bullet", size: 14, canvas: 18)
        sortPicker.menu = sortingMenu(); sortPicker.setAccessibilityLabel("Sort and group options")
        sortPicker.widthAnchor.constraint(equalToConstant: 88).isActive = true
        sortPicker.menu?.items.first?.image = Palette.buttonSymbol("arrow.up.arrow.down", size: 14, canvas: 18)
        searchOptions.menu = searchOptionsMenu(); searchOptions.setAccessibilityLabel("Search options")
        searchOptions.toolTip = "Search options: current folder, subfolders, and stop search"
        searchOptionsWidth = searchOptions.widthAnchor.constraint(equalToConstant: 132); searchOptionsWidth?.isActive = true
        closeSearchButton = ActionButton(symbol: "xmark", tooltip: "Close search") { [weak self] in self?.closeSearch() }
        closeSearchButton.contentTintColor = .systemBlue
        closeSearchWidth = closeSearchButton.constraints.first { $0.firstAttribute == .width }
        let left = NSStackView(views: [new, separator(), cut, copy, paste, rename, move, trash, separator(), undo, cancel, separator(), sortPicker, viewPicker, searchOptions, closeSearchButton!]); left.spacing = 4
        bar.onLayout = { [weak self, weak bar] in self?.layoutSearchTools(width: bar?.bounds.width ?? 0) }
        pinButton = ActionButton(symbol: "pin", tooltip: "Pin current folder (⌘D)") { [weak self] in self?.togglePin() }
        dualButton = ActionButton(symbol: "rectangle.split.2x1", tooltip: "Toggle dual panes (⇧⌘D)") { [weak self] in self?.workspace?.toggleDualPane() }
        copyOtherButton = ActionButton(symbol: "doc.on.doc.fill", tooltip: "Copy selection to other pane (⌃⇧C)") { [weak self] in self?.transferToOtherPane(move: false) }
        moveOtherButton = ActionButton(symbol: "arrow.left.arrow.right", tooltip: "Move selection to other pane (⌃⇧M)") { [weak self] in self?.transferToOtherPane(move: true) }
        copyOtherButton.isHidden = true; moveOtherButton.isHidden = true
        let right = NSStackView(views: [copyOtherButton!, moveOtherButton!, previewButton!, pinButton!, dualButton!, hiddenButton!]); right.spacing = 4
        for child in [left, right] { bar.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14), left.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14), right.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -12)
        ])
        return bar
    }
    func separator() -> NSView {
        let line = NSBox(); line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true; line.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return line
    }
    func buildNavigationBar() -> NSView {
        let bar = Surface(); bar.color = Palette.navigation; bar.border = true
        backButton = ActionButton(symbol: "arrow.left", tooltip: "Back (⌘[ or ⌥←)") { [weak self] in self?.goBack() }
        forwardButton = ActionButton(symbol: "arrow.right", tooltip: "Forward (⌘] or ⌥→)") { [weak self] in self?.goForward() }
        upButton = ActionButton(symbol: "arrow.up", tooltip: "Parent folder (⌘↑ or ⌥↑)") { [weak self] in self?.goUp() }
        let refresh = ActionButton(symbol: "arrow.clockwise", tooltip: "Refresh (⌘R or F5)") { [weak self] in self?.refresh() }
        let buttons = NSStackView(views: [backButton, forwardButton, upButton, refresh]); buttons.spacing = 2
        search.onChange = { [weak self] in self?.searchQueryChanged() }
        search.onSubmit = { [weak self] in self?.submitSearch() }
        search.onClear = { [weak self] in self?.closeSearch(focusFiles: false) }
        for child in [buttons, pathBar, search] { bar.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8), buttons.topAnchor.constraint(equalTo: bar.topAnchor, constant: 10),
            pathBar.leadingAnchor.constraint(equalTo: buttons.trailingAnchor, constant: 7), pathBar.topAnchor.constraint(equalTo: bar.topAnchor, constant: 8), pathBar.heightAnchor.constraint(equalToConstant: 34),
            search.heightAnchor.constraint(equalToConstant: 34),
            search.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10)
        ])
        navigationWide = [search.leadingAnchor.constraint(equalTo: pathBar.trailingAnchor, constant: 10), search.widthAnchor.constraint(equalToConstant: 260), search.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor)]
        navigationNarrow = [pathBar.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10), search.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10), search.topAnchor.constraint(equalTo: pathBar.bottomAnchor, constant: 5)]
        configureNavigation(compact: false)
        return bar
    }
    func configureNavigation(compact: Bool) {
        guard compactNavigation != compact else { return }
        NSLayoutConstraint.deactivate(navigationWide + navigationNarrow)
        NSLayoutConstraint.activate(compact ? navigationNarrow : navigationWide); compactNavigation = compact
    }
    func buildFooter() -> NSView {
        let bar = Surface(); bar.color = .controlBackgroundColor
        for label in [status, detail] { label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor; label.lineBreakMode = .byTruncatingMiddle }
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        for child in [progress, status, detail] { bar.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            progress.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10), progress.centerYAnchor.constraint(equalTo: bar.centerYAnchor), progress.widthAnchor.constraint(equalToConstant: 14), progress.heightAnchor.constraint(equalToConstant: 14),
            status.leadingAnchor.constraint(equalTo: progress.trailingAnchor, constant: 7), status.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            detail.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16), detail.centerYAnchor.constraint(equalTo: bar.centerYAnchor), status.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -15)
        ])
        return bar
    }

    func buildFileTable() {
        detailsHeaderView = table.headerView
        tableScroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(contentTableResized(_:)), name: NSView.frameDidChangeNotification, object: tableScroll.contentView)
        table.rowHeight = 29; table.floatsGroupRows = false; table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .controlBackgroundColor; table.usesAlternatingRowBackgroundColors = false
        table.style = .plain; table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true; table.allowsEmptySelection = true; table.allowsTypeSelect = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        table.target = self; table.doubleAction = #selector(doubleClick)
        table.setAccessibilityLabel("Files in current folder")
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        for (key, title, width) in [("name", "Name", 385.0), ("modified", "Date modified", 185.0), ("kind", "Type", 140.0), ("size", "Size", 85.0), ("location", "Folder", 180.0), ("created", "Date created", 185.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title; column.width = width; column.minWidth = key == "name" ? 160 : 60
            column.headerCell.font = .systemFont(ofSize: 11)
            if key != "location" { column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true) }
            column.isHidden = key == "location" || key == "created"
            if key == "size" { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        // Set the restored order before installing the delegate: initialization
        // must not report a user sort change and overwrite this tab's settings.
        table.sortDescriptors = [NSSortDescriptor(key: tab.sort.key.rawValue, ascending: tab.sort.ascending)]
        table.dataSource = self; table.delegate = self
        table.onOpen = { [weak self] in self?.openSelected() }
        table.onBack = { [weak self] in self?.goBack() }
        table.onPreview = { [weak self] in self?.toggleQuickLook() }
        table.onFileAction = { [weak self] in self?.performFileAction($0) }
        table.canFileAction = { [weak self] in self?.canPerformFileAction($0) == true }
        let menu = NSMenu(); menu.delegate = self; table.menu = menu
        tableScroll.documentView = table; tableScroll.hasVerticalScroller = true; tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true; tableScroll.drawsBackground = true; tableScroll.backgroundColor = .controlBackgroundColor
    }
    func buildFileArea() -> NSView {
        let area = FolderDropSurface(); area.color = .controlBackgroundColor
        area.dropDestination = { [weak self] in self?.folderDestination }
        for scroll in [tableScroll, collectionScroll, thisMacView] {
            scroll.translatesAutoresizingMaskIntoConstraints = false; area.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: area.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: area.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: area.topAnchor), scroll.bottomAnchor.constraint(equalTo: area.bottomAnchor)
            ])
        }
        let image = NSImageView(image: Palette.symbol("folder", size: 34) ?? NSImage()); image.contentTintColor = .tertiaryLabelColor
        emptyTitle.font = .systemFont(ofSize: 18, weight: .medium); emptyTitle.alignment = .center
        emptyDescription.font = .systemFont(ofSize: 12); emptyDescription.textColor = .secondaryLabelColor; emptyDescription.alignment = .center
        let open = ActionButton("Choose a folder…", symbol: "folder", tooltip: "Choose a folder") { [weak self] in self?.chooseFolder() }
        emptyStack.orientation = .vertical; emptyStack.spacing = 13
        [image, emptyTitle, emptyDescription, open].forEach { emptyStack.addArrangedSubview($0) }
        emptyStack.translatesAutoresizingMaskIntoConstraints = false; area.addSubview(emptyStack)
        NSLayoutConstraint.activate([emptyStack.centerXAnchor.constraint(equalTo: area.centerXAnchor), emptyStack.centerYAnchor.constraint(equalTo: area.centerYAnchor), emptyStack.widthAnchor.constraint(lessThanOrEqualTo: area.widthAnchor, constant: -70), emptyDescription.widthAnchor.constraint(lessThanOrEqualToConstant: 400)])
        emptyStack.isHidden = true
        return area
    }

    func title(for url: URL) -> String {
        if BrowserLocation.isThisMac(url) { return "This Mac" }
        if url.path == FileManager.default.homeDirectoryForCurrentUser.path { return "Home" }
        if url.path == "/" { return "Macintosh HD" }
        return url.lastPathComponent
    }
    func updateChrome() {
        guard isViewLoaded else { return }
        for id in Array(tabChips.keys) where !tabs.contains(where: { $0.id == id }) {
            tabChips.removeValue(forKey: id)?.removeFromSuperview()
        }
        for (index, tab) in tabs.enumerated() {
            let chip = tabChips[tab.id] ?? BrowserTabView(id: tab.id, title: title(for: tab.history.current), active: index == activeIndex,
                select: { [weak self] in self?.activateTab(id: tab.id) }, close: { [weak self] in self?.closeTab(id: tab.id) })
            chip.browser = self
            chip.update(title: tabTitle(tab), active: index == activeIndex)
            chip.setOverviewIcon(tab.isThisMac)
            chip.dropDestination = { [weak tab] in guard let tab, !tab.isThisMac, !tab.isRecursiveSearch else { return nil }; return tab.history.current }
            chip.onDragHover = { [weak self] in self?.activateTab(id: tab.id) }
            if tabChips[tab.id] == nil { tabsDocument.addSubview(chip); tabChips[tab.id] = chip }
        }
        tabStripWidth?.constant = CGFloat(tabs.count) * 216
        tabsDocument.setAccessibilityChildren(tabs.compactMap { tabChips[$0.id] })
        layoutTabStrip()
        tabsDocument.scrollToVisible(NSRect(x: CGFloat(activeIndex) * 216, y: 0, width: 212, height: tabsDocument.bounds.height))
        pathBar.update(tab.history.current)
        search.stringValue = tab.query
        backButton.isEnabled = canGoBack; forwardButton.isEnabled = canGoForward; upButton.isEnabled = canGoUp
        hiddenButton.active = showHidden
        let wasSuppressed = suppressSelection
        suppressSelection = true
        table.sortDescriptors = [NSSortDescriptor(key: tab.sort.key.rawValue, ascending: tab.sort.ascending)]
        suppressSelection = wasSuppressed
        workspace?.updateWindowTitle(); workspace?.syncSidebar(from: self)
        updateSearchControls(); favoritesChanged()
        applyPresentationMode(); updateStatus()
    }

    func layoutTabStrip() {
        let nativeHeight = tabBar?.bounds.height ?? 0
        let height = nativeHeight > 0 ? nativeHeight : 44
        let chipHeight = min(38, max(0, height - 6))
        // Tabs sit below top padding; center the + on their bodies, not the row.
        if newTabCenterY?.constant != -chipHeight / 2 { newTabCenterY?.constant = -chipHeight / 2 }
        for (index, tab) in tabs.enumerated() {
            tabChips[tab.id]?.frame = NSRect(x: CGFloat(index) * 216, y: height - chipHeight, width: 212, height: chipHeight)
        }
        tabsDocument.frame = NSRect(x: 0, y: 0, width: CGFloat(tabs.count) * 216, height: height)
    }

    func rememberSelection() {
        guard isViewLoaded, !tab.isThisMac else { return }
        if tab.pendingSelections[tab.selectionKey] == nil {
            tab.selections[tab.selectionKey] = Set(selectedItems.map(\.id))
        }
        tab.scrollPositions[scrollKey] = activeScroll.contentView.bounds.origin.y
    }
    var selectedIndexes: IndexSet {
        tab.isThisMac ? [] : viewMode.usesTable ? IndexSet(table.selectedRowIndexes.compactMap { tab.displayIndex.item(atRow: $0) }) : IndexSet(collection.selectionIndexPaths.compactMap { tab.displayIndex.item(section: $0.section, offset: $0.item) })
    }
    var selectedItems: [FileItem] { selectedIndexes.compactMap { tab.visible.indices.contains($0) ? tab.visible[$0] : nil } }

    func newTab(url: URL? = nil) {
        workspace?.activate(self)
        rememberSelection(); tab.searchTask?.cancel(); tab.loadTask?.cancel(); tab.sortTask?.cancel()
        tabs.append(BrowserTab(url: url ?? tab.history.current)); activeIndex = tabs.count - 1
        updateChrome(); loadFolder(clear: true); saveSession(); view.window?.makeFirstResponder(activeFileView)
    }
    func activateTab(id: UUID) {
        workspace?.activate(self)
        guard let index = tabs.firstIndex(where: { $0.id == id }), index != activeIndex else { return }
        workspace?.activate(self)
        rememberSelection(); tab.searchTask?.cancel(); tab.loadTask?.cancel(); tab.sortTask?.cancel(); activeIndex = index
        suppressSelection = true
        table.sortDescriptors = [NSSortDescriptor(key: tab.sort.key.rawValue, ascending: tab.sort.ascending)]
        suppressSelection = false
        updateChrome(); loadFolder(clear: true); saveSession(); view.window?.makeFirstResponder(activeFileView)
    }
    func cycleTab(_ direction: Int) {
        guard tabs.count > 1 else { return }
        activateTab(id: tabs[(activeIndex + direction + tabs.count) % tabs.count].id)
    }
    func closeActiveTab() { closeTab(id: tab.id) }
    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count == 1 { saveSession(); onCloseWindow?(); return }
        rememberSelection(); tabs[index].searchTask?.cancel(); tabs[index].loadTask?.cancel(); tabs[index].sortTask?.cancel()
        let activeID = tab.id; tabs.remove(at: index)
        if activeID == id {
            activeIndex = min(index, tabs.count - 1)
            updateChrome(); loadFolder(clear: true)
        } else { activeIndex = tabs.firstIndex(where: { $0.id == activeID })!; updateChrome() }
        saveSession()
    }
    func saveSession() { workspace?.saveSession() }
    func navigate(_ url: URL) {
        rememberSelection(); tab.history.visit(url); tab.query = ""
        updateChrome(); loadFolder(clear: true); saveSession()
        view.window?.makeFirstResponder(activeFileView)
    }
    func goBack() {
        guard canGoBack else { return }; rememberSelection(); tab.history.back(); tab.query = ""
        updateChrome(); loadFolder(clear: true); saveSession()
        view.window?.makeFirstResponder(activeFileView)
    }
    func goForward() {
        guard canGoForward else { return }; rememberSelection(); tab.history.forward(); tab.query = ""
        updateChrome(); loadFolder(clear: true); saveSession()
        view.window?.makeFirstResponder(activeFileView)
    }
    func goUp() {
        guard !tab.isThisMac else { return }
        if tab.history.current.path == "/" || StorageStore.shared.locations.contains(where: { $0.url == tab.history.current }) { navigate(BrowserLocation.thisMac) }
        else if let parent = tab.history.parent { navigate(parent) }
    }
    func editPath() { pathBar.beginEditing() }
    func focusFilter() { search.focus() }
    func refresh(clearThumbnails: Bool = true) {
        if tab.isThisMac { StorageStore.shared.refresh(); return }
        rememberSelection(); iconCache.removeAllObjects()
        if clearThumbnails { ThumbnailStore.shared.invalidateCache() }
        loadFolder(clear: false)
    }
    func toggleHidden() {
        guard !tab.isThisMac else { return }
        AppPreferences.shared.showHidden = !showHidden
        applyHiddenPreference()
    }
    func applyHiddenPreference() {
        guard showHidden != AppPreferences.shared.showHidden else { return }
        guard isViewLoaded else { showHidden = AppPreferences.shared.showHidden; return }
        rememberSelection(); showHidden = AppPreferences.shared.showHidden
        hiddenButton.active = showHidden; workspace?.refreshSidebar(from: self)
        guard !tab.isThisMac else { return }
        if tab.isRecursiveSearch { startSearch() } else { applyView() }
    }
    func copySelectedPaths() {
        if tab.isThisMac { thisMacView.copyPath(); return }
        let paths = selectedItems.isEmpty ? [tab.history.current.path] : selectedItems.map { $0.url.path }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        status.stringValue = paths.count == 1 ? "Path copied" : "\(paths.count) paths copied"
    }
    func chooseFolder() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.directoryURL = tab.isThisMac ? FileManager.default.homeDirectoryForCurrentUser : tab.history.current; panel.prompt = "Open folder"
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.navigate(url) }
        }
    }
    func openExternal(_ url: URL) {
        Task { [weak self] in
            let isDirectory = await Task.detached { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.value
            guard let self else { return }
            self.newTab(url: isDirectory ? url : url.deletingLastPathComponent())
        }
    }

    func loadFolder(clear: Bool) {
        if tab.isThisMac { loadThisMac(); return }
        if tab.isRecursiveSearch { startSearch(); return }
        cancelSearchWork()
        updateSearchControls(); applyPresentationMode()
        let tab = self.tab, url = tab.history.current
        tab.loadTask?.cancel(); tab.sortTask?.cancel(); refreshTask?.cancel()
        tab.generation = UUID(); let generation = tab.generation
        tab.error = nil; tab.loading = true; tab.changedDuringLoad = false
        // Attach without blocking the UI; the watcher reconciles once it is ready.
        if watcherURL != url || watcherTabID != tab.id || watcher?.needsRetry == true {
            watcherURL = url; watcherTabID = tab.id
            watcher = DirectoryWatcher(url: url) { [weak self, weak tab] in
                guard let self, let tab, self.tab === tab else { return }
                if tab.loading { tab.changedDuringLoad = true }
                else { self.scheduleRefresh() }
            }
        }
        if clear {
            tab.items = []; tab.clearVisible(); suppressSelection = true; table.reloadData(); table.deselectAll(nil)
            cancelVisibleThumbnails(); collection.reloadData(); collection.selectionIndexPaths = []
            activeScroll.contentView.scroll(to: .zero); suppressSelection = false; updateQuickLookSelection()
        }
        updateStatus(); updateEmptyState()
        tab.loadTask = Task { [weak self, weak tab] in
            let worker = Task.detached(priority: .userInitiated) { try FileSystem.validateDirectory(url); return try FileSystem.list(url) }
            do {
                let items = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self, let tab, tab.generation == generation, self.tab === tab else { return }
                tab.items = items; tab.loading = false
                self.applyView()
                if tab.changedDuringLoad { self.scheduleRefresh() }
            } catch {
                guard !Task.isCancelled, let self, let tab, tab.generation == generation, self.tab === tab else { return }
                tab.loading = false; tab.items = []; tab.clearVisible(); tab.error = error.localizedDescription
                self.suppressSelection = true; self.cancelVisibleThumbnails(); self.table.reloadData(); self.collection.reloadData(); self.suppressSelection = false
                self.updateStatus(); self.updateEmptyState(); self.updateQuickLookSelection()
            }
        }
    }
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }; self?.refresh(clearThumbnails: false)
        }
    }
    func applyView() {
        let tab = self.tab
        tab.sortTask?.cancel(); tab.sortGeneration = UUID(); let generation = tab.sortGeneration
        let grouping = tab.grouping
        let items = tab.items, sort = tab.sort, query = tab.isRecursiveSearch ? "" : tab.query, hidden = showHidden
        tab.sortTask = Task { [weak self, weak tab] in
            let worker = Task.detached(priority: .userInitiated) { grouping.sections(from: sort.apply(to: items, query: query, showHidden: hidden)) }
            let groups = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, let tab, self.tab === tab, tab.sortGeneration == generation else { return }
            tab.groups = groups; tab.visible = groups.flatMap(\.items)
            self.reloadFilePresentation(selected: tab.selections[tab.selectionKey] ?? [], pending: tab.pendingSelections[tab.selectionKey])
        }
    }
    func updateStatus() {
        updateSearchMenuState()
        updateTransferButtons()
        if let workspace, workspace.activeBrowser !== self { workspace.activeBrowser.updateTransferButtons() }
        previewButton?.isEnabled = canQuickLook
        for (action, button) in operationButtons { button.isEnabled = canPerformFileAction(action) }
        operationButtons[.paste]?.toolTip = operations.cutPaths.isEmpty ? "Paste copies (⌘V or Ctrl+V)" : "Paste moves cut items (⌘V or Ctrl+V)"
        operationButtons[.undo]?.toolTip = operations.undoTitle.map { "Undo \($0) (⌘Z or Ctrl+Z)" } ?? "Nothing to undo"
        if operations.busy {
            progress.startAnimation(nil); status.stringValue = operations.statusText
            detail.stringValue = "Escape to cancel"; return
        }
        if tab.isThisMac {
            if StorageStore.shared.refreshing { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
            status.stringValue = "\(thisMacView.itemCount) locations" + (thisMacView.selectedLocation == nil ? "" : " · 1 selected")
            detail.stringValue = StorageStore.shared.refreshing ? "Updating storage…" : "This Mac"
            return
        }
        if tab.isRecursiveSearch {
            updateSearchStatus(); return
        }
        if tab.loading { progress.startAnimation(nil); status.stringValue = "Loading \(title(for: tab.history.current))…" }
        else {
            progress.stopAnimation(nil)
            let count = tab.visible.count.formatted()
            let selected = selectedItems
            status.stringValue = "\(count) \(tab.visible.count == 1 ? "item" : "items")"
            if !tab.query.isEmpty { status.stringValue += " matching \"\(tab.query)\"" }
            if !selected.isEmpty {
                status.stringValue += "  ·  \(selected.count) selected"
                let sizes = selected.compactMap(\.size)
                if sizes.count == selected.count { status.stringValue += "  ·  " + ByteCountFormatter.string(fromByteCount: sizes.reduce(0, +), countStyle: .file) }
            }
            if tab.error != nil { status.stringValue = "Folder unavailable" }
        }
        detail.stringValue = operations.statusText.isEmpty ? (viewMode.title + (showHidden ? " · Hidden files" : "")) : operations.statusText
    }
    func updateEmptyState() {
        if tab.isThisMac { emptyStack.isHidden = true; return }
        emptyStack.isHidden = !tab.visible.isEmpty || tab.loading
        if let error = tab.error {
            emptyTitle.stringValue = "This folder couldn’t be opened"
            emptyDescription.stringValue = error + "\nChoose another folder or check its access permissions."
        } else if tab.isRecursiveSearch {
            emptyTitle.stringValue = tab.searchStopped ? "Search stopped" : "No matching files"
            emptyDescription.stringValue = "Search names in this folder and its subfolders. Try a different name or clear the search."
        } else if !tab.query.isEmpty {
            emptyTitle.stringValue = "No matching files"; emptyDescription.stringValue = "Try another name or clear the folder filter."
        } else {
            emptyTitle.stringValue = "This folder is empty"; emptyDescription.stringValue = showHidden ? "There are no items in this folder." : "There are no visible items in this folder."
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tab.displayIndex.rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tab.displayIndex.rows.indices.contains(row), case let .header(section) = tab.displayIndex.rows[row] { return makeGroupHeader(section: section) }
        guard let column = tableColumn, let item = file(atRow: row) else { return nil }
        if viewMode == .content {
            let cell = (tableView.makeView(withIdentifier: ContentResultCell.identifier, owner: self) as? ContentResultCell) ?? ContentResultCell()
            let key = FileColors.cacheKey(item)
            let icon = iconCache.object(forKey: key) ?? FileColors.icon(item)
            iconCache.setObject(icon, forKey: key)
            cell.configure(item, query: tab.query, icon: icon, modified: item.modified.map(dateFormatter.string) ?? "—",
                           dimmed: operations.cutPaths.contains(FileOperationController.itemPath(item.url)),
                           onReveal: { [weak self] in self?.revealInContainingFolder(item.url) })
            return cell
        }
        let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView) ?? makeCell(column.identifier)
        switch column.identifier.rawValue {
        case "name":
            if let label = cell.textField { SearchHighlight.apply(item.name, to: label, query: tab.query) }
            let key = FileColors.cacheKey(item)
            if let cached = iconCache.object(forKey: key) { cell.imageView?.image = cached }
            else {
                let icon = FileColors.icon(item)
                iconCache.setObject(icon, forKey: key); cell.imageView?.image = icon
            }
            cell.alphaValue = operations.cutPaths.contains(FileOperationController.itemPath(item.url)) ? 0.35 : (item.isHidden ? 0.6 : 1)
        case "location":
            if let label = cell.textField as? FolderLocationLink {
                label.configure(DirectorySearch.location(of: item.url, relativeTo: tab.history.current),
                                query: tab.query, file: item.url, onOpen: { [weak self] in self?.revealInContainingFolder(item.url) })
            }
        case "modified": cell.textField?.stringValue = item.modified.map(dateFormatter.string) ?? "—"
        case "created": cell.textField?.stringValue = item.created.map(dateFormatter.string) ?? "—"
        case "kind": cell.textField?.stringValue = item.kind
        case "size": cell.textField?.stringValue = item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        default: break
        }
        cell.toolTip = column.identifier.rawValue == "name" ? [item.url.path, FileColors.description(item.finderColors)].filter { !$0.isEmpty }.joined(separator: "\n") : cell.textField?.stringValue
        return cell
    }
    func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView(); cell.identifier = identifier
        let label = identifier.rawValue == "location" ? FolderLocationLink() : NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingMiddle
        label.textColor = identifier.rawValue == "name" ? .labelColor : .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false; cell.textField = label; cell.addSubview(label)
        var leading = cell.leadingAnchor
        if identifier.rawValue == "name" {
            let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false; cell.imageView = icon; cell.addSubview(icon)
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18)])
            leading = icon.trailingAnchor
        }
        if identifier.rawValue == "size" { label.alignment = .right }
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leading, constant: 9), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if !suppressSelection { rememberSelection(); updateStatus(); updateQuickLookSelection() } }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard isViewLoaded, !suppressSelection, let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key.flatMap(FileSortKey.init(rawValue:)) else { return }
        rememberSelection(); tab.sort = FileSort(key: key, ascending: descriptor.ascending); updateSortPresentation(); applyView(); saveSession()
    }
    func searchQueryChanged() {
        if tab.isThisMac { tab.query = search.stringValue; updateSearchControls(); storageChanged(); return }
        rememberSelection(); tab.query = search.stringValue
        if !tab.query.isEmpty { tab.scrollPositions[scrollKey] = 0 }
        if tab.isRecursiveSearch { startSearch(debounce: true) }
        else if tab.searchScope == .subfolders { loadFolder(clear: true) }
        else { applyPresentationMode(); updateSearchControls(); applyView() }
    }
    @objc private func doubleClick() {
        guard file(atRow: table.clickedRow) != nil else { return }
        openSelected(inNewTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }
    func openSelected(inNewTab: Bool = false) {
        guard let item = selectedItems.first else { return }
        if item.isNavigable {
            if inNewTab { newTab(url: item.url) } else { navigate(item.url) }
        } else { NSWorkspace.shared.open(item.url) }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if viewMode.usesTable, file(atRow: table.clickedRow) != nil, !table.selectedRowIndexes.contains(table.clickedRow) {
            table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        } else if viewMode.usesTable, file(atRow: table.clickedRow) == nil { table.deselectAll(nil) }
        populateContextMenu(menu)
    }
    func populateContextMenu(_ menu: NSMenu) {
        ContextMenu.configure(menu)
        let items = selectedItems
        ContextMenu.addFileActions(to: menu, enabled: canPerformFileAction) { [weak self] in self?.performFileAction($0) }
        func add(_ title: String, _ symbol: String, _ action: @escaping () -> Void) {
            menu.addItem(ContextMenu.item(title, symbol: symbol, action: action))
        }
        if let item = items.first {
            add("Open", item.isNavigable ? "folder" : "doc") { [weak self] in self?.contextOpen() }
            if items.count == 1, item.isNavigable {
                add("Open in New Tab", "plus.square.on.square") { [weak self] in self?.contextNewTab() }
                add("Open in New Window", "macwindow.badge.plus") { (NSApp.delegate as? AppDelegate)?.newWindow(urls: [item.url]) }
                add("Open in Other Pane", "rectangle.split.2x1") { [weak self] in self?.openSelectedInOtherPane() }
                menu.addItem(.separator())
                add(FavoriteStore.shared.favorites.contains(item.url) ? "Unpin from Favorites" : "Pin to Favorites", "pin") { [weak self] in self?.pinSelectedFolder() }
            }
            if items.count == 1, item.isPackage { add("Show Package Contents", "shippingbox") { [weak self] in self?.contextPackage() } }
            if tab.isRecursiveSearch { add("Open Containing Folder", "folder") { [weak self] in self?.openContainingFolder() } }
            add("Quick Look", "eye") { [weak self] in self?.contextPreview() }
            if let window = view.window { menu.addItem(FileColorMenu.shared.item(urls: items.map(\.url), summaries: items.map(\.finderColors), window: window)) }
            add("Copy as Path", "link") { [weak self] in self?.contextCopy() }
            menu.addItem(.separator())
        }
        for action in [FileAction.move, .newFolder, .undo] {
            let title = action == .undo ? operations.undoTitle.map { "Undo \($0)" } ?? "Undo" : action.title
            menu.addItem(ContextMenu.item(title, symbol: action.menuSymbol, enabled: canPerformFileAction(action)) { [weak self] in self?.performFileAction(action) })
        }
        let terminalFolder = ExternalApplications.terminalDirectory(items: items, currentFolder: tab.history.current)
        let canEdit = ExternalApplications.canEdit(items)
        if terminalFolder != nil || canEdit {
            menu.addItem(.separator())
            if let folder = terminalFolder { menu.addItem(ExternalApplications.terminalItem(folder: folder, window: view.window, containing: items.first.map { !$0.isNavigable } ?? false)) }
            if canEdit {
                let urls = items.map(\.url)
                add(ExternalApplications.editorTitle(for: urls), "square.and.pencil") { [weak self] in ExternalApplications.openEditor(files: urls, window: self?.view.window) }
            }
        }
    }

    var fileListHasFocus: Bool { view.window?.firstResponder === activeFileView }
    func handleFileShortcut(_ event: NSEvent) -> Bool {
        guard fileListHasFocus, view.window?.attachedSheet == nil else { return false }
        if tab.isThisMac { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let character = event.charactersIgnoringModifiers?.lowercased()
        var action: FileAction?
        if flags == .control {
            switch character {
            case "c": action = .copy
            case "x": action = .cut
            case "v": action = .paste
            case "z": action = .undo
            case "a": if viewMode.usesTable { table.selectAll(nil) } else { collection.selectAll(nil) }; return true
            default: break
            }
        }
        if flags == [.control, .shift], let mode = FileViewMode.allCases.first(where: { $0.shortcutNumber == event.characters(byApplyingModifiers: []) }) {
            setViewMode(mode); return true
        }
        if flags == [.command], let character {
            let modes: [String: FileViewMode] = ["1": .details, "2": .medium, "3": .large, "4": .extraLarge, "5": .content]
            if let mode = modes[character] { setViewMode(mode); return true }
        }
        if flags == [.control, .shift], character == "c" { transferToOtherPane(move: false); return true }
        if flags == [.control, .shift], character == "m" { transferToOtherPane(move: true); return true }
        if flags.isEmpty, event.keyCode == 53, tab.searchTask != nil { stopSearch(); return true }
        if flags == [.control, .shift], character == "n" { action = .newFolder }
        if flags.isEmpty {
            if event.keyCode == 49 { toggleQuickLook(); return true }
            if event.keyCode == 120 { action = .rename } // F2
            if event.keyCode == 117 { action = .trash } // Forward Delete / Fn-Backspace
            if event.keyCode == 53 { action = .cancel }
        }
        if let action { performFileAction(action); return true }
        return false
    }
    func canPerformFileAction(_ action: FileAction) -> Bool {
        if action == .cancel { return operations.busy || !operations.cutPaths.isEmpty }
        guard !operations.busy else { return false }
        switch action {
        case .copy, .cut, .move, .trash: return !selectedItems.isEmpty
        case .rename: return selectedItems.count == 1
        case .newFolder: return folderDestination != nil
        case .paste: return folderDestination != nil && operations.canPaste
        case .undo: return operations.undoTitle != nil
        case .cancel: return false
        }
    }
    func performFileAction(_ action: FileAction) {
        guard let window = view.window, window.attachedSheet == nil, canPerformFileAction(action) else { return }
        let urls = selectedItems.map(\.url), folder = tab.history.current
        switch action {
        case .copy: operations.copy(urls, cut: false)
        case .cut: operations.copy(urls, cut: true)
        case .paste: operations.paste(into: folder, window: window)
        case .undo: operations.undo(window: window)
        case .cancel: operations.cancel()
        case .trash: operations.run(.trash(urls), window: window)
        case .rename:
            guard let item = selectedItems.first else { return }
            operations.askName(title: "Rename", initial: item.name, selectStem: !item.isDirectory, window: window) { [weak self] name in
                self?.operations.run(.rename(item.url, to: name), window: window)
            }
        case .newFolder:
            var name = "New folder", index = 2
            let names = Set(tab.items.map { $0.name.lowercased() })
            while names.contains(name.lowercased()) { name = "New folder (\(index))"; index += 1 }
            operations.askName(title: "New Folder", initial: name, selectStem: false, window: window) { [weak self] name in
                self?.operations.run(.newFolder(in: folder, name: name), window: window)
            }
        case .move:
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
            panel.directoryURL = folder; panel.prompt = "Move here"; panel.message = "Choose the destination for \(urls.count) selected item(s)."
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let target = panel.url { self?.operations.run(.move(urls, to: target), window: window) }
            }
        }
    }
    @objc private func operationsChanged() {
        guard isViewLoaded else { return }
        if viewMode.usesTable, table.numberOfRows > 0 { table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows), columnIndexes: IndexSet(integer: 0)) }
        if !viewMode.usesTable { configureVisibleIcons() }
        updateStatus()
    }
    @objc private func operationsFinished(_ notification: Notification) {
        guard isViewLoaded else { return }
        if tab.isThisMac { StorageStore.shared.refresh(); return }
        if let workspace, workspace.right === self, !workspace.dualPane { return }
        rememberSelection()
        if tab.isRecursiveSearch {
            startSearch(); workspace?.refreshSidebar(from: self); return
        }
        if notification.userInfo?["metadataOnly"] as? Bool != true, let urls = notification.userInfo?["completed"] as? [URL] {
            let current = tab.history.current.resolvingSymlinksInPath().path
            let children = urls.filter { $0.deletingLastPathComponent().resolvingSymlinksInPath().path == current }
            if !children.isEmpty {
                tab.pendingSelections[tab.selectionKey] = Set(children.map(FileOperationController.itemPath))
                // New and renamed files must not disappear behind the current filter.
                tab.query = ""; search.stringValue = ""
            }
        }
        iconCache.removeAllObjects(); workspace?.refreshSidebar(from: self)
        loadFolder(clear: false)
    }
    @objc private func contextOpen() { openSelected() }
    @objc private func contextNewTab() { openSelected(inNewTab: true) }
    @objc private func contextPackage() { if let item = selectedItems.first { navigate(item.url) } }
    @objc private func contextCopy() { copySelectedPaths() }
}
