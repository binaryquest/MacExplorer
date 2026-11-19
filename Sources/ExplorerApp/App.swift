import AppKit
import ExplorerCore
import Quartz

@main
struct ExplorerMain {
    @MainActor static func main() {
        _ = L10n.current
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windows: [ExplorerWindowController] = []
    private var pendingURLs: [URL] = []
    private var ready = false
    private var languageRestartRequested = false
    private let hotKeyRegistrar = CarbonHotKeyRegistrar()
    private lazy var globalShortcut = GlobalShortcutController(registrar: hotKeyRegistrar)
    private var settings: SettingsWindowController?
    private var about: AboutWindowController?
    private let crashReportExporter = CrashReportExporter()
    private lazy var updates = AppUpdateController()
    var current: ExplorerWindowController? {
        (NSApp.keyWindow?.windowController as? ExplorerWindowController) ?? (NSApp.mainWindow?.windowController as? ExplorerWindowController) ?? windows.last
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DemoData.configure()
        PreferenceMigration.run()
        NSApp.appearance = AppPreferences.shared.appearance.appearance
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") { NSApp.applicationIconImage = NSImage(contentsOf: icon) }
        buildMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: AppPreferences.changed, object: AppPreferences.shared)
        hotKeyRegistrar.onPress = { [weak self] id in
            guard let self, self.globalShortcut.activeID == id else { return }
            self.showExplorer()
        }
        do { try globalShortcut.apply(AppPreferences.shared.shortcutEnabled ? AppPreferences.shared.shortcut : nil) }
        catch { NSLog("Explorer shortcut unavailable: %@", error.localizedDescription) }
        ready = true
        let args = CommandLine.arguments
        if DemoData.active { newWindow(session: DemoData.session) }
        else if let index = args.firstIndex(of: "--folder"), index + 1 < args.count {
            newWindow(urls: [URL(fileURLWithPath: args[index + 1], isDirectory: true)])
        } else if !pendingURLs.isEmpty {
            newWindow(urls: pendingURLs)
            pendingURLs = []
        } else {
            newWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        updates.start()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if !ready { pendingURLs += urls }
        else if let current {
            for url in urls { current.browser.openExternal(url) }
        } else { newWindow(urls: urls) }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if windows.isEmpty { newWindow() }
        else if !flag { showExplorer(forceExisting: true) }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let restart = languageRestartRequested
        languageRestartRequested = false
        if FileOperationController.shared.busy {
            let alert = NSAlert(); alert.messageText = L10n.text("A file operation is still running")
            alert.informativeText = L10n.text("Let it finish, or cancel it with Escape before quitting Explorer.")
            alert.addButton(withTitle: L10n.text("Keep Explorer Open")); alert.runModal(); return .terminateCancel
        }
        if restart {
            do { try scheduleLanguageRestart() }
            catch {
                let alert = NSAlert()
                alert.messageText = L10n.text("Couldn’t Restart Explorer")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: L10n.text("OK"))
                alert.runModal()
                return .terminateCancel
            }
        }
        return .terminateNow
    }
    private func scheduleLanguageRestart() throws {
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for normal termination to finish saving the session and releasing the global shortcut.
        launcher.arguments = ["-c", """
            remaining=60
            while kill -0 "$1" 2>/dev/null; do
                [ "$remaining" -gt 0 ] || exit 1
                remaining=$((remaining - 1))
                /bin/sleep 1
            done
            exec /usr/bin/open -n "$2"
            """, "explorer-relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        try launcher.run()
    }
    func applicationWillTerminate(_ notification: Notification) {
        current?.browser.saveSession(); hotKeyRegistrar.shutdown()
    }

    func newWindow(urls: [URL] = [], active: Int = 0) {
        newWindow(session: urls.isEmpty ? AppPreferences.shared.openingSession(restored: SessionStore.load())
                  : WorkspaceSession(left: PaneSession(paths: urls.map(\.path), active: active)))
    }
    func newWindow(session: WorkspaceSession) {
        let controller = ExplorerWindowController(session: session)
        show(controller)
    }
    private func show(_ controller: ExplorerWindowController) {
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func showExplorer(forceExisting: Bool = false) {
        if (!forceExisting && AppPreferences.shared.shortcutOpensNewWindow) || current == nil { newWindow() }
        else if let window = current?.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showSettings(_ sender: Any?) {
        if settings == nil {
            let controller = SettingsWindowController(shortcutController: globalShortcut, updates: updates)
            if Bundle.main.bundleURL.pathExtension == "app" {
                controller.onLanguageRestart = { [weak self] in
                    self?.languageRestartRequested = true
                    NSApp.terminate(nil)
                }
            }
            settings = controller
        }
        settings?.showWindow(nil); settings?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func checkForUpdates(_ sender: Any?) { updates.checkForUpdates(sender) }
    @objc func exportCrashReport() { crashReportExporter.start() }
    @objc func showAbout(_ sender: Any?) {
        if about == nil { about = AboutWindowController() }
        about?.showWindow(nil); about?.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func preferencesChanged() {
        NSApp.appearance = AppPreferences.shared.appearance.appearance
        for controller in windows {
            controller.workspace.left.applyHiddenPreference()
            controller.workspace.right?.applyHiddenPreference()
        }
    }

    func detachTab(id: UUID, from source: BrowserViewController, at point: NSPoint?) {
        guard source.canTransferTabs, let oldWindow = source.view.window else { return }
        let oldFrame = oldWindow.frame
        guard let transfer = source.extractTab(id: id) else { return }
        let browser = BrowserViewController(transferredTab: transfer.tab, showHidden: source.showHidden)
        let controller = ExplorerWindowController(session: WorkspaceSession(left: browser.session), initialBrowser: browser)
        show(controller)
        if let window = controller.window {
            let location = point ?? NSPoint(x: oldFrame.minX + 200, y: oldFrame.maxY - 6)
            let screen = NSScreen.screens.first { $0.frame.contains(location) } ?? oldWindow.screen ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                let size = NSSize(width: min(oldFrame.width, visible.width), height: min(oldFrame.height, visible.height))
                let origin = NSPoint(x: min(max(location.x - 180, visible.minX), visible.maxX - size.width),
                                     y: min(max(location.y + 22 - size.height, visible.minY), visible.maxY - size.height))
                window.setFrame(NSRect(origin: origin, size: size), display: true)
            }
        }
        if transfer.emptied { source.onCloseWindow?() }
        browser.workspace?.activate(browser, force: true)
        controller.window?.makeKeyAndOrderFront(nil); controller.window?.makeFirstResponder(browser.activeFileView)
        browser.saveSession()
    }

    @objc func newWindowAction(_ sender: Any?) { newWindow() }
    @objc func newTab(_ sender: Any?) { current?.browser.newTab() }
    @objc func closeTab(_ sender: Any?) {
        if NSApp.keyWindow === settings?.window { settings?.window?.performClose(sender) }
        else if NSApp.keyWindow === about?.window { about?.window?.performClose(sender) }
        else { current?.browser.closeActiveTab() }
    }
    @objc func openFolder(_ sender: Any?) { current?.browser.chooseFolder() }
    @objc func editPath(_ sender: Any?) { current?.browser.editPath() }
    @objc func back(_ sender: Any?) { current?.browser.goBack() }
    @objc func forward(_ sender: Any?) { current?.browser.goForward() }
    @objc func up(_ sender: Any?) { current?.browser.goUp() }
    @objc func refresh(_ sender: Any?) { current?.browser.refresh() }
    @objc func home(_ sender: Any?) { current?.browser.navigate(DemoData.active ? DemoData.root : FileManager.default.homeDirectoryForCurrentUser) }
    @objc func exportDemoScreenshot(_ sender: Any?) {
        guard let current else { return }
        do { try DemoData.exportScreenshot(of: current) }
        catch { NSApp.presentError(error) }
    }
    @objc func thisMac(_ sender: Any?) { current?.browser.navigate(BrowserLocation.thisMac) }
    @objc func hidden(_ sender: Any?) { current?.browser.toggleHidden() }
    @objc func copyPath(_ sender: Any?) { current?.browser.copySelectedPaths() }
    @objc func filter(_ sender: Any?) { current?.browser.focusFilter() }
    @objc func recursiveSearch(_ sender: Any?) { current?.browser.focusRecursiveSearch() }
    @objc func toggleDual(_ sender: Any?) { current?.workspace.toggleDualPane() }
    @objc func otherPane(_ sender: Any?) { current?.workspace.focusOtherPane() }
    @objc func pinFolder(_ sender: Any?) { current?.browser.togglePin() }
    @objc func copyOther(_ sender: Any?) { current?.browser.transferToOtherPane(move: false) }
    @objc func moveOther(_ sender: Any?) { current?.browser.transferToOtherPane(move: true) }
    @objc func containingFolder(_ sender: Any?) { current?.browser.openContainingFolder() }
    @objc func preview(_ sender: Any?) { current?.browser.toggleQuickLook() }
    @objc func viewMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = FileViewMode(rawValue: raw) { current?.browser.setViewMode(mode) }
    }
    @objc func nextTab(_ sender: Any?) { current?.browser.cycleTab(1) }
    @objc func previousTab(_ sender: Any?) { current?.browser.cycleTab(-1) }

    @objc func fileOperation(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let action = FileAction(rawValue: raw) { current?.browser.performFileAction(action) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates) { return updates.canCheck }
        if item.action == #selector(exportCrashReport) { return !crashReportExporter.exporting }
        if item.action == #selector(showAbout) || item.action == #selector(showSettings) || item.action == #selector(newWindowAction) { return true }
        if NSApp.keyWindow === settings?.window || NSApp.keyWindow === about?.window { return item.action == #selector(closeTab) }
        if item.action == #selector(fileOperation), let raw = item.representedObject as? String, let action = FileAction(rawValue: raw) {
            if NSApp.keyWindow?.firstResponder is NSTextView, action == .trash || action == .rename { return false }
            return current?.browser.canPerformFileAction(action) == true
        }
        if item.action == #selector(toggleDual) { item.state = current?.workspace.dualPane == true ? .on : .off }
        if item.action == #selector(otherPane) { return current?.workspace.dualPane == true }
        if item.action == #selector(copyOther), let current { return !(NSApp.keyWindow?.firstResponder is NSTextView) && current.workspace.canTransfer(from: current.browser, move: false) }
        if item.action == #selector(moveOther), let current { return !(NSApp.keyWindow?.firstResponder is NSTextView) && current.workspace.canTransfer(from: current.browser, move: true) }
        if item.action == #selector(containingFolder) { return current?.browser.selectedItems.isEmpty == false }
        if item.action == #selector(pinFolder), let current { item.state = FavoriteStore.shared.favorites.contains(current.browser.tab.history.current) ? .on : .off; return !current.browser.tab.isThisMac }
        if item.action == #selector(preview) { return current?.browser.canQuickLook == true }
        if item.action == #selector(viewMode) { item.state = (item.representedObject as? String) == current?.browser.viewMode.rawValue ? .on : .off; return current?.browser.tab.isThisMac == false }
        if item.action == #selector(back) { return current?.browser.canGoBack == true }
        if item.action == #selector(forward) { return current?.browser.canGoForward == true }
        if item.action == #selector(up) { return current?.browser.canGoUp == true }
        if item.action == #selector(hidden) { item.state = current?.browser.showHidden == true ? .on : .off; return current?.browser.tab.isThisMac == false }
        if item.action == #selector(newWindowAction) { return true }
        return current != nil
    }

    private func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title); item.submenu = menu; main.addItem(item); return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target ?? self
            menu.addItem(item)
        }
        let app = submenu("Explorer")
        add(app, L10n.text("About Explorer"), #selector(showAbout))
        add(app, L10n.text("Settings…"), #selector(showSettings), ",")
        add(app, L10n.text("Check for Updates…"), #selector(checkForUpdates))
        app.addItem(.separator())
        add(app, L10n.text("Hide Explorer"), #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(app, L10n.text("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp)
        add(app, L10n.text("Show All"), #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        add(app, L10n.text("Quit Explorer"), #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = submenu(L10n.text("File"))
        add(file, L10n.text("New Window"), #selector(newWindowAction), "n")
        add(file, L10n.text("New Tab"), #selector(newTab), "t")
        add(file, L10n.text("Open Folder…"), #selector(openFolder), "o")
        file.addItem(.separator())
        for (action, key, modifiers) in [(FileAction.newFolder, "n", NSEvent.ModifierFlags([.command, .shift])),
                                         (.rename, String(UnicodeScalar(NSF2FunctionKey)!), []),
                                         (.move, "m", [.command, .shift]),
                                         (.trash, String(UnicodeScalar(NSDeleteCharacter)!), [.command]),
                                         (.compress, "", []), (.extract, "", []),
                                         (.properties, "i", [.command])] {
            let item = NSMenuItem(title: action.title, action: #selector(fileOperation), keyEquivalent: key)
            item.target = self; item.representedObject = action.rawValue; item.keyEquivalentModifierMask = modifiers; file.addItem(item)
        }
        file.addItem(.separator())
        add(file, L10n.text("Copy to Other Pane"), #selector(copyOther), "c", [.control, .shift])
        add(file, L10n.text("Move to Other Pane"), #selector(moveOther), "m", [.control, .shift])
        file.addItem(.separator())
        add(file, L10n.text("Close Tab"), #selector(closeTab), "w")
        if DemoData.active {
            file.addItem(.separator())
            add(file, L10n.text("Export Demo Screenshot"), #selector(exportDemoScreenshot), "s", [.command, .shift])
        }
        let edit = submenu(L10n.text("Edit"))
        for (title, selector, key) in [(L10n.text("Undo"), "undo:", "z"), (L10n.text("Cut"), "cut:", "x"), (L10n.text("Copy"), "copy:", "c"), (L10n.text("Paste"), "paste:", "v"), (L10n.text("Select All"), "selectAll:", "a")] {
            let item = NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key)
            edit.addItem(item)
        }
        edit.addItem(.separator())
        add(edit, L10n.text("Copy Path"), #selector(copyPath), "c", [.command, .shift])
        let view = submenu(L10n.text("View"))
        for mode in FileViewMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(viewMode), keyEquivalent: "")
            item.target = self; item.representedObject = mode.rawValue; view.addItem(item)
        }
        view.addItem(.separator())
        add(view, L10n.text("Quick Look"), #selector(preview))
        view.addItem(.separator())
        add(view, L10n.text("Refresh"), #selector(refresh), "r")
        add(view, L10n.text("Show Hidden Files"), #selector(hidden), ".", [.command, .shift])
        add(view, L10n.text("Search"), #selector(filter), "f")
        add(view, L10n.text("Search Subfolders"), #selector(recursiveSearch), "f", [.command, .shift])
        view.addItem(.separator())
        add(view, L10n.text("Dual Pane"), #selector(toggleDual), "d", [.command, .shift])
        add(view, L10n.text("Focus Other Pane"), #selector(otherPane), String(UnicodeScalar(NSF6FunctionKey)!), [])
        add(view, L10n.text("Pin Current Folder"), #selector(pinFolder), "d")
        view.addItem(.separator())
        let fullScreen = NSMenuItem(title: L10n.text("Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        view.addItem(fullScreen)
        let go = submenu(L10n.text("Go"))
        add(go, L10n.text("Back"), #selector(back), "[")
        add(go, L10n.text("Forward"), #selector(forward), "]")
        add(go, L10n.text("Parent Folder"), #selector(up), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command])
        add(go, L10n.text("Home"), #selector(home), "h", [.command, .shift])
        add(go, L10n.text("This Mac"), #selector(thisMac), "e", [.command, .shift])
        go.addItem(.separator())
        add(go, L10n.text("Open Containing Folder"), #selector(containingFolder), "r", [.command, .shift])
        add(go, L10n.text("Go to Path…"), #selector(editPath), "l")
        let window = submenu(L10n.text("Window"))
        add(window, L10n.text("Next Tab"), #selector(nextTab), "}", [.command, .shift])
        add(window, L10n.text("Previous Tab"), #selector(previousTab), "{", [.command, .shift])
        window.addItem(.separator())
        let minimize = NSMenuItem(title: L10n.text("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(minimize)
        let help = submenu(L10n.text("Help"))
        add(help, L10n.text("Export Crash Report…"), #selector(exportCrashReport))
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
        NSApp.helpMenu = help
    }
}

@MainActor
final class ExplorerWindow: NSWindow {
    weak var browser: BrowserViewController?
    weak var workspace: WorkspaceViewController?
    weak var tabStripView: NSView?
    private weak var pressedTab: BrowserTabView?
    func alignWindowControls(with tabView: NSView) {
        guard !styleMask.contains(.fullScreen), tabView.window === self, tabView.bounds.height > 0 else { return }
        // Keep the real AppKit controls, horizontal spacing and native actions.
        // Convert from the tab body so its top padding is included in alignment.
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(kind), let parent = button.superview else { continue }
            let center = parent.convert(NSPoint(x: tabView.bounds.midX, y: tabView.bounds.midY), from: tabView)
            let y = center.y - button.frame.height / 2
            if abs(button.frame.minY - y) > 0.01 { button.setFrameOrigin(NSPoint(x: button.frame.minX, y: y)) }
        }
    }
    func contentHit(at location: NSPoint) -> NSView? {
        // Native titlebar accessories live outside contentView's hierarchy.
        if let tabStripView, !tabStripView.isHiddenOrHasHiddenAncestor, let parent = tabStripView.superview,
           let hit = tabStripView.hitTest(parent.convert(location, from: nil)) { return hit }
        guard let contentView else { return nil }
        // hitTest takes its point in the receiver's SUPERview coordinates.
        // Our content is flipped, so converting into content coordinates first
        // would test the bottom of the window when the pointer is over a tab.
        return contentView.hitTest(contentView.superview?.convert(location, from: nil) ?? location)
    }
    override func sendEvent(_ event: NSEvent) {
        // Keep the tab's press/drag sequence together. Its native titlebar
        // accessory excludes the tab area from Window Server dragging.
        if attachedSheet == nil {
            if event.type == .leftMouseDown, let tab = contentHit(at: event.locationInWindow) as? BrowserTabView {
                pressedTab = tab
                makeKeyAndOrderFront(nil)
                workspace?.activatePane(containing: tab)
                tab.mouseDown(with: event)
                return
            }
            if event.type == .leftMouseDown, let titlebar = contentHit(at: event.locationInWindow) as? TitlebarSurface {
                pressedTab = nil
                makeKeyAndOrderFront(nil)
                titlebar.mouseDown(with: event)
                return
            }
            if event.type == .leftMouseDragged, let pressedTab {
                pressedTab.mouseDragged(with: event); return
            }
            if event.type == .leftMouseUp, let tab = pressedTab {
                pressedTab = nil; tab.mouseUp(with: event); return
            }
        }
        if event.type == .leftMouseDown { pressedTab = nil }
        if attachedSheet == nil, [.leftMouseDown, .rightMouseDown].contains(event.type) {
            workspace?.activatePane(containing: contentHit(at: event.locationInWindow))
        }
        super.sendEvent(event)
    }
    func endTabGesture() { pressedTab = nil }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let result = super.makeFirstResponder(responder)
        if result, let view = responder as? NSView { workspace?.activatePane(containing: view) }
        return result
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if attachedSheet == nil, browser?.handleFileShortcut(event) == true { return true }
        if attachedSheet != nil { return super.performKeyEquivalent(with: event) }
        // Arrow and function keys also carry .numericPad/.function on macOS.
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .option {
            switch event.keyCode {
            case 123: browser?.goBack(); return true
            case 124: browser?.goForward(); return true
            case 126: browser?.goUp(); return true
            default: break
            }
        }
        if event.keyCode == 48 && flags.contains(.control) {
            browser?.cycleTab(flags.contains(.shift) ? -1 : 1); return true
        }
        if event.keyCode == 96 && flags.isEmpty { browser?.refresh(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class ExplorerWindowController: NSWindowController, NSWindowDelegate {
    let workspace: WorkspaceViewController
    var browser: BrowserViewController { workspace.activeBrowser }
    var onClose: (() -> Void)?
    let titlebarAccessory = NSTitlebarAccessoryViewController()
    private var titlebarLayoutPending = false
    init(session: WorkspaceSession, initialBrowser: BrowserViewController? = nil) {
        workspace = WorkspaceViewController(session: session, initialBrowser: initialBrowser)
        let window = ExplorerWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.workspace = workspace; window.browser = browser
        window.title = "Explorer"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // Keep a full-height native titlebar for the tab accessory. Without a
        // toolbar AppKit compresses this row to its small, title-only height.
        window.toolbarStyle = .expanded
        window.toolbar = NSToolbar(identifier: "Explorer.TabTitlebar")
        window.backgroundColor = Palette.chrome
        window.minSize = NSSize(width: 900, height: 520)
        window.contentViewController = workspace
        // .top is supported by AppKit since macOS 10.13 and requires
        // .fullSizeContentView. AppKit owns its hit region and traffic-light gap.
        titlebarAccessory.layoutAttribute = .top
        titlebarAccessory.view = TitlebarSurface(frame: NSRect(x: 0, y: 0, width: 1160, height: 44))
        window.addTitlebarAccessoryViewController(titlebarAccessory)
        workspace.installTitlebar(in: titlebarAccessory.view)
        window.tabStripView = workspace.titlebarTabs
        window.setContentSize(NSSize(width: 1160, height: 760))
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Explorer.mainWindow")
        window.center()
        updateTitlebarLayout()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func updateTitlebarLayout() {
        workspace.updateTitlebarLayout()
        workspace.titlebarTabs.layoutSubtreeIfNeeded()
        if !titlebarAccessory.isHidden,
           let tab = workspace.left.tabs.first.flatMap({ workspace.left.tabChips[$0.id] }) {
            (window as? ExplorerWindow)?.alignWindowControls(with: tab)
        }
    }
    private func scheduleTitlebarLayout() {
        guard !titlebarLayoutPending else { return }
        titlebarLayoutPending = true
        // AppKit may resize its accessory during this update pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.titlebarLayoutPending = false
            self.updateTitlebarLayout()
        }
    }
    func windowDidUpdate(_ notification: Notification) { scheduleTitlebarLayout() }
    func windowDidResize(_ notification: Notification) { scheduleTitlebarLayout() }
    func windowWillEnterFullScreen(_ notification: Notification) {
        // Keep tabs visible when macOS retracts its fullscreen titlebar.
        workspace.embedTitlebarForFullScreen(); titlebarAccessory.isHidden = true
        window?.toolbar?.isVisible = false
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        window?.toolbar?.isVisible = true
        titlebarAccessory.isHidden = false; workspace.installTitlebar(in: titlebarAccessory.view)
        scheduleTitlebarLayout()
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        window.toolbar?.isVisible = true
        titlebarAccessory.isHidden = false; workspace.installTitlebar(in: titlebarAccessory.view)
        scheduleTitlebarLayout()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if FileOperationController.shared.busy { NSSound.beep(); return false }
        return true
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { MainActor.assumeIsolated { browser.canQuickLook } }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { browser.beginQuickLook(panel) } }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { (panel.dataSource as? BrowserViewController)?.endQuickLook(panel) } }
    func windowWillClose(_ notification: Notification) { workspace.saveSession(); workspace.shutdown(); onClose?() }
}
