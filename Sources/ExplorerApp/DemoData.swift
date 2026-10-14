import AppKit
import ExplorerCore

/// Only the separate bundle produced by scripts/demo.sh enables this mode.
/// Sample drives are fictional; file browsing still uses ordinary temporary files.
@MainActor
enum DemoData {
    static var active: Bool { Bundle.main.object(forInfoDictionaryKey: "ExplorerDemo") as? Bool == true }
    static var root: URL {
        URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "ExplorerDemoRoot") as? String ?? "/tmp/MacExplorer Demo", isDirectory: true)
    }
    static var favorites: Favorites {
        Favorites([Favorite(url: root, name: "Home")] + ["Projects", "Documents", "Pictures", "Downloads"].map {
            Favorite(url: root.appendingPathComponent($0), name: $0)
        })
    }
    static var session: WorkspaceSession {
        WorkspaceSession(left: PaneSession(paths: [BrowserLocation.stored(BrowserLocation.thisMac), root.appendingPathComponent("Projects").path,
                                                   root.appendingPathComponent("Pictures").path]))
    }
    static var locations: [StorageLocation] {
        let gb: Int64 = 1_000_000_000
        func drive(_ name: String, _ kind: StorageLocation.Kind, total: Int64, free: Int64) -> StorageLocation {
            StorageLocation(url: root.appendingPathComponent("Devices/" + name), title: name,
                            detail: kind == .internalDrive ? "Local disk" : kind == .network ? "Network drive" : "External volume",
                            kind: kind, capacity: StorageCapacity(total: total * gb, available: free * gb))
        }
        let google = root.appendingPathComponent("Cloud/Google Drive")
        return [drive("Macintosh HD", .internalDrive, total: 1000, free: 428),
                drive("Studio SSD", .externalDrive, total: 2000, free: 1240),
                drive("Archive", .externalDrive, total: 500, free: 34),
                drive("Shared Projects", .network, total: 4000, free: 2160),
                StorageLocation(url: google, title: "Google Drive", detail: "Google Drive · demo@example.test", kind: .googleDrive, children: [
                    StorageLocation(url: google.appendingPathComponent("My Drive"), title: "My Drive", detail: "Google Drive · demo@example.test", kind: .googleDrive),
                    StorageLocation(url: google.appendingPathComponent("Shared drives"), title: "Shared drives", detail: "Google Drive · demo@example.test", kind: .googleDrive)
                ]),
                StorageLocation(url: root.appendingPathComponent("Cloud/OneDrive"), title: "OneDrive", detail: "Sample workspace", kind: .cloud)]
    }
    static func configure() {
        guard active else { return }
        UserDefaults.standard.setVolatileDomain([
            "explorer.shortcut.enabled": false, "explorer.appearance": "light", "explorer.showHidden": false,
            "explorer.searchScope": "subfolders", "explorer.viewMode": "details", "explorer.startup": "restore"
        ], forName: UserDefaults.argumentDomain)
    }
    static func exportScreenshot(of controller: ExplorerWindowController) throws {
        guard active, let window = controller.window, let frame = window.contentView?.superview,
              let output = Bundle.main.object(forInfoDictionaryKey: "ExplorerScreenshotDirectory") as? String else { return }
        frame.layoutSubtreeIfNeeded()
        guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let name = controller.workspace.dualPane ? "dual-pane" : controller.browser.tab.hasSearchQuery ? "search" : controller.browser.tab.isThisMac ? "this-mac" : "files"
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
