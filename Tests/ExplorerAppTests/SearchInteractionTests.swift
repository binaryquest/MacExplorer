import AppKit
import Testing
import ExplorerCore
@testable import ExplorerApp

@Suite @MainActor
struct SearchInteractionTests {
    private func fixture() throws -> (URL, BrowserViewController) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Explorer-Search-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("report.txt"))
        try Data().write(to: root.appendingPathComponent("Nested/report-copy.txt"))
        let browser = BrowserViewController(urls: [root], active: 0)
        browser.tab.viewMode = .details
        _ = browser.view
        return (root, browser)
    }
    private func finish(_ browser: BrowserViewController) async {
        await browser.tab.loadTask?.value
        await browser.tab.searchTask?.value
        await browser.tab.sortTask?.value
    }

    @Test func clearCancelsPendingSearchAndRestoresFolderSelection() async throws {
        let (root, browser) = try fixture()
        defer { browser.suspend(); try? FileManager.default.removeItem(at: root) }
        await finish(browser)
        let row = try #require(browser.tab.visible.firstIndex { $0.name == "report.txt" })
        browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        browser.search.stringValue = "report"
        browser.searchQueryChanged()
        let pending = browser.tab.searchTask
        #expect(pending != nil)
        #expect(!browser.closeSearchButton.isHidden)
        browser.search.clearButton.performClick(nil)
        await pending?.value
        await finish(browser)
        #expect(browser.tab.query.isEmpty)
        #expect(browser.tab.searchTask == nil)
        #expect(browser.closeSearchButton.isHidden)
        #expect(browser.search.clearButton.isHidden)
        #expect(Set(browser.tab.visible.map(\.name)) == ["Nested", "report.txt"])
        #expect(browser.selectedItems.map(\.name) == ["report.txt"])
    }

    @Test func scopeSwitchingAndCloseKeepSearchBoundToItsTab() async throws {
        let (root, browser) = try fixture()
        defer { browser.suspend(); try? FileManager.default.removeItem(at: root) }
        await finish(browser)
        browser.search.stringValue = "report"; browser.searchQueryChanged()
        await finish(browser)
        #expect(browser.tab.visible.count == 2)
        let firstID = browser.tab.id
        browser.newTab(url: root.appendingPathComponent("Nested"))
        await finish(browser)
        #expect(browser.search.stringValue.isEmpty)
        #expect(browser.closeSearchButton.isHidden)
        browser.activateTab(id: firstID)
        await finish(browser)
        #expect(browser.search.stringValue == "report")
        #expect(browser.tab.visible.count == 2)
        let local = try #require(browser.searchOptions.menu?.item(withTag: 1))
        browser.changeSearchScope(local)
        await finish(browser)
        #expect(browser.tab.visible.map(\.name) == ["report.txt"])
        #expect(!browser.tab.isRecursiveSearch)
        browser.closeSearchButton.performClick(nil)
        await finish(browser)
        #expect(browser.tab.query.isEmpty)
        #expect(browser.tab.visible.count == 2)
        #expect(browser.tabs[1].query.isEmpty)
    }

    @Test func contentSearchPreservesFileIdentityAndRestoresFolderPresentation() async throws {
        let (root, browser) = try fixture()
        defer { browser.suspend(); try? FileManager.default.removeItem(at: root) }
        await finish(browser)
        let originalHeader = browser.table.headerView
        browser.search.stringValue = "report"; browser.searchQueryChanged()
        await finish(browser)
        #expect(browser.viewMode == .content)
        #expect(browser.activeFileView === browser.table)
        #expect(browser.table.headerView == nil)
        #expect(browser.table.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue) == ["name"])
        let row = try #require(browser.tab.visible.firstIndex { $0.name == "report-copy.txt" })
        let column = try #require(browser.table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")))
        let cell = try #require(browser.tableView(browser.table, viewFor: column, row: row) as? ContentResultCell)
        let result = browser.tab.visible[row]
        #expect(cell.locationLabel.stringValue == result.url.deletingLastPathComponent().path)
        #expect(cell.modifiedLabel.stringValue.contains(browser.dateFormatter.string(from: try #require(result.modified))))
        #expect(cell.sizeLabel.stringValue == "Size: Zero KB")
        #expect(cell.nameLabel.attributedStringValue.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
        browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        #expect(browser.selectedItems.map(\.url) == [result.url])
        browser.setViewMode(.large); await browser.tab.sortTask?.value
        #expect(browser.activeFileView === browser.collection)
        #expect(browser.selectedItems.map(\.url) == [result.url])
        browser.setViewMode(.details); await browser.tab.sortTask?.value
        #expect(browser.table.headerView === originalHeader)
        #expect(browser.selectedItems.map(\.url) == [result.url])
        browser.setViewMode(.content); await browser.tab.sortTask?.value
        browser.closeSearch(); await finish(browser)
        #expect(browser.viewMode == .details)
        #expect(browser.tab.viewMode == .details)
        #expect(browser.table.headerView === originalHeader)
        #expect(browser.table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("modified"))?.isHidden == false)
        #expect(browser.table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("location"))?.isHidden == true)
    }

    @Test(arguments: [FileViewMode.content, .details, .small])
    func folderLinkRevealsItsOwnResultInsteadOfTheSelectedResult(_ mode: FileViewMode) async throws {
        let (root, browser) = try fixture()
        defer { browser.suspend(); try? FileManager.default.removeItem(at: root) }
        await finish(browser)
        browser.search.stringValue = "report"; browser.searchQueryChanged()
        await finish(browser)
        browser.setViewMode(mode); await finish(browser)
        let selected = try #require(browser.tab.visible.firstIndex { $0.name == "report.txt" })
        let target = try #require(browser.tab.visible.firstIndex { $0.name == "report-copy.txt" })
        let result = browser.tab.visible[target]
        let link: FolderLocationLink
        if mode.usesTable {
            browser.table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            let column = try #require(browser.table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(mode == .content ? "name" : "location")))
            let cell = try #require(browser.tableView(browser.table, viewFor: column, row: target) as? NSTableCellView)
            link = try #require((cell as? ContentResultCell)?.locationLabel ?? cell.textField as? FolderLocationLink)
            #expect(browser.table.validateProposedFirstResponder(link, for: nil))
        } else {
            browser.collection.selectionIndexPaths = [try #require(browser.iconPath(for: selected))]
            let cell = FileIconItem()
            browser.configureIcon(cell, at: try #require(browser.iconPath(for: target)))
            link = try #require(cell.view.subviews.compactMap { $0 as? FolderLocationLink }.first)
        }
        #expect(browser.selectedItems.map(\.name) == ["report.txt"])
        #expect(link.accessibilityRole() == .link)
        #expect(link.accessibilityPerformPress())
        await finish(browser)
        #expect(FileOperationController.itemPath(browser.tab.history.current) == FileOperationController.itemPath(result.url.deletingLastPathComponent()))
        #expect(browser.tab.query.isEmpty)
        #expect(browser.search.stringValue.isEmpty)
        #expect(browser.viewMode == .details)
        #expect(browser.selectedItems.map(\.url) == [result.url])
    }
}
