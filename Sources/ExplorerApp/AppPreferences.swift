import AppKit
import ExplorerCore

enum StartupLocation: String, CaseIterable {
    case restore, thisMac, home, downloads
    var title: String {
        switch self {
        case .restore: "Restore previous tabs"
        case .thisMac: "This Mac"
        case .home: "Home"
        case .downloads: "Downloads"
        }
    }
}

enum AppAppearance: String, CaseIterable {
    case system, light, dark
    var title: String { rawValue.capitalized }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class AppPreferences {
    static let shared = AppPreferences()
    static let changed = Notification.Name("ExplorerPreferencesChanged")
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func set(_ value: Any, for key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    var shortcutEnabled: Bool {
        get { defaults.object(forKey: "explorer.shortcut.enabled") as? Bool ?? true }
        set { set(newValue, for: "explorer.shortcut.enabled") }
    }
    var shortcut: LaunchShortcut {
        get {
            guard let data = defaults.data(forKey: "explorer.shortcut.binding"),
                  let value = try? JSONDecoder().decode(LaunchShortcut.self, from: data), value.isValid else { return .defaultShortcut }
            return value
        }
        set { if newValue.isValid, let data = try? JSONEncoder().encode(newValue) { set(data, for: "explorer.shortcut.binding") } }
    }
    var shortcutOpensNewWindow: Bool {
        get { defaults.bool(forKey: "explorer.shortcut.newWindow") }
        set { set(newValue, for: "explorer.shortcut.newWindow") }
    }
    var startupLocation: StartupLocation {
        get { StartupLocation(rawValue: defaults.string(forKey: "explorer.startup") ?? "") ?? .restore }
        set { set(newValue.rawValue, for: "explorer.startup") }
    }
    var appearance: AppAppearance {
        get { AppAppearance(rawValue: defaults.string(forKey: "explorer.appearance") ?? "") ?? .system }
        set { set(newValue.rawValue, for: "explorer.appearance") }
    }
    var viewMode: FileViewMode {
        get { FileViewMode(rawValue: defaults.string(forKey: "explorer.viewMode") ?? "") ?? .details }
        set { set(newValue.rawValue, for: "explorer.viewMode") }
    }
    var searchScope: SearchScope {
        get { SearchScope(rawValue: defaults.string(forKey: "explorer.searchScope") ?? "") ?? .subfolders }
        set { set(newValue.rawValue, for: "explorer.searchScope") }
    }
    var showHidden: Bool {
        get { defaults.bool(forKey: "explorer.showHidden") }
        set { set(newValue, for: "explorer.showHidden") }
    }
    var terminalApplication: ApplicationChoice? {
        get { application(for: "explorer.applications.terminal") }
        set { setApplication(newValue, for: "explorer.applications.terminal") }
    }
    var editorApplication: ApplicationChoice? {
        get { application(for: "explorer.applications.editor") }
        set { setApplication(newValue, for: "explorer.applications.editor") }
    }
    private func application(for key: String) -> ApplicationChoice? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ApplicationChoice.self, from: $0) }
    }
    private func setApplication(_ choice: ApplicationChoice?, for key: String) {
        if let choice, let data = try? JSONEncoder().encode(choice) { set(data, for: key) }
        else { defaults.removeObject(forKey: key); NotificationCenter.default.post(name: Self.changed, object: self) }
    }
    func openingSession(restored: WorkspaceSession) -> WorkspaceSession {
        let path: String
        switch startupLocation {
        case .restore: return restored
        case .thisMac: path = BrowserLocation.stored(BrowserLocation.thisMac)
        case .home: path = FileManager.default.homeDirectoryForCurrentUser.path
        case .downloads: path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        }
        return WorkspaceSession(left: PaneSession(paths: [path]))
    }
}
