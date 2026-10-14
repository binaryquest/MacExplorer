import AppKit
import ExplorerCore

extension BrowserViewController {
    func loadThisMac() {
        cancelSearchWork(); tab.loadTask?.cancel(); tab.sortTask?.cancel(); refreshTask?.cancel()
        tab.generation = UUID(); tab.sortGeneration = UUID(); tab.loading = false; tab.error = nil
        watcher = nil; watcherURL = nil; watcherTabID = nil
        closeQuickLook(); cancelVisibleThumbnails(); tab.items = []; tab.clearVisible()
        thisMacView.onOpen = { [weak self] url, newTab in
            if newTab { self?.newTab(url: url) } else { self?.navigate(url) }
        }
        thisMacView.onOtherPane = { [weak self] url in self?.workspace?.openOtherPane(url) }
        thisMacView.onBack = { [weak self] in self?.goBack() }
        thisMacView.onSelection = { [weak self] in self?.updateStatus() }
        thisMacView.collection.onFileAction = { [weak self] in self?.performFileAction($0) }
        thisMacView.collection.canFileAction = { [weak self] in self?.canPerformFileAction($0) == true }
        applyPresentationMode(); updateSearchControls(); updateEmptyState()
        storageChanged(); StorageStore.shared.refreshIfNeeded()
    }
    @objc func storageChanged() {
        guard isViewLoaded, tab.isThisMac else { return }
        thisMacView.update(StorageStore.shared.locations, query: tab.query, loading: StorageStore.shared.refreshing)
        updateStatus()
    }
}
