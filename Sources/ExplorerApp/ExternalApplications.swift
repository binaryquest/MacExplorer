import AppKit
import UniformTypeIdentifiers
import ExplorerCore

struct ApplicationChoice: Codable, Equatable {
    let bundleIdentifier: String?
    let path: String
    let bookmark: Data?

    init(url: URL) {
        bundleIdentifier = Bundle(url: url)?.bundleIdentifier
        path = url.path
        bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    @MainActor var resolvedURL: URL? {
        var stale = false
        if let bookmark, let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                           relativeTo: nil, bookmarkDataIsStale: &stale), Self.isApplication(url) { return url }
        let original = URL(fileURLWithPath: path)
        if Self.isApplication(original), Bundle(url: original)?.bundleIdentifier == bundleIdentifier { return original }
        return bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    static func isApplication(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "app" && FileManager.default.fileExists(atPath: url.path)
            && Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
    }
}

enum ExternalApplicationRole: String {
    case terminal, editor
    var defaultIdentifier: String { self == .terminal ? "com.apple.Terminal" : "com.apple.TextEdit" }
    var defaultName: String { self == .terminal ? "Terminal" : "TextEdit" }
    var installedCandidates: [String] {
        self == .terminal ? ["com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty"]
            : ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.sublimetext.4", "com.sublimetext.3", "com.barebones.bbedit", "dev.zed.Zed", "com.macromates.TextMate", "com.coteditor.CotEditor"]
    }
}

enum TextFileTypes {
    private static let extensions: Set<String> = Set("txt text md markdown rst log yaml yml json jsonc jsonl ndjson toml ini conf config cfg env properties csv tsv xml svg html htm css scss sass less js jsx ts tsx mjs cjs py rb php pl sh bash zsh fish swift c h cpp hpp cc cs java kt kts go rs sql graphql gql proto tf tfvars tex bib diff patch gitignore gitattributes gitmodules editorconfig lock dockerfile makefile cmake".split(separator: " ").map(String.init))
    private static let names: Set<String> = ["dockerfile", "containerfile", "makefile", "gemfile", "rakefile", "license", "readme", ".gitignore", ".gitattributes", ".gitconfig", ".gitmodules", ".editorconfig", ".env", ".npmrc", ".yarnrc", ".zshrc", ".bashrc", ".bash_profile", ".profile"]
    static func recognizes(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased(), ext = url.pathExtension.lowercased()
        if names.contains(name) || name.hasPrefix(".env.") || extensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .text) || type.conforms(to: .sourceCode)
    }
}

@MainActor
enum ExternalApplications {
    static func choice(for role: ExternalApplicationRole, preferences: AppPreferences = .shared) -> ApplicationChoice? {
        role == .terminal ? preferences.terminalApplication : preferences.editorApplication
    }
    static func url(for role: ExternalApplicationRole, preferences: AppPreferences = .shared) -> URL? {
        if let choice = choice(for: role, preferences: preferences) { return choice.resolvedURL }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: role.defaultIdentifier)
    }
    static func name(of url: URL) -> String {
        if Bundle(url: url)?.bundleIdentifier == "com.googlecode.iterm2" { return "iTerm2" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    static func name(for role: ExternalApplicationRole, preferences: AppPreferences = .shared) -> String {
        if let url = url(for: role, preferences: preferences) { return name(of: url) }
        return choice(for: role, preferences: preferences).map { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent } ?? role.defaultName
    }
    static func terminalDirectory(items: [FileItem], currentFolder: URL?) -> URL? {
        guard items.count <= 1 else { return nil }
        if let item = items.first { return item.isNavigable ? item.url : item.url.deletingLastPathComponent() }
        return currentFolder?.isFileURL == true ? currentFolder : nil
    }
    static func canEdit(_ items: [FileItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { !$0.isDirectory && !$0.isPackage && $0.url.isFileURL }
    }
    static func editorTitle(for urls: [URL]) -> String {
        "Open \(urls.allSatisfy(TextFileTypes.recognizes) ? "with" : "as Text with") \(name(for: .editor))"
    }
    static func openTerminal(at folder: URL, window: NSWindow?) {
        do { try FileSystem.validateDirectory(folder) }
        catch { showError(error.localizedDescription, window: window); return }
        open([folder], role: .terminal, window: window)
    }
    static func openEditor(files: [URL], window: NSWindow?) {
        guard !files.isEmpty, files.allSatisfy(\.isFileURL) else { return }
        open(files, role: .editor, window: window)
    }
    private static func open(_ urls: [URL], role: ExternalApplicationRole, window: NSWindow?) {
        guard let app = url(for: role) else {
            showError("\(name(for: role)) could not be found. Choose another application in Explorer Settings → Applications.", window: window)
            return
        }
        open(urls, with: app, window: window)
    }
    static func open(_ urls: [URL], with app: URL, window: NSWindow?) {
        // Send document/folder URLs directly. Paths never become shell commands,
        // and scripts opened in the editor are documents, not executables.
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: .init()) { _, error in
            if let error { Task { @MainActor in showError(error.localizedDescription, window: window) } }
        }
    }
    static func showError(_ message: String, window: NSWindow?) {
        let alert = NSAlert(); alert.messageText = "Couldn’t Open Application"; alert.informativeText = message
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
    static func terminalItem(folder: URL, window: NSWindow?, containing: Bool = false) -> NSMenuItem {
        ContextMenu.item("Open \(containing ? "Containing Folder " : "")in \(name(for: .terminal))", symbol: "terminal") { [weak window] in
            openTerminal(at: folder, window: window)
        }
    }
}
