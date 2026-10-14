import AppKit
import Carbon

/// Finder owns the native Get Info UI. Paths are Apple-event parameters, never
/// interpolated AppleScript source, and no keyboard/UI scripting is involved.
actor FinderInformation {
    static let shared = FinderInformation()
    static func arguments(for urls: [URL]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (index, url) in urls.enumerated() { list.insert(NSAppleEventDescriptor(string: url.path), at: index + 1) }
        return list
    }
    func show(_ urls: [URL]) -> String? {
        let source = """
        on run itemPaths
            tell application "Finder"
                repeat with itemPath in itemPaths
                    set targetItem to (POSIX file (contents of itemPath)) as alias
                    open information window of targetItem
                end repeat
                activate
            end tell
        end run
        """
        guard let script = NSAppleScript(source: source) else { return "Could not prepare Finder’s Get Info command." }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                                          targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(Self.arguments(for: urls), forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        script.executeAppleEvent(event, error: &error)
        guard let error else { return nil }
        if (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -1743 {
            return "Allow Explorer to control Finder in System Settings → Privacy & Security → Automation, then try Properties again."
        }
        return error[NSAppleScript.errorMessage] as? String ?? "Finder could not open Get Info for this selection."
    }
}

@MainActor
enum FileProperties {
    static func show(_ urls: [URL], window: NSWindow?) {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return }
        Task {
            if let error = await FinderInformation.shared.show(urls) {
                let alert = NSAlert(); alert.messageText = "Couldn’t Open Properties"; alert.informativeText = error
                if let window, window.attachedSheet == nil { await alert.beginSheetModal(for: window) }
                else { alert.runModal() }
            }
        }
    }
    static func item(urls: [URL], window: NSWindow?) -> NSMenuItem {
        ContextMenu.item("Properties", symbol: "info.circle") { [weak window] in show(urls, window: window) }
    }
}
