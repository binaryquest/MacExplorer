import AppKit
import ExplorerCore

@MainActor
final class WorkspaceViewController: NSViewController, NSSplitViewDelegate {
    var left: BrowserViewController
    var right: BrowserViewController?
    private(set) var activeBrowser: BrowserViewController
    private(set) var dualPane: Bool
    let sidebar = FolderSidebar()
    let titlebarTabs = TitlebarSurface()
    private let outer = ExplorerSplitView()
    private let panes = ExplorerSplitView()
    private let toolbar = Surface()
    private let headers = Surface()
    private var headersHeight: NSLayoutConstraint!
    private var headersTop: NSLayoutConstraint!
    private var titlebarInContent = false
    private var displayedToolbar: NSView?
    private let restoreRight: Bool
    private var ready = false

    init(session: WorkspaceSession, initialBrowser: BrowserViewController? = nil) {
        let session = session.sanitized
        left = initialBrowser ?? BrowserViewController(session: session.left)
        right = session.right.map { BrowserViewController(session: $0) }
        activeBrowser = left; dualPane = session.dualPane; restoreRight = session.activeRight
        super.init(nibName: nil, bundle: nil)
        configure(left); if let right { configure(right) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func configure(_ browser: BrowserViewController) {
        browser.workspace = self
        browser.onCloseWindow = { [weak self, weak browser] in
            guard let self, let browser else { return }; self.closePane(browser)
        }
    }
    override func loadView() {
        view = Surface(frame: NSRect(x: 0, y: 0, width: 1160, height: 760))
        toolbar.color = .controlBackgroundColor
        headers.color = Palette.chrome
        titlebarTabs.color = Palette.chrome
        titlebarTabs.onLayout = { [weak self] in self?.layoutTitlebarTabs() }
        (view as? Surface)?.onLayout = { [weak self] in self?.updateTitlebarLayout() }
        outer.isVertical = true; outer.dividerStyle = .thin; outer.delegate = self
        panes.isVertical = true; panes.dividerStyle = .thin; panes.delegate = self
        addChild(sidebar)
        sidebar.onNavigate = { [weak self] in self?.activeBrowser.navigate($0) }
        sidebar.onNewTab = { [weak self] in self?.activeBrowser.newTab(url: $0) }
        sidebar.onOtherPane = { [weak self] in self?.openOtherPane($0) }
        outer.addArrangedSubview(sidebar.view); outer.addArrangedSubview(panes)
        addChild(left); panes.addArrangedSubview(left.view)
        if let right, dualPane { addChild(right); panes.addArrangedSubview(right.view) }
        for child in [headers, toolbar, outer] { view.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        headersTop = headers.topAnchor.constraint(equalTo: view.topAnchor, constant: 32)
        NSLayoutConstraint.activate([
            headersTop, headers.leadingAnchor.constraint(equalTo: view.leadingAnchor), headers.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: headers.bottomAnchor), toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor), toolbar.heightAnchor.constraint(equalToConstant: 47),
            outer.topAnchor.constraint(equalTo: toolbar.bottomAnchor), outer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            outer.leadingAnchor.constraint(equalTo: view.leadingAnchor), outer.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        headersHeight = headers.heightAnchor.constraint(equalToConstant: dualPane ? 90 : 54); headersHeight.isActive = true
        headers.onLayout = { [weak self] in self?.layoutHeaders() }
        ready = true; syncHeaders()
        activate(restoreRight && dualPane ? right! : left, force: true)
    }
    override func viewDidAppear() {
        super.viewDidAppear(); updateMinimumSize()
        outer.setPosition(210, ofDividerAt: 0)
        if dualPane { panes.setPosition(panes.bounds.width / 2, ofDividerAt: 0) }
        activate(activeBrowser, force: true); view.window?.makeFirstResponder(activeBrowser.activeFileView)
    }
    func activate(_ browser: BrowserViewController, force: Bool = false) {
        guard ready, browser === left || (dualPane && browser === right), force || activeBrowser !== browser else { return }
        if activeBrowser !== browser { activeBrowser.closeQuickLook() }
        activeBrowser = browser
        (view.window as? ExplorerWindow)?.browser = browser
        if displayedToolbar !== browser.commandBar {
            displayedToolbar?.removeFromSuperview(); let bar = browser.commandBar!
            toolbar.addSubview(bar); bar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor), bar.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor), bar.topAnchor.constraint(equalTo: toolbar.topAnchor), bar.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor)])
            displayedToolbar = bar
        }
        updatePaneLabels(); syncSidebar(from: browser); browser.updateStatus(); updateWindowTitle(); saveSession()
    }
    func activatePane(containing view: NSView?) {
        guard let view else { return }
        if view === left.view || view.isDescendant(of: left.view) || view === left.headerView || view.isDescendant(of: left.headerView)
            || left.tabBar.map({ view === $0 || view.isDescendant(of: $0) }) == true { activate(left) }
        else if dualPane, let right, view === right.view || view.isDescendant(of: right.view) || view === right.headerView || view.isDescendant(of: right.headerView)
            || right.tabBar.map({ view === $0 || view.isDescendant(of: $0) }) == true { activate(right) }
    }
    func toggleDualPane() {
        guard view.window?.attachedSheet == nil else { return }
        if dualPane {
            dualPane = false
            if let right { right.rememberSelection(); right.suspend(); right.view.removeFromSuperview(); right.headerView.removeFromSuperview(); right.tabBar?.removeFromSuperview() }
            activate(left, force: true)
        } else {
            if right == nil { right = BrowserViewController(urls: [left.tab.history.current], active: 0); configure(right!) }
            dualPane = true
            let right = right!; if right.parent == nil { addChild(right) }
            panes.addArrangedSubview(right.view); right.loadFolder(clear: true)
            updateMinimumSize(); view.layoutSubtreeIfNeeded(); panes.setPosition(panes.bounds.width / 2, ofDividerAt: 0)
            activate(activeBrowser, force: true)
        }
        syncHeaders(); updateMinimumSize(); updatePaneLabels(); saveSession(); view.window?.makeFirstResponder(activeBrowser.activeFileView)
    }
    private func syncHeaders() {
        guard ready else { return }
        headersHeight.constant = dualPane ? 90 : 54
        for browser in [left, dualPane ? right : nil].compactMap({ $0 }) {
            if browser.headerView.superview !== headers { headers.addSubview(browser.headerView) }
            if let tabBar = browser.tabBar, tabBar.superview !== titlebarTabs { titlebarTabs.addSubview(tabBar) }
            // The native accessory already reserves space for the traffic lights.
            browser.tabBarLeading?.constant = 8
            browser.configureNavigation(compact: dualPane)
        }
        headers.needsLayout = true; layoutHeaders()
    }
    private func layoutHeaders() {
        guard ready else { return }
        let rightWidth = dualPane ? (right?.view.frame.width ?? 0) : 0
        let leftWidth = max(0, headers.bounds.width - rightWidth - (dualPane ? panes.dividerThickness : 0))
        left.headerView.frame = NSRect(x: 0, y: 0, width: leftWidth, height: headers.bounds.height)
        if dualPane, let right { right.headerView.frame = NSRect(x: leftWidth + panes.dividerThickness, y: 0, width: rightWidth, height: headers.bounds.height) }
        layoutTitlebarTabs()
    }
    func installTitlebar(in host: NSView) {
        titlebarInContent = false
        titlebarTabs.removeFromSuperview(); host.addSubview(titlebarTabs)
        titlebarTabs.autoresizingMask = [.width, .height]; titlebarTabs.frame = host.bounds
        updateTitlebarLayout()
    }
    func embedTitlebarForFullScreen() {
        titlebarInContent = true
        titlebarTabs.removeFromSuperview(); view.addSubview(titlebarTabs)
        titlebarTabs.autoresizingMask = [.width]
        updateTitlebarLayout()
    }
    func updateTitlebarLayout() {
        guard ready else { return }
        if titlebarInContent { titlebarTabs.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: 44) }
        let inset: CGFloat
        if titlebarInContent { inset = 44 }
        else if titlebarTabs.window != nil, titlebarTabs.window === view.window {
            inset = max(0, view.convert(titlebarTabs.bounds, from: titlebarTabs).maxY)
        } else { inset = 32 }
        if headersTop.constant != inset { headersTop.constant = inset }
        layoutTitlebarTabs()
    }
    private func layoutTitlebarTabs() {
        guard ready else { return }
        let size = titlebarTabs.bounds.size
        let rightWidth = dualPane ? (right?.view.frame.width ?? 0) : 0
        let nativeRightInset: CGFloat = titlebarTabs.window === view.window && view.window != nil
            ? max(0, view.bounds.maxX - view.convert(titlebarTabs.bounds, from: titlebarTabs).maxX) : 0
        let leftWidth = dualPane ? max(0, min(size.width, size.width - rightWidth + nativeRightInset - panes.dividerThickness)) : size.width
        left.tabBar?.frame = NSRect(x: 0, y: 0, width: leftWidth, height: size.height)
        if dualPane, let right {
            right.tabBar?.frame = NSRect(x: leftWidth + panes.dividerThickness, y: 0,
                                        width: max(0, size.width - leftWidth - panes.dividerThickness), height: size.height)
        }
    }
    func splitViewDidResizeSubviews(_ notification: Notification) { layoutHeaders() }
    private func updateMinimumSize() {
        guard let window = view.window else { return }
        let width: CGFloat = dualPane ? 1200 : 900
        window.minSize = NSSize(width: width, height: 520)
        if window.frame.width < width {
            var frame = window.frame; frame.size.width = width
            if let screen = window.screen { frame.origin.x = min(frame.origin.x, screen.visibleFrame.maxX - width) }
            window.setFrame(frame, display: true)
        }
    }
    func focusOtherPane() {
        guard dualPane, let right else { return }
        let next = activeBrowser === left ? right : left
        activate(next); view.window?.makeFirstResponder(next.activeFileView)
    }
    func otherPane(from browser: BrowserViewController) -> BrowserViewController? {
        guard dualPane else { return nil }; return browser === left ? right : left
    }
    func openOtherPane(_ url: URL) {
        if !dualPane { toggleDualPane() }
        guard let other = otherPane(from: activeBrowser) else { return }
        other.navigate(url); activate(other); view.window?.makeFirstResponder(other.activeFileView)
    }
    func canTransfer(from browser: BrowserViewController, move: Bool) -> Bool {
        guard !FileOperationController.shared.busy, let other = otherPane(from: browser), other.folderDestination != nil, !browser.selectedItems.isEmpty else { return false }
        return FileDropPlan.make(sources: browser.selectedItems.map(\.url), destination: other.tab.history.current,
                                internalDrag: true, copyRequested: !move, moveRequested: move, supportsCopy: true, supportsMove: true) != nil
    }
    func transfer(from browser: BrowserViewController, move: Bool) {
        guard let window = view.window, window.attachedSheet == nil, canTransfer(from: browser, move: move), let other = otherPane(from: browser) else { return }
        let urls = browser.selectedItems.map(\.url), destination = other.tab.history.current
        FileOperationController.shared.run(move ? .move(urls, to: destination) : .copy(urls, to: destination), window: window)
    }
    private func closePane(_ browser: BrowserViewController) {
        guard dualPane, let right else { view.window?.performClose(nil); return }
        browser.suspend(); browser.view.removeFromSuperview(); browser.headerView.removeFromSuperview(); browser.tabBar?.removeFromSuperview(); browser.removeFromParent()
        if browser === left { left = right }
        self.right = nil; dualPane = false; syncHeaders()
        activate(left, force: true); updateMinimumSize(); saveSession(); view.window?.makeFirstResponder(left.activeFileView)
    }
    func updatePaneLabels() {
        for browser in [left, right].compactMap({ $0 }) where browser.isViewLoaded {
            let side = browser === left ? "Left" : "Right", active = browser === activeBrowser
            browser.paneBadge.stringValue = dualPane ? side : ""
            browser.paneBadge.textColor = active ? .controlAccentColor : .secondaryLabelColor
            browser.paneBadgeWidth?.constant = dualPane ? 43 : 0
            browser.paneHeader?.color = Palette.chrome
            browser.view.setAccessibilityLabel(dualPane ? "\(side) browsing pane\(active ? ", active" : "")" : "File browser")
            browser.dualButton?.active = dualPane
            browser.copyOtherButton?.isHidden = !dualPane; browser.moveOtherButton?.isHidden = !dualPane
            browser.updateStatus()
        }
    }
    func updateWindowTitle() {
        guard ready else { return }
        let browser = activeBrowser
        view.window?.title = "\(browser.tabTitle(browser.tab)) — Explorer"
        // The native document proxy asks IconServices to synchronously enumerate
        // the folder. Protected or unavailable locations can stall window launch.
        // The address bar supplies the path without that main-thread filesystem IO.
    }
    func syncSidebar(from browser: BrowserViewController) {
        guard ready, browser === activeBrowser else { return }
        if sidebar.showHidden != browser.showHidden { sidebar.showHidden = browser.showHidden; sidebar.rebuild() }
        sidebar.sync(to: browser.tab.history.current)
    }
    func refreshSidebar(from browser: BrowserViewController) {
        guard ready, browser === activeBrowser else { return }
        sidebar.showHidden = browser.showHidden; sidebar.rebuild(); sidebar.sync(to: browser.tab.history.current)
    }
    func saveSession() {
        guard ready else { return }
        SessionStore.save(WorkspaceSession(left: left.session, right: right?.session, dualPane: dualPane, activeRight: activeBrowser === right))
    }
    func shutdown() { left.suspend(); right?.suspend() }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { splitView === outer ? 165 : 420 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { splitView === outer ? min(300, splitView.bounds.width - (dualPane ? 840 : 620)) : splitView.bounds.width - 420 }
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { splitView !== outer || view !== sidebar.view }
}

@MainActor
enum SessionStore {
    private struct Legacy: Codable { let paths: [String]; let active: Int }
    static func load() -> WorkspaceSession {
        if DemoData.active { return DemoData.session }
        if let data = UserDefaults.standard.data(forKey: "explorer.session.v2"), let value = try? JSONDecoder().decode(WorkspaceSession.self, from: data) { return value.sanitized }
        if let data = UserDefaults.standard.data(forKey: "explorer.session.v1"), let old = try? JSONDecoder().decode(Legacy.self, from: data) { return WorkspaceSession(left: PaneSession(paths: old.paths, active: old.active)) }
        return WorkspaceSession(left: PaneSession(paths: []))
    }
    static func save(_ session: WorkspaceSession) {
        guard !DemoData.active else { return }
        if let data = try? JSONEncoder().encode(session) { UserDefaults.standard.set(data, forKey: "explorer.session.v2") }
    }
}
