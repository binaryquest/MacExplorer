import AppKit
import ExplorerCore
import Testing
@testable import ExplorerApp

@Suite @MainActor
struct ContextActionsTests {
    @Test func openWithIntersectsHandlersAndMarksOnlyASharedDefault() {
        let text = URL(fileURLWithPath: "/tmp/a.txt"), image = URL(fileURLWithPath: "/tmp/b.png")
        let editor = URL(fileURLWithPath: "/Applications/Editor.app")
        let viewer = URL(fileURLWithPath: "/Applications/Viewer.app")
        let universal = URL(fileURLWithPath: "/Applications/Universal.app")
        let mixed = OpenWithMenu.applications(for: [text, image], registered: { $0 == text ? [editor, universal, universal] : [viewer, universal] }, defaultApplication: { $0 == text ? editor : viewer })
        #expect(mixed.apps == [universal]); #expect(mixed.defaultApp == nil)
        let shared = OpenWithMenu.applications(for: [text, image], registered: { _ in [editor, universal] }, defaultApplication: { _ in universal })
        #expect(shared.apps == [universal, editor]); #expect(shared.defaultApp == universal)
        let unknown = OpenWithMenu.applications(for: [text], registered: { _ in [] }, defaultApplication: { _ in nil })
        #expect(unknown.apps.isEmpty); #expect(unknown.defaultApp == nil)
    }

    @Test func propertiesPassesLiteralPathsAsData() {
        let urls = [URL(fileURLWithPath: "/tmp/Quote\" and \\ backslash/日本語\nfile.txt"), URL(fileURLWithPath: "/tmp/$(do not execute).json")]
        let arguments = FinderInformation.arguments(for: urls)
        #expect(arguments.numberOfItems == 2)
        #expect(arguments.atIndex(1)?.stringValue == urls[0].path)
        #expect(arguments.atIndex(2)?.stringValue == urls[1].path)
    }

    @Test func addressBarCopiesOnlyWhenShowingAFolder() throws {
        _ = NSApplication.shared
        let bar = PathBar()
        var calls = 0
        bar.onCopyFolderPath = { calls += 1 }
        let button = try #require(bar.subviews.compactMap { $0 as? ActionButton }.first {
            $0.toolTip == L10n.text("Copy Current Folder Path")
        })

        bar.update(BrowserLocation.thisMac)
        #expect(!button.isEnabled)

        bar.update(URL(fileURLWithPath: "/tmp"))
        #expect(button.isEnabled)
        button.performClick(nil)
        #expect(calls == 1)
    }

    @Test func commonFoldersAndSystemLocations() throws {
        let paths = StorageStore.commonFolders.map { $0.url }
        let downloads = try #require(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        #expect(paths.first?.path == "/Applications")
        #expect(paths.contains(downloads))
        #expect(Set(paths).count == paths.count)
        let root = URL(fileURLWithPath: "/")
        let dev = URL(fileURLWithPath: "/dev")
        #expect(StorageDiscovery.visibleVolumes([root, dev]) == [root])
        let items = try FileSystem.list(root)
        for name in ["System", "Library", "usr"] {
            #expect(!FileSort().apply(to: items).contains { $0.name == name })
            #expect(FileSort().apply(to: items, showHidden: true).contains { $0.name == name })
        }
        #expect(FileSort().apply(to: items, showHidden: true).contains { $0.name == "usr" })
    }

    @Test func fileMenus() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Explorer-Menu-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("config.json"))
        try Data().write(to: root.appendingPathComponent("Archive.ZIP"))
        let browser = BrowserViewController(urls: [root], active: 0); browser.tab.viewMode = .details
        _ = browser.view
        defer { browser.suspend(); try? FileManager.default.removeItem(at: root) }
        await browser.tab.loadTask?.value; await browser.tab.sortTask?.value
        for name in ["Folder", "config.json", "Archive.ZIP"] {
            let row = try #require(browser.tab.visible.firstIndex { $0.name == name })
            browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let menu = NSMenu(); browser.populateContextMenu(menu)
            let titles = menu.items.map(\.title)
            #expect(titles.first == L10n.text("Copy Path"))
            #expect(titles.contains(L10n.text("Properties"))); #expect(titles.contains(L10n.text("Compress to ZIP")))
            #expect(titles.contains(L10n.text("Extract All…")) == (name == "Archive.ZIP"))
            #expect(titles.contains(L10n.text("Open With")) == (name != "Folder"))
            if name != "Folder" {
                let sub = try #require(menu.items.first { $0.title == L10n.text("Open With") }?.submenu)
                #expect(sub.items.last?.title == L10n.text("Other…"))
            }
        }
        browser.table.deselectAll(nil)
        let menu = NSMenu(); browser.populateContextMenu(menu)
        #expect(menu.items.first?.title == L10n.text("Copy Current Folder Path"))
        #expect(menu.items.contains { $0.title == L10n.text("Properties") })
        #expect(menu.items.contains { $0.title == L10n.text("New File…") && $0.isEnabled })
        #expect(!menu.items.contains { $0.title == L10n.text("Compress to ZIP") })
    }
}
