import AppKit
import Testing
@testable import ExplorerApp

@Suite @MainActor
struct TabHitTestingTests {
    private func fixture() -> (ExplorerWindow, Surface, NSScrollView, [BrowserTabView]) {
        _ = NSApplication.shared
        let window = ExplorerWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = TitlebarSurface(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        window.contentView = root
        let scroll = TabStripScrollView(frame: NSRect(x: 90, y: 0, width: 600, height: 44))
        scroll.automaticallyAdjustsContentInsets = false
        let document = TabStripDocumentView(frame: NSRect(x: 0, y: 0, width: 864, height: 44))
        scroll.documentView = document; root.addSubview(scroll)
        let tabs = (0..<4).map { index in
            let tab = BrowserTabView(id: UUID(), title: "Tab \(index)", active: index == 1, select: {}, close: {})
            tab.frame = NSRect(x: CGFloat(index) * 216, y: 6, width: 212, height: 38)
            document.addSubview(tab); return tab
        }
        root.layoutSubtreeIfNeeded()
        return (window, root, scroll, tabs)
    }

    @Test func firstSecondAndThirdTabsHitTheirBodiesIncludingLabelsAndIcons() {
        let (window, _, _, tabs) = fixture()
        defer { window.close() }
        for tab in tabs.prefix(3) {
            for x: CGFloat in [8, 22, 70, 140] {
                for y: CGFloat in [5, 12, 22, 30] {
                    let point = tab.convert(NSPoint(x: x, y: y), to: nil)
                    #expect(window.contentHit(at: point) === tab)
                }
            }
        }
    }

    @Test func closeButtonsAndEmptyTitlebarSpaceHaveSeparateTargets() {
        let (window, root, scroll, tabs) = fixture()
        defer { window.close() }
        #expect(!scroll.mouseDownCanMoveWindow)
        #expect(scroll.documentView?.mouseDownCanMoveWindow == false)
        for tab in tabs.prefix(2) {
            let point = tab.convert(NSPoint(x: 193, y: 19), to: nil)
            #expect(window.contentHit(at: point) is ActionButton)
        }
        let empty = root.convert(NSPoint(x: 740, y: 20), to: nil)
        #expect(window.contentHit(at: empty) === root)
    }

    @Test func windowLayoutRemainsEnabledWhileTabViewsRejectWindowDragging() {
        let (window, root, scroll, tabs) = fixture()
        defer { window.close() }
        #expect(window.isMovable)
        #expect(!window.isMovableByWindowBackground)
        #expect(!root.mouseDownCanMoveWindow)
        #expect(!scroll.contentView.mouseDownCanMoveWindow)
        for tab in tabs { #expect(!tab.mouseDownCanMoveWindow) }
        // Explicit performDrag on empty titlebar space still moves the window.
        #expect(window.styleMask.contains(.resizable))
        #expect(window.standardWindowButton(.closeButton) != nil)
        #expect(window.standardWindowButton(.zoomButton) != nil)
    }

    @Test func nativeAccessoryTabHitsStaySeparateFromWindowControls() {
        let (window, _, scroll, tabs) = fixture()
        defer { window.close() }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .top
        let host = TitlebarSurface(frame: NSRect(x: 0, y: 0, width: 800, height: 44))
        accessory.view = host
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.toolbarStyle = .expanded
        window.toolbar = NSToolbar(identifier: "Explorer.TabTitlebar")
        window.addTitlebarAccessoryViewController(accessory)
        scroll.removeFromSuperview(); host.addSubview(scroll)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        scroll.frame = NSRect(x: 8, y: 0, width: host.bounds.width - 16, height: host.bounds.height)
        window.tabStripView = host
        for tab in tabs { tab.frame.origin.y = 4; tab.frame.size.height = host.bounds.height - 4 }
        host.layoutSubtreeIfNeeded()
        #expect(window.isMovable)
        #expect(host.bounds.height >= 44)
        #expect(!host.mouseDownCanMoveWindow)
        #expect(!host.isDescendant(of: window.contentView!))
        for tab in tabs.prefix(3) {
            for x: CGFloat in [8, 22, 70, 140] {
                #expect(window.contentHit(at: tab.convert(NSPoint(x: x, y: 12), to: nil)) === tab)
            }
            #expect(window.contentHit(at: tab.convert(NSPoint(x: 193, y: tab.bounds.midY), to: nil)) is ActionButton)
        }
        window.alignWindowControls(with: tabs[0])
        let tabCenter = tabs[0].convert(NSPoint(x: tabs[0].bounds.midX, y: tabs[0].bounds.midY), to: nil)
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            let button = window.standardWindowButton(kind)!
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            #expect(abs(point.y - tabCenter.y) < 0.01)
            let nativeFrame = window.contentView!.superview!
            #expect(nativeFrame.hitTest(nativeFrame.superview?.convert(point, from: nil) ?? point) === button)
            #expect(!(window.contentHit(at: point) is BrowserTabView))
        }
    }

    @Test func hitTestingFollowsReorderedAndHorizontallyScrolledTabs() {
        let (window, _, scroll, tabs) = fixture()
        defer { window.close() }
        tabs[1].frame.origin.x = 0; tabs[0].frame.origin.x = 216
        scroll.contentView.scroll(to: NSPoint(x: 216, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        for tab in [tabs[0], tabs[2], tabs[3]] {
            let point = tab.convert(NSPoint(x: 70, y: 15), to: nil)
            #expect(window.contentHit(at: point) === tab)
        }
    }
}
