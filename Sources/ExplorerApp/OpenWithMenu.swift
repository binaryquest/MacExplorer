import AppKit
import UniformTypeIdentifiers

@MainActor
enum OpenWithMenu {
    /// An app must handle every selected document. Resolve aliases and deduplicate
    /// by bundle path, retaining separate installed versions when macOS offers them.
    static func applications(for urls: [URL],
                             registered: (URL) -> [URL] = NSWorkspace.shared.urlsForApplications(toOpen:),
                             defaultApplication: (URL) -> URL? = NSWorkspace.shared.urlForApplication(toOpen:)) -> (apps: [URL], defaultApp: URL?) {
        guard let first = urls.first else { return ([], nil) }
        func canonical(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }
        var common = Set(registered(first).map(canonical))
        for url in urls.dropFirst() { common.formIntersection(registered(url).map(canonical)) }
        let defaults = urls.map { defaultApplication($0).map(canonical) }
        let preferred = defaults.first.flatMap { $0 }
        let defaultApp = preferred.flatMap { app in defaults.allSatisfy { $0 == app } ? app : nil }
        if let defaultApp { common.insert(defaultApp) }
        let apps = common.sorted {
            if $0 == $1 { return false }
            if $0 == defaultApp { return true }
            if $1 == defaultApp { return false }
            let comparison = ExternalApplications.name(of: $0).localizedStandardCompare(ExternalApplications.name(of: $1))
            return comparison == .orderedSame ? $0.path < $1.path : comparison == .orderedAscending
        }
        return (apps, defaultApp)
    }

    static func item(urls: [URL], window: NSWindow?) -> NSMenuItem {
        let parent = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        let menu = NSMenu(); menu.autoenablesItems = false
        let choices = applications(for: urls)
        let names = choices.apps.map { ExternalApplications.name(of: $0) }
        for app in choices.apps {
            let name = ExternalApplications.name(of: app)
            let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let suffix = names.filter { $0 == name }.count > 1 ? " (\(version ?? app.deletingLastPathComponent().lastPathComponent))" : ""
            let item = ContextMenu.item(name + suffix + (app == choices.defaultApp ? " (Default)" : ""), symbol: "app") { [weak window] in
                ExternalApplications.open(urls, with: app, window: window)
            }
            let icon = NSWorkspace.shared.icon(forFile: app.path).copy() as? NSImage
            icon?.size = NSSize(width: 16, height: 16); item.image = icon; item.toolTip = app.path
            menu.addItem(item)
        }
        if choices.apps.isEmpty {
            let empty = NSMenuItem(title: "No Registered Applications", action: nil, keyEquivalent: "")
            empty.isEnabled = false; menu.addItem(empty)
        }
        menu.addItem(.separator())
        menu.addItem(ContextMenu.item("Other…", symbol: "ellipsis") { [weak window] in
            guard let window, window.attachedSheet == nil else { return }
            let panel = NSOpenPanel(); panel.title = "Open With"; panel.prompt = "Open"
            panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let app = panel.url {
                    ExternalApplications.open(urls, with: app, window: window)
                }
            }
        })
        parent.submenu = menu
        return parent
    }
}
