import AppKit
import ExplorerCore

extension BrowserViewController {
    func tabTitle(_ tab: BrowserTab) -> String {
        tab.isRecursiveSearch ? L10n.text("%1$@ — Search Results in %2$@", tab.query, title(for: tab.history.current)) : title(for: tab.history.current)
    }

    func updateSearchControls() {
        searchOptions.isHidden = tab.isThisMac
        closeSearchButton?.isHidden = tab.query.isEmpty
        updateSearchMenuState()
        pathBar.update(tab.history.current, searchResults: tab.isRecursiveSearch ? title(for: tab.history.current) : nil)
        tabChips[tab.id]?.update(title: tabTitle(tab), active: true)
        workspace?.updateWindowTitle()
        if tab.isThisMac {
            search.placeholderString = L10n.text("Search This Mac"); search.setAccessibilityLabel(L10n.text("Search drives and network locations"))
            search.toolTip = L10n.text("Filter drives and cloud folders by name or account"); return
        }
        let recursive = tab.searchScope == .subfolders
        search.placeholderString = L10n.text("Search %1$@", title(for: tab.history.current))
        search.setAccessibilityLabel(recursive ? L10n.text("Search folder and subfolders") : L10n.text("Filter this folder"))
        search.toolTip = recursive ? L10n.text("Find names in %1$@ and its subfolders", tab.history.current.path) : L10n.text("Filter names in the current folder")
    }

