import AppKit
import ExplorerCore

enum FileAction: String, CaseIterable {
    case cut, copy, paste, move, rename, newFolder, trash, compress, extract, properties, undo, cancel
    var title: String {
        switch self {
        case .cut: "Cut"
        case .copy: "Copy"
        case .paste: "Paste"
        case .move: "Move to Folder…"
        case .rename: "Rename…"
        case .newFolder: "New Folder…"
        case .trash: "Move to Trash"
        case .compress: "Compress to ZIP"
        case .extract: "Extract All…"
        case .properties: "Properties"
        case .undo: "Undo"
        case .cancel: "Cancel Operation"
        }
    }
}

@MainActor
final class FileOperationController {
    static let shared = FileOperationController()
    static let changed = Notification.Name("ExplorerFileOperationsChanged")
    static let finished = Notification.Name("ExplorerFileOperationsFinished")
    private let engine = FileOperationEngine()
    private var task: Task<Void, Never>?
    private var cutChangeCount: Int?
    private var cutURLs: [URL] = []
    private var clipboardTimer: Timer?
    private(set) var busy = false
    private(set) var statusText = ""
    private(set) var undoTitle: String?
    var canPaste: Bool { !busy && !clipboardURLs.isEmpty }
    var cutPaths: Set<String> {
        guard cutChangeCount == NSPasteboard.general.changeCount else { return [] }
        return Set(cutURLs.map(\.path))
    }
    static func itemPath(_ url: URL) -> String {
        let item = url.standardizedFileURL
        return item.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(item.lastPathComponent).path
    }
    private var clipboardURLs: [URL] {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).filter(\.isFileURL)
    }
    private init() {
        // NSPasteboard has no change notification. Poll only while a cut is pending.
    }
    private func notify() { NotificationCenter.default.post(name: Self.changed, object: nil) }
    func copy(_ urls: [URL], cut: Bool) {
        guard !busy, !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents(); pasteboard.writeObjects(urls as [NSURL])
        cutURLs = cut ? urls : []; cutChangeCount = cut ? pasteboard.changeCount : nil
        clipboardTimer?.invalidate(); clipboardTimer = nil
        if cut {
            clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.cutChangeCount != NSPasteboard.general.changeCount { self.clearCut() }
                }
            }
        }
        statusText = cut ? "\(urls.count) cut · Paste to move" : "\(urls.count) copied"
        notify()
    }
    func clearCut() {
        cutURLs = []; cutChangeCount = nil; clipboardTimer?.invalidate(); clipboardTimer = nil; statusText = ""; notify()
    }
    func paste(into folder: URL, window: NSWindow) {
        let urls = clipboardURLs
        guard !busy, !urls.isEmpty else { return }
        let cut = cutChangeCount == NSPasteboard.general.changeCount
        let clipboardVersion = NSPasteboard.general.changeCount
        run(cut ? .move(urls, to: folder) : .copy(urls, to: folder), window: window) { [weak self] report in
            guard let self, cut, self.cutChangeCount == clipboardVersion,
                  NSPasteboard.general.changeCount == clipboardVersion else { return }
            let consumed = Set(report.consumedSources.map(Self.itemPath))
            let remaining = urls.filter { !consumed.contains(Self.itemPath($0)) }
            if remaining.isEmpty {
                NSPasteboard.general.clearContents(); self.clearCut()
            } else if remaining.count != urls.count { self.copy(remaining, cut: true) }
        }
    }
    func cancel() {
        guard busy else { clearCut(); return }
        task?.cancel(); statusText = "Cancelling after the current item…"; notify()
    }
    func run(_ operation: FileOperation, window: NSWindow, completion: ((OperationReport) -> Void)? = nil) {
        // Sheet completion handlers run just before AppKit detaches the sheet.
        // The queued Task starts after that handler returns.
        guard !busy else { return }
        busy = true; statusText = "Preparing \(operation.title.lowercased())…"; notify()
        task = Task {
            let report = await engine.perform(operation, resolve: { [weak self, weak window] conflict in
                guard let self, let window else { return ConflictResolution(.cancel) }
                return await self.resolve(conflict, window: window)
            }, progress: { [weak self] progress in await self?.showProgress(progress) })
            undoTitle = await engine.undoTitle
            busy = false; task = nil; completion?(report)
            finish(report, title: operation.title, window: window)
        }
    }
    func undo(window: NSWindow) {
        guard !busy, undoTitle != nil, window.attachedSheet == nil else { return }
        busy = true; statusText = "Checking items for undo…"; notify()
        task = Task {
            let report = await engine.undo(progress: { [weak self] progress in await self?.showProgress(progress) })
            undoTitle = await engine.undoTitle; busy = false; task = nil
            finish(report, title: "Undo", window: window)
        }
    }
    private func showProgress(_ progress: OperationProgress) {
        statusText = "\(progress.title) · \(progress.index) of \(progress.total) · \(progress.item)"; notify()
    }
    private func finish(_ report: OperationReport, title: String, window: NSWindow) {
        statusText = report.cancelled ? "Cancelled · completed items can be undone" : "\(title) complete"
        if report.skipped > 0 { statusText += " · \(report.skipped) skipped" }
        notify()
        NotificationCenter.default.post(name: Self.finished, object: nil,
                                        userInfo: ["completed": report.completed, "metadataOnly": report.metadataOnly])
        if let error = report.error {
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "\(title) couldn’t finish"
            alert.informativeText = error + (report.completed.isEmpty ? "" : "\n\nCompleted items are still available in Undo.")
            alert.addButton(withTitle: "OK"); alert.beginSheetModal(for: window)
        }
    }
    private func resolve(_ conflict: FileConflict, window: NSWindow) async -> ConflictResolution {
        guard !Task.isCancelled else { return ConflictResolution(.cancel) }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "“\(conflict.destination.lastPathComponent)” already exists"
        alert.informativeText = "From: \(conflict.source.path)\nTo: \(conflict.destination.path)\n\n" +
            (conflict.destinationIsDirectory ? "Replace sends the entire existing folder to Trash; folders are not merged." : "Replace sends the existing item to Trash so it can be restored with Undo.")
        // Keep Both is the safe default. Escape cancels the remaining batch.
        ["Keep Both", "Replace", "Skip", "Cancel"].forEach { alert.addButton(withTitle: $0) }
        alert.buttons[3].keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Apply to all remaining conflicts"
        let response = await alert.beginSheetModal(for: window)
        let choice: ConflictChoice
        switch response {
        case .alertFirstButtonReturn: choice = .keepBoth
        case .alertSecondButtonReturn: choice = .replace
        case .alertThirdButtonReturn: choice = .skip
        default: choice = .cancel
        }
        return ConflictResolution(choice, applyToAll: alert.suppressionButton?.state == .on)
    }

    func askName(title: String, initial: String, selectStem: Bool, window: NSWindow,
                 submit: @escaping (String) -> Void) {
        guard !busy, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = title
        alert.addButton(withTitle: title == "New Folder" ? "Create" : "Rename"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 340, height: 26)
        field.setAccessibilityLabel("Name"); alert.accessoryView = field; alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            do { try FileOperationEngine.validateName(field.stringValue); submit(field.stringValue) }
            catch {
                let errorAlert = NSAlert(); errorAlert.messageText = "That name can’t be used"
                errorAlert.informativeText = error.localizedDescription; errorAlert.beginSheetModal(for: window)
            }
        }
        field.selectText(nil)
        if selectStem, let editor = field.currentEditor() {
            let ext = (initial as NSString).pathExtension
            let length = (initial as NSString).length - (ext.isEmpty ? 0 : (ext as NSString).length + 1)
            editor.selectedRange = NSRange(location: 0, length: length)
        }
    }
}
