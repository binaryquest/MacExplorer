import AppKit
import ExplorerCore

/// Marker identifies drags originating in Explorer without trusting pasteboard strings.
@MainActor protocol ExplorerDragSource: AnyObject {}
extension FileTableView: ExplorerDragSource {}

@MainActor final class FolderOutlineView: NSOutlineView, ExplorerDragSource {}

@MainActor
enum FileDrag {
    static func plan(_ info: NSDraggingInfo, to destination: URL) -> FileDropPlan? {
        guard !FileOperationController.shared.busy else { return nil }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let flags = NSEvent.modifierFlags.intersection([.option, .control, .shift])
        return FileDropPlan.make(sources: urls, destination: destination,
            internalDrag: info.draggingSource is any ExplorerDragSource,
            copyRequested: flags.contains(.option) || flags.contains(.control), moveRequested: flags.contains(.shift),
            supportsCopy: info.draggingSourceOperationMask.contains(.copy), supportsMove: info.draggingSourceOperationMask.contains(.move))
    }
    static func operation(_ info: NSDraggingInfo, to destination: URL) -> NSDragOperation {
        guard let plan = plan(info, to: destination) else { return [] }
        return plan.action == .copy ? .copy : .move
    }
    static func accept(_ info: NSDraggingInfo, to destination: URL, window: NSWindow?) -> Bool {
        guard let window, window.attachedSheet == nil, let plan = plan(info, to: destination) else { return false }
        FileOperationController.shared.run(plan.operation, window: window)
        return true
    }
}

@MainActor
class FolderDropSurface: Surface {
    var dropDestination: (() -> URL?)?
    var onDragHover: (() -> Void)?
    private var hoverTask: Task<Void, Never>?
    private var acceptingDrop = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    private func updateDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = dropDestination?().map { FileDrag.operation(sender, to: $0) } ?? []
        acceptingDrop = !operation.isEmpty && window?.attachedSheet == nil
        if acceptingDrop, hoverTask == nil, let onDragHover {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }; onDragHover()
            }
        }
        if !acceptingDrop { hoverTask?.cancel(); hoverTask = nil }
        return acceptingDrop ? operation : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { resetDrop() }
    override func draggingEnded(_ sender: NSDraggingInfo) { resetDrop() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !updateDrop(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { resetDrop() }
        guard let destination = dropDestination?() else { return false }
        return FileDrag.accept(sender, to: destination, window: window)
    }
    private func resetDrop() { hoverTask?.cancel(); hoverTask = nil; acceptingDrop = false }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if acceptingDrop {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7)
            path.lineWidth = 2; path.stroke()
        }
    }
}
