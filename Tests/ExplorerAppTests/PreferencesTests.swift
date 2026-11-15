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

    @Test func interfaceLanguagePersistsAndInvalidValuesUseAutomatic() throws {
        let name = "Explorer.PreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.interfaceLanguage == nil)
        preferences.interfaceLanguage = .english
        #expect(AppPreferences(defaults: defaults).interfaceLanguage == .english)
        #expect(defaults.string(forKey: InterfaceLanguage.preferenceKey) == "en")
        preferences.interfaceLanguage = nil
        #expect(defaults.string(forKey: InterfaceLanguage.preferenceKey) == nil)
        defaults.set("invalid", forKey: InterfaceLanguage.preferenceKey)
        #expect(preferences.interfaceLanguage == nil)
    }

    @Test func languageMenuListsAvailableLanguagesAndCanRestoreAutomatic() throws {
        _ = NSApplication.shared
        let name = "Explorer.PreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(defaults: defaults)
        let controller = SettingsWindowController(preferences: preferences,
                                                  shortcutController: GlobalShortcutController(registrar: FakeRegistrar()),
                                                  updates: AppUpdateController())
        let tabs = try #require(controller.window?.contentViewController as? NSTabViewController)
        let general = try #require(tabs.tabViewItems.first?.viewController?.view)
        let stack = try #require(general.subviews.first as? NSStackView)
        let controls = stack.arrangedSubviews.compactMap { $0 as? NSStackView }.flatMap(\.arrangedSubviews)
        let install = try #require(controls.compactMap { $0 as? NSButton }
            .first { $0.title == L10n.text("Install Language Packs…") })
        #expect(install.isEnabled && install.action != nil)
        let popups = controls.compactMap { $0 as? NSPopUpButton }
        let popup = try #require(popups.first { $0.accessibilityLabel() == L10n.text("Interface language") })
        #expect(popup.itemTitles == [L10n.text("Automatic (macOS)")] + InterfaceLanguage.available.map(\.title))
        #expect(popup.indexOfSelectedItem == 0)

        let index = try #require(InterfaceLanguage.available.firstIndex(of: .english))
        let action = try #require(popup.action)
        popup.selectItem(at: index + 1)
        #expect(NSApp.sendAction(action, to: popup.target, from: popup))
        #expect(preferences.interfaceLanguage == .english)
        popup.selectItem(at: 0)
        #expect(NSApp.sendAction(action, to: popup.target, from: popup))
        #expect(preferences.interfaceLanguage == nil)
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
