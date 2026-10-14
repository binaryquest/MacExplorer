import AppKit
import ExplorerCore

extension BrowserViewController {
    var canTransferTabs: Bool {
        isViewLoaded && view.window?.isVisible == true && view.window?.attachedSheet == nil && !operations.busy
    }

    func reorderTab(id: UUID, before slot: Int) {
        guard canTransferTabs, let source = tabs.firstIndex(where: { $0.id == id }),
              let destination = TabPlacement.destination(from: source, before: slot, count: tabs.count), source != destination else { return }
        let activeID = tab.id
        tabs.insert(tabs.remove(at: source), at: destination)
        activeIndex = tabs.firstIndex { $0.id == activeID }!
        updateChrome(); saveSession()
    }

    /// Cancel work bound to the old controller before handing the same tab to its new owner.
    func extractTab(id: UUID) -> (tab: BrowserTab, emptied: Bool)? {
        guard canTransferTabs, let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        rememberSelection()
        let activeID = tab.id, moved = tabs[index]
        if moved === tab { suspend() }
        moved.searchTask?.cancel(); moved.loadTask?.cancel(); moved.sortTask?.cancel()
        moved.searchTask = nil; moved.loadTask = nil; moved.sortTask = nil
        moved.searchGeneration = UUID(); moved.generation = UUID(); moved.sortGeneration = UUID()
        moved.loading = false
        tabs.remove(at: index)
        let emptied = tabs.isEmpty
        if emptied {
            // Closing a pane/window calls suspend and saves its session. It must
            // never operate on the tab that now belongs to the destination.
            tabs = [BrowserTab(url: BrowserLocation.thisMac)]; activeIndex = 0
        } else {
            activeIndex = tabs.firstIndex { $0.id == activeID } ?? min(index, tabs.count - 1)
            updateChrome()
            if activeID == id { loadFolder(clear: true) }
            saveSession()
        }
        return (moved, emptied)
    }

    @discardableResult
    func receiveTab(id: UUID, from source: BrowserViewController, before slot: Int) -> Bool {
        guard canTransferTabs, source.canTransferTabs, (0...tabs.count).contains(slot) else { return false }
        if source === self { reorderTab(id: id, before: slot); return true }
        rememberSelection(); suspend()
        guard let transfer = source.extractTab(id: id) else { loadFolder(clear: false); return false }
        tabs.insert(transfer.tab, at: slot); activeIndex = slot
        updateChrome(); loadFolder(clear: true)
        if transfer.emptied { source.onCloseWindow?() }
        workspace?.activate(self, force: true)
        view.window?.makeKeyAndOrderFront(nil); view.window?.makeFirstResponder(activeFileView)
        saveSession()
        return true
    }

    func moveTabToNewWindow(id: UUID, at point: NSPoint? = nil) {
        (NSApp.delegate as? AppDelegate)?.detachTab(id: id, from: self, at: point)
    }
}
