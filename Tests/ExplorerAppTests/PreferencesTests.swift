import AppKit
import Carbon
import ExplorerCore
import Testing
@testable import ExplorerApp

@Suite @MainActor
struct PreferencesTests {
    @Test func preferencesPersistAndStartupRetainsTheSavedWorkspace() throws {
        let name = "Explorer.PreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.shortcutEnabled)
        #expect(preferences.shortcut == .defaultShortcut)
        #expect(preferences.searchScope == .subfolders)
        #expect(preferences.appearance == .system)
        let session = WorkspaceSession(left: PaneSession(paths: ["/tmp", "/Users"], active: 1, modes: ["details", "large"]),
                                       right: PaneSession(paths: ["/"]), dualPane: true, activeRight: true)
        #expect(preferences.openingSession(restored: session) == session)
        preferences.startupLocation = .thisMac
        #expect(preferences.openingSession(restored: session).left.paths == [BrowserLocation.stored(BrowserLocation.thisMac)])
        #expect(!preferences.openingSession(restored: session).dualPane)
        preferences.appearance = .dark; preferences.searchScope = .folder; preferences.viewMode = .content
        preferences.showHidden = true; preferences.shortcutEnabled = false; preferences.shortcutOpensNewWindow = true
        let binding = LaunchShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue, character: "J")
        preferences.shortcut = binding
        let reloaded = AppPreferences(defaults: defaults)
        #expect(reloaded.shortcut == binding)
        #expect(!reloaded.shortcutEnabled)
        #expect(reloaded.shortcutOpensNewWindow)
        #expect(reloaded.startupLocation == .thisMac)
        #expect(reloaded.appearance == .dark)
        #expect(reloaded.searchScope == .folder)
        #expect(reloaded.viewMode == .content)
        #expect(reloaded.showHidden)
    }

    @Test func corruptedOrUnsafeBindingsFallBackToCommandE() throws {
        let name = "Explorer.PreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(defaults: defaults)
        defaults.set(Data("broken".utf8), forKey: "explorer.shortcut.binding")
        #expect(preferences.shortcut == .defaultShortcut)
        let invalid = LaunchShortcut(keyCode: 14, modifiers: NSEvent.ModifierFlags.shift.rawValue, character: "E")
        defaults.set(try JSONEncoder().encode(invalid), forKey: "explorer.shortcut.binding")
        #expect(preferences.shortcut == .defaultShortcut)
        #expect(!invalid.isValid)
        #expect(LaunchShortcut.defaultShortcut.title == "⌘E")
        #expect(LaunchShortcut.defaultShortcut.carbonModifiers == UInt32(cmdKey))
    }

    @Test func shortcutReplacementKeepsTheOldBindingOnConflictAndDisableReleasesIt() throws {
        let registrar = FakeRegistrar()
        let bindingController = GlobalShortcutController(registrar: registrar)
        try bindingController.apply(.defaultShortcut)
        let originalID = try #require(bindingController.activeID)
        try bindingController.apply(.defaultShortcut)
        #expect(registrar.registrations.count == 1)
        #expect(registrar.attempts == 1)
        let other = LaunchShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, character: "J")
        registrar.reject = true
        #expect(throws: ShortcutError.self) { try bindingController.apply(other) }
        #expect(bindingController.activeID == originalID)
        #expect(bindingController.activeShortcut == .defaultShortcut)
        #expect(registrar.registrations[originalID] == .defaultShortcut)
        registrar.reject = false
        try bindingController.apply(other)
        #expect(bindingController.activeID != originalID)
        #expect(registrar.registrations.count == 1)
        #expect(registrar.registrations[originalID] == nil)
        try bindingController.apply(nil)
        #expect(bindingController.activeID == nil)
        #expect(bindingController.activeShortcut == nil)
        #expect(registrar.registrations.isEmpty)
    }
}

@MainActor
private final class FakeRegistrar: HotKeyRegistrar {
    var registrations: [UInt32: LaunchShortcut] = [:]
    var reject = false, attempts = 0
    func register(_ shortcut: LaunchShortcut, id: UInt32) throws {
        attempts += 1
        if reject { throw ShortcutError.registration(OSStatus(eventHotKeyExistsErr)) }
        registrations[id] = shortcut
    }
    func unregister(id: UInt32) { registrations.removeValue(forKey: id) }
}