    func searchOptionsMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let title = NSMenuItem(title: L10n.text("Search options"), action: nil, keyEquivalent: "")
        title.image = Palette.buttonSymbol("doc.text.magnifyingglass", size: 14, canvas: 18); menu.addItem(title)
        for (label, tag, action) in [(L10n.text("Current folder"), 1, #selector(changeSearchScope(_:))),
                                    (L10n.text("All subfolders"), 2, #selector(changeSearchScope(_:))),
                                    (L10n.text("Stop search"), 3, #selector(stopSearch)),
                                    (L10n.text("Search again"), 4, #selector(submitSearch))] {
            if tag == 3 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.tag = tag; item.target = self; menu.addItem(item)
        }
        return menu
    }
    func updateSearchMenuState() {
        for item in searchOptions.menu?.items ?? [] {
            switch item.tag {
            case 1: item.state = tab.searchScope == .folder ? .on : .off
            case 2: item.state = tab.searchScope == .subfolders ? .on : .off
            case 3: item.isEnabled = tab.searchTask != nil
            case 4: item.isEnabled = !tab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: break
            }
        }
    }
    func layoutSearchTools(width: CGFloat) {
        let compact = width < 1040
        let title = compact ? L10n.text("Search") : L10n.text("Search options")
        if searchOptions.menu?.items.first?.title != title { searchOptions.menu?.items.first?.title = title }
        let optionsWidth: CGFloat = compact ? 86 : 132, closeWidth: CGFloat = compact ? 32 : 110
        if searchOptionsWidth?.constant != optionsWidth { searchOptionsWidth?.constant = optionsWidth }
        if closeSearchWidth?.constant != closeWidth { closeSearchWidth?.constant = closeWidth }
        let closeTitle = compact ? "" : L10n.text("Close search")
        if closeSearchButton?.title != closeTitle {
            closeSearchButton?.title = closeTitle
            closeSearchButton?.imagePosition = compact ? .imageOnly : .imageLeading
        }
    }
    @objc func changeSearchScope(_ sender: NSMenuItem) {
        let scope: SearchScope = sender.tag == 1 ? .folder : .subfolders
        guard scope != tab.searchScope else { return }
        rememberSelection(); tab.searchScope = scope
        loadFolder(clear: true); updateSearchControls()
    }
    func closeSearch(focusFiles: Bool = true) {
        guard !tab.query.isEmpty else {
            if focusFiles { view.window?.makeFirstResponder(activeFileView) }
            return
        }
        rememberSelection(); cancelSearchWork(); closeQuickLook()
        tab.query = ""; search.stringValue = ""
        loadFolder(clear: true)
        if focusFiles { view.window?.makeFirstResponder(activeFileView) }
    }
    @objc func submitSearch() {
        guard !tab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { focusFilter(); return }
        if tab.isRecursiveSearch { startSearch() }
        else if tab.isThisMac { storageChanged() }
        else { applyView() }
    }
    func focusRecursiveSearch() {
        if tab.isThisMac { focusFilter(); return }
        if tab.searchScope != .subfolders { tab.searchScope = .subfolders; loadFolder(clear: true) }
        updateSearchControls(); focusFilter()
    }
    func cancelSearchWork() {
        tab.searchTask?.cancel(); tab.searchTask = nil; tab.searchGeneration = UUID()
    }
    @objc func stopSearch() {
        guard tab.searchTask != nil else { return }
        cancelSearchWork(); tab.loading = false; tab.searchStopped = true
        updateStatus(); updateEmptyState()
    }
    func startSearch(debounce: Bool = false) {
        cancelSearchWork(); tab.loadTask?.cancel(); tab.sortTask?.cancel(); refreshTask?.cancel()
        watcher = nil; watcherURL = nil; watcherTabID = nil
        let tab = self.tab, generation = tab.searchGeneration
        let root = tab.history.current, query = tab.query, hidden = showHidden
        tab.searchScanned = 0; tab.searchSkipped = 0; tab.searchLimited = false; tab.searchStopped = false
        tab.error = nil; tab.loading = true; tab.items = []; tab.clearVisible()
        suppressSelection = true; cancelVisibleThumbnails(); table.reloadData(); collection.reloadData()
        table.deselectAll(nil); collection.selectionIndexPaths = []; suppressSelection = false
        applyPresentationMode(); updateSearchControls(); updateQuickLookSelection(); updateEmptyState()
        tab.searchTask = Task { [weak self, weak tab] in
            if debounce { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled, let self, let tab, self.tab === tab, tab.searchGeneration == generation else { return }
            let worker = Task.detached(priority: .userInitiated) { [self, tab] in
                try await DirectorySearch.run(root: root, query: query, showHidden: hidden) { update in
                    await MainActor.run { [self, tab] in
                        guard self.tab === tab, tab.searchGeneration == generation else { return }
                        tab.searchScanned = update.scanned; tab.searchSkipped = update.unreadableFolders; tab.searchLimited = update.reachedLimit
                        if !update.matches.isEmpty {
                            tab.scrollPositions[self.scrollKey] = self.activeScroll.contentView.bounds.origin.y
                            tab.items.append(contentsOf: update.matches); self.applyView()
                        }
                        self.updateStatus()
                    }
                }
            }
            do {
                _ = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, self.tab === tab, tab.searchGeneration == generation else { return }
                tab.loading = false; tab.searchTask = nil; self.updateStatus(); self.updateEmptyState()
            } catch {
                guard !Task.isCancelled, self.tab === tab, tab.searchGeneration == generation else { return }
                tab.loading = false; tab.searchTask = nil; tab.error = error.localizedDescription
                self.updateStatus(); self.updateEmptyState()
            }
        }
        updateStatus()
    }
    func updateSearchStatus() {
        if tab.loading { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        let count = tab.visible.count, scanned = tab.searchScanned.formatted(.number.locale(L10n.locale))
        if tab.error != nil { status.stringValue = L10n.text("Search unavailable"); detail.stringValue = ""; return }
        status.stringValue = L10n.count("%lld results", count)
        if !selectedItems.isEmpty { status.stringValue += L10n.text(" · %1$@ selected", selectedItems.count) }
        if tab.loading { detail.stringValue = L10n.text("Searching · %1$@ checked", scanned) }
        else if tab.searchStopped { detail.stringValue = L10n.text("Stopped · partial results") }
        else if tab.searchLimited { detail.stringValue = L10n.text("20,000-result limit · refine search") }
        else { detail.stringValue = tab.searchSkipped > 0 ? L10n.text("%1$@ folders unreadable", tab.searchSkipped) : L10n.text("Search complete") }
        if tab.loading, tab.searchSkipped > 0 { detail.stringValue += L10n.text(" · %1$@ unreadable", tab.searchSkipped) }
    }
    func suspend() {
        closeQuickLook(); cancelSearchWork(); tab.loadTask?.cancel(); tab.sortTask?.cancel(); refreshTask?.cancel()
        watcher = nil; watcherURL = nil; watcherTabID = nil; cancelVisibleThumbnails(); tab.loading = false
    }
    @objc func openContainingFolder() {
        guard let item = selectedItems.first else { return }
        revealInContainingFolder(item.url)
    }
    func revealInContainingFolder(_ file: URL) {
        guard view.window?.attachedSheet == nil else { return }
        workspace?.activate(self)
        navigate(file.deletingLastPathComponent())
        tab.pendingSelections[tab.selectionKey] = [FileOperationController.itemPath(file)]
        view.window?.makeFirstResponder(activeFileView)
    }
    @objc func favoritesChanged() {
        guard isViewLoaded else { return }
        let pinned = FavoriteStore.shared.favorites.contains(tab.history.current)
        pinButton?.isEnabled = !tab.isThisMac
        pinButton?.active = pinned
        pinButton?.toolTip = pinned ? L10n.text("Unpin current folder (⌘D)") : L10n.text("Pin current folder (⌘D)")
        pinButton?.setAccessibilityLabel(pinned ? L10n.text("Unpin current folder from Favorites") : L10n.text("Pin current folder to Favorites"))
    }
    func togglePin() { if !tab.isThisMac { FavoriteStore.shared.toggle(tab.history.current) } }
    @objc func pinSelectedFolder() {
        if let item = selectedItems.first, item.isNavigable { FavoriteStore.shared.toggle(item.url) }
    }
    @objc func openSelectedInOtherPane() {
        if let item = selectedItems.first, item.isNavigable { workspace?.openOtherPane(item.url) }
    }
    func transferToOtherPane(move: Bool) { workspace?.transfer(from: self, move: move) }
    func updateTransferButtons() {
        copyOtherButton?.isEnabled = workspace?.canTransfer(from: self, move: false) == true
        moveOtherButton?.isEnabled = workspace?.canTransfer(from: self, move: true) == true
    }
}
