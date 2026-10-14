import AppKit
import ExplorerCore
import Testing
@testable import ExplorerApp

@Suite @MainActor
struct ExternalApplicationsTests {
    @Test func editorRecognizesCodeConfigurationAndExtensionlessText() {
        for name in ["config.YAML", "compose.yml", "package.json", "settings.jsonc", "Cargo.toml", ".env.local", ".gitignore", ".zshrc", "Dockerfile", "Makefile", "LICENSE", "notes.md", "script.sh", "source.swift"] {
            #expect(TextFileTypes.recognizes(URL(fileURLWithPath: "/tmp/" + name)), "Missing text type: \(name)")
        }
        for name in ["photo.png", "archive.zip", "program.dmg"] { #expect(!TextFileTypes.recognizes(URL(fileURLWithPath: "/tmp/" + name))) }
    }

    @Test func terminalTargetsFolderOrContainingFolderWithoutChangingPath() {
        let folder = URL(fileURLWithPath: "/tmp/Space & Quote's $(literal)/日本語", isDirectory: true)
        let file = FileItem(url: folder.appendingPathComponent("config.yaml"), name: "config.yaml", isDirectory: false)
        let directory = FileItem(url: folder, name: folder.lastPathComponent, isDirectory: true)
        #expect(ExternalApplications.terminalDirectory(items: [], currentFolder: folder) == folder)
        #expect(ExternalApplications.terminalDirectory(items: [directory], currentFolder: nil) == folder)
        #expect(ExternalApplications.terminalDirectory(items: [file], currentFolder: nil) == folder)
        #expect(ExternalApplications.terminalDirectory(items: [file, directory], currentFolder: folder) == nil)
        #expect(ExternalApplications.terminalDirectory(items: [], currentFolder: BrowserLocation.thisMac) == nil)
        #expect(ExternalApplications.canEdit([file]))
        #expect(!ExternalApplications.canEdit([directory]))
        #expect(!ExternalApplications.canEdit([file, directory]))
        #expect(!ExternalApplications.canEdit([]))
    }

    @Test func applicationPreferencesPersistResetAndKeepMissingChoice() throws {
        let name = "Explorer.ExternalAppsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.terminalApplication == nil)
        #expect(preferences.editorApplication == nil)
        #expect(ExternalApplications.name(for: .terminal, preferences: preferences) == "Terminal")
        #expect(ExternalApplications.name(for: .editor, preferences: preferences) == "TextEdit")
        let missing = ApplicationChoice(url: URL(fileURLWithPath: "/tmp/Explorer-Missing-\(UUID()).app"))
        preferences.terminalApplication = missing; preferences.editorApplication = missing
        let reloaded = AppPreferences(defaults: defaults)
        #expect(reloaded.terminalApplication == missing)
        #expect(reloaded.editorApplication == missing)
        // Never silently open a different app after the preferred one is removed.
        #expect(ExternalApplications.url(for: .terminal, preferences: reloaded) == nil)
        reloaded.terminalApplication = nil
        #expect(preferences.terminalApplication == nil)
        #expect(preferences.editorApplication == missing)
        defaults.set(Data("invalid".utf8), forKey: "explorer.applications.editor")
        #expect(preferences.editorApplication == nil)
    }

    @Test func paletteDispatchesTheSelectedActionAndPreservesDisabledStates() throws {
        _ = NSApplication.shared
        let menu = NSMenu(); ContextMenu.configure(menu)
        var performed: [FileAction] = []
        ContextMenu.addFileActions(to: menu, enabled: { $0 == .copy }) { performed.append($0) }
        let palette = try #require(menu.items.first?.submenu)
        #expect(palette.presentationStyle == .palette)
        #expect(palette.items.count == 5)
        #expect(palette.items.filter(\.isEnabled).map(\.title) == ["Copy"])
        let copy = try #require(palette.items.first { $0.title == "Copy" })
        #expect(NSApp.sendAction(try #require(copy.action), to: copy.target, from: copy))
        #expect(performed == [.copy])
        #expect(palette.items.allSatisfy { $0.image != nil && $0.toolTip != nil })
    }
}
