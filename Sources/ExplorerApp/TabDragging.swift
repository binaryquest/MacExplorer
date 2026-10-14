import AppKit
import ExplorerCore

@MainActor
final class TabDragSession: NSObject, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType("dev.local.explorer.browser-tab")
    private static var current: TabDragSession?
    let id: UUID
    let source: BrowserViewController
    private weak var chip: BrowserTabView?
    private var escapeMonitor: Any?
    private var cancelled = false
    var accepted = false

    private init(id: UUID, source: BrowserViewController, chip: BrowserTabView) {
        self.id = id; self.source = source; self.chip = chip
    }

    static func begin(from chip: BrowserTabView, browser: BrowserViewController, event: NSEvent) {
        guard current == nil, browser.canTransferTabs else { return }
        let drag = TabDragSession(id: chip.id, source: browser, chip: chip)
        current = drag
        // From this point AppKit owns the native drag loop, not the window's
        // initial mouse-down/threshold tracking.
        (chip.window as? ExplorerWindow)?.endTabGesture()
        let item = NSPasteboardItem(); item.setString(chip.id.uuidString, forType: pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let preview = NSImage(size: chip.bounds.size)
        if let bitmap = chip.bitmapImageRepForCachingDisplay(in: chip.bounds) {
            chip.cacheDisplay(in: chip.bounds, to: bitmap); preview.addRepresentation(bitmap)
        }
        draggingItem.setDraggingFrame(chip.bounds, contents: preview)
        drag.escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak drag] key in
            if key.keyCode == 53 { drag?.cancelled = true }
            return key
        }
        let session = chip.beginDraggingSession(with: [draggingItem], event: event, source: drag)
        session.draggingFormation = .none
        session.animatesToStartingPositionsOnCancelOrFail = true
        chip.alphaValue = 0.4
    }

    static func validated(_ info: NSDraggingInfo) -> TabDragSession? {
        guard let drag = info.draggingSource as? TabDragSession, drag === current,
              info.draggingPasteboard.string(forType: pasteboardType) == drag.id.uuidString,
              drag.source.canTransferTabs, drag.source.tabs.contains(where: { $0.id == drag.id }) else { return nil }
        return drag
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Never expose a folder URL or advertise an operation to other apps.
        context == .withinApplication ? .move : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        let outside = source.view.window.map { !$0.frame.insetBy(dx: -12, dy: -12).contains(screenPoint) } ?? false
        session.animatesToStartingPositionsOnCancelOrFail = !outside || cancelled
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil; chip?.alphaValue = 1
        (chip?.window as? ExplorerWindow)?.endTabGesture()
        source.tabBar?.clearInsertion()
        let escape = NSApp.currentEvent.map { $0.type == .keyDown && $0.keyCode == 53 } ?? false
        let outside = source.view.window.map { !$0.frame.insetBy(dx: -12, dy: -12).contains(screenPoint) } ?? false
        let detach = TabPlacement.shouldDetach(accepted: accepted || !operation.isEmpty, cancelled: cancelled || escape,
            mouseReleased: NSEvent.pressedMouseButtons & 1 == 0, outsideSourceWindow: outside)
        Self.current = nil
        if detach {
            DispatchQueue.main.async { [source, id] in source.moveTabToNewWindow(id: id, at: screenPoint) }
        }
    }
}

@MainActor
final class TabStripScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame); contentView = TabStripClipView()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class TabStripClipView: NSClipView {
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor
final class TabStripDocumentView: Surface {
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor
private final class TabInsertionMarker: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 0), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

@MainActor
final class TabBarView: TitlebarSurface {
    weak var browser: BrowserViewController?
    private let marker = TabInsertionMarker()
    override init(frame: NSRect) {
        super.init(frame: frame); registerForDraggedTypes([TabDragSession.pasteboardType])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateInsertion(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateInsertion(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearInsertion() }
    override func draggingEnded(_ sender: NSDraggingInfo) { clearInsertion() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !updateInsertion(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { acceptTab(sender) }

    private func insertionSlot(_ info: NSDraggingInfo, scroll: Bool) -> Int? {
        guard let browser, browser.canTransferTabs, TabDragSession.validated(info) != nil else { return nil }
        let point = convert(info.draggingLocation, from: nil)
        guard bounds.contains(point), point.x >= browser.tabsScroll.frame.minX else { return nil }
        let clip = browser.tabsScroll.contentView
        if scroll {
            let edge = convert(info.draggingLocation, from: nil).x - browser.tabsScroll.frame.minX
            let delta: CGFloat = edge < 24 ? -18 : edge > clip.bounds.width - 24 && edge < clip.bounds.width ? 18 : 0
            let limit = max(0, browser.tabsDocument.bounds.width - clip.bounds.width)
            clip.scroll(to: NSPoint(x: min(limit, max(0, clip.bounds.minX + delta)), y: 0))
            browser.tabsScroll.reflectScrolledClipView(clip)
        }
        let x = browser.tabsDocument.convert(info.draggingLocation, from: nil).x
        return min(browser.tabs.count, max(0, Int(floor((x + 108) / 216))))
    }
    func updateInsertion(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let browser, let slot = insertionSlot(info, scroll: true) else { clearInsertion(); return [] }
        let x = convert(NSPoint(x: CGFloat(slot) * 216, y: 0), from: browser.tabsDocument).x
        let left = browser.tabsScroll.frame.minX, right = browser.tabsScroll.frame.maxX
        marker.frame = NSRect(x: min(right - 2, max(left, x - 2)), y: 5, width: 4, height: max(0, bounds.height - 10))
        addSubview(marker, positioned: .above, relativeTo: nil)
        return .move
    }
    func clearInsertion() { marker.removeFromSuperview() }
    func acceptTab(_ info: NSDraggingInfo) -> Bool {
        defer { clearInsertion() }
        guard let browser, let slot = insertionSlot(info, scroll: false), let drag = TabDragSession.validated(info) else { return false }
        drag.accepted = browser.receiveTab(id: drag.id, from: drag.source, before: slot)
        return drag.accepted
    }
}
