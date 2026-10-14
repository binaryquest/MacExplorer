import AppKit
import ExplorerCore
import ServiceManagement

@MainActor
private final class SettingsWindow: NSWindow {
    weak var recorder: ShortcutRecorder?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recorder?.isRecording == true { recorder?.capture(event); return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class SettingsPageController: NSViewController {
    var onDisappear: (() -> Void)?
    override func viewWillDisappear() { super.viewWillDisappear(); onDisappear?() }
}

@MainActor
final class ShortcutRecorder: NSButton {
    private(set) var isRecording = false
    var onBegin: (() -> Void)?
    var onFinish: ((LaunchShortcut?) -> Void)?
    var onInvalid: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded; font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        target = self; action = #selector(begin)
        setAccessibilityLabel("Record global shortcut")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func begin() {
        guard !isRecording else { return }
        onBegin?(); isRecording = true; title = "Press shortcut…"
        window?.makeFirstResponder(self)
    }
    func cancel() {
        guard isRecording else { return }
        isRecording = false; onFinish?(nil)
    }
    func capture(_ event: NSEvent) {
        guard isRecording else { return }
        if event.keyCode == 53 { cancel(); return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let shortcut = LaunchShortcut(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue,
                                      character: (event.charactersIgnoringModifiers ?? "").uppercased())
        guard shortcut.isValid else { onInvalid?(); return }
        isRecording = false; onFinish?(shortcut)
    }
    override func keyDown(with event: NSEvent) {
        if isRecording { capture(event) } else { super.keyDown(with: event) }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let preferences: AppPreferences
    private let shortcutController: GlobalShortcutController
    private let updates: AppUpdateController
    private let automaticChecks = NSButton(checkboxWithTitle: "Automatically check for updates", target: nil, action: nil)
    private let automaticInstalls = NSButton(checkboxWithTitle: "Download and install updates automatically", target: nil, action: nil)
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private let lastUpdateCheck = NSTextField(labelWithString: "")
    private let checkUpdates = NSButton(title: "Check for Updates…", target: nil, action: nil)
    private let recorder = ShortcutRecorder()
    private let shortcutEnabled = NSButton(checkboxWithTitle: "Enable global shortcut", target: nil, action: nil)
    private let shortcutStatus = NSTextField(wrappingLabelWithString: "")
    private let launchAtLogin = NSButton(checkboxWithTitle: "Open Explorer at login", target: nil, action: nil)
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private let loginSettings = NSButton(title: "Open Login Items Settings…", target: nil, action: nil)
    private let hidden = NSButton(checkboxWithTitle: "Show hidden files and folders", target: nil, action: nil)
    private let startup = NSPopUpButton(), appearance = NSPopUpButton(), viewMode = NSPopUpButton(), scope = NSPopUpButton(), shortcutAction = NSPopUpButton()

    init(preferences: AppPreferences = .shared, shortcutController: GlobalShortcutController, updates: AppUpdateController) {
        self.preferences = preferences; self.shortcutController = shortcutController
        self.updates = updates
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 480),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Explorer Settings"; window.isReleasedWhenClosed = false
        window.delegate = self; window.recorder = recorder; window.setFrameAutosaveName("Explorer.Settings")
        let tabs = NSTabViewController(); tabs.tabStyle = .toolbar
        let general = NSViewController(); general.view = generalView()
        let keyboard = SettingsPageController(); keyboard.view = keyboardView()
        keyboard.onDisappear = { [weak self] in self?.recorder.cancel() }
        let updatePage = NSViewController(); updatePage.view = updatesView()
        for (controller, title, symbol) in [(general, "General", "gearshape"), (keyboard, "Shortcut", "keyboard"), (updatePage, "Updates", "arrow.triangle.2.circlepath")] {
            let item = NSTabViewItem(viewController: controller); item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); tabs.addTabViewItem(item)
        }
        tabs.preferredContentSize = NSSize(width: 590, height: 480)
        window.contentViewController = tabs; window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AppPreferences.changed, object: preferences)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshUpdates), name: AppUpdateController.changed, object: updates)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func page(_ title: String, subtitle: String, content: [NSView]) -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 590, height: 480))
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 20, weight: .semibold)
        let caption = note(subtitle)
        let stack = NSStackView(views: [heading, caption] + content)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.setCustomSpacing(5, after: heading); stack.setCustomSpacing(24, after: caption)
        root.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
                                     stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
                                     stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 25)])
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return root
    }
    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor; return label
    }
    private func row(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 13)
        label.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let stack = NSStackView(views: [label, control]); stack.orientation = .horizontal; stack.spacing = 14
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }
    private func popup(_ popup: NSPopUpButton, titles: [String], action: Selector, label: String) {
        popup.addItems(withTitles: titles); popup.target = self; popup.action = action
        popup.setAccessibilityLabel(label)
    }
    private func generalView() -> NSView {
        popup(startup, titles: StartupLocation.allCases.map(\.title), action: #selector(startupChanged), label: "Open new windows to")
        popup(appearance, titles: AppAppearance.allCases.map(\.title), action: #selector(appearanceChanged), label: "Appearance")
        popup(viewMode, titles: FileViewMode.allCases.map(\.title), action: #selector(viewChanged), label: "Default folder view")
        popup(scope, titles: ["Current folder", "All subfolders"], action: #selector(scopeChanged), label: "Default search scope")
        hidden.target = self; hidden.action = #selector(hiddenChanged)
        launchAtLogin.target = self; launchAtLogin.action = #selector(loginChanged)
        launchAtLogin.isEnabled = !DemoData.active
        loginStatus.font = .systemFont(ofSize: 12); loginStatus.textColor = .secondaryLabelColor
        loginSettings.bezelStyle = .rounded; loginSettings.target = self; loginSettings.action = #selector(openLoginSettings)
        return page("Make Explorer yours", subtitle: "Changes are saved automatically.", content: [
            row("Open new windows to", control: startup), row("Appearance", control: appearance),
            row("Default folder view", control: viewMode), row("Default search scope", control: scope),
            hidden, note("View and search defaults apply to new tabs. Existing tabs keep their layout; the View menu also updates the folder-view default."),
            launchAtLogin, loginStatus, loginSettings
        ])
    }
    private func keyboardView() -> NSView {
        shortcutEnabled.target = self; shortcutEnabled.action = #selector(enabledChanged)
        recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 155).isActive = true
        recorder.onBegin = { [weak self] in
            try? self?.shortcutController.apply(nil)
            self?.showShortcutStatus("Press Command, Control, or Option plus a letter or number. Escape cancels.")
        }
        recorder.onFinish = { [weak self] binding in self?.finishRecording(binding) }
        recorder.onInvalid = { [weak self] in self?.showShortcutStatus(ShortcutError.invalid.localizedDescription, error: true) }
        let reset = NSButton(title: "Use ⌘E", target: self, action: #selector(resetShortcut)); reset.bezelStyle = .rounded
        let controls = NSStackView(views: [recorder, reset]); controls.orientation = .horizontal; controls.spacing = 10
        popup(shortcutAction, titles: ["Show existing window", "Open a new window"], action: #selector(shortcutActionChanged), label: "Shortcut action")
        shortcutStatus.font = .systemFont(ofSize: 12); shortcutStatus.textColor = .secondaryLabelColor
        return page("Explorer, one shortcut away", subtitle: "Open Explorer from any app, like Windows + E.", content: [
            shortcutEnabled, row("Keyboard shortcut", control: controls), row("When pressed", control: shortcutAction),
            shortcutStatus,
            note("Click the shortcut to record a new combination. While enabled, it takes precedence over the same shortcut in other apps."),
            note("Explorer must be running. Closing all browser windows keeps the shortcut available; quitting Explorer disables it until the next launch. Enable Open Explorer at login in General to make it available after signing in.")
        ])
    }
    private func updatesView() -> NSView {
        automaticChecks.target = self; automaticChecks.action = #selector(automaticChecksChanged)
        automaticInstalls.target = self; automaticInstalls.action = #selector(automaticInstallsChanged)
        checkUpdates.bezelStyle = .rounded; checkUpdates.target = updates; checkUpdates.action = #selector(AppUpdateController.checkForUpdates(_:))
        updateStatus.font = .systemFont(ofSize: 12); updateStatus.textColor = .secondaryLabelColor
        lastUpdateCheck.font = .systemFont(ofSize: 12); lastUpdateCheck.textColor = .secondaryLabelColor
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        return page("Keep Explorer up to date", subtitle: "Explorer \(version)", content: [
            automaticChecks, automaticInstalls,
            note("Automatic installation is optional. Explorer waits for file operations to finish before restarting for an update."),
            checkUpdates, lastUpdateCheck, updateStatus
        ])
    }
    @objc private func refreshUpdates() {
        automaticChecks.state = updates.automaticallyChecks ? .on : .off
        automaticChecks.isEnabled = updates.isAvailable
        automaticInstalls.state = updates.automaticallyInstalls ? .on : .off
        automaticInstalls.isEnabled = updates.isAvailable && updates.automaticallyChecks
        checkUpdates.isEnabled = updates.canCheck
        updateStatus.stringValue = updates.status
        lastUpdateCheck.stringValue = updates.lastCheck.map { "Last checked: " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not checked yet"
    }
    @objc private func automaticChecksChanged() { updates.automaticallyChecks = automaticChecks.state == .on }
    @objc private func automaticInstallsChanged() { updates.automaticallyInstalls = automaticInstalls.state == .on }
    @objc private func refresh() {
        startup.selectItem(at: StartupLocation.allCases.firstIndex(of: preferences.startupLocation) ?? 0)
        appearance.selectItem(at: AppAppearance.allCases.firstIndex(of: preferences.appearance) ?? 0)
        viewMode.selectItem(at: FileViewMode.allCases.firstIndex(of: preferences.viewMode) ?? 0)
        scope.selectItem(at: preferences.searchScope == .folder ? 0 : 1)
        hidden.state = preferences.showHidden ? .on : .off
        shortcutEnabled.state = preferences.shortcutEnabled ? .on : .off
        shortcutAction.selectItem(at: preferences.shortcutOpensNewWindow ? 1 : 0)
        if !recorder.isRecording { recorder.title = preferences.shortcut.title; updateShortcutStatus() }
        refreshLoginStatus()
        refreshUpdates()
    }
    private func refreshLoginStatus() {
        let state = SMAppService.mainApp.status
        launchAtLogin.state = state == .enabled || state == .requiresApproval ? .on : .off
        loginSettings.isHidden = state != .requiresApproval
        switch state {
        case .enabled: loginStatus.stringValue = "Explorer will open when you sign in."
        case .requiresApproval: loginStatus.stringValue = "Allow Explorer in macOS Login Items to finish enabling this."
        case .notRegistered: loginStatus.stringValue = "Off. Enable to have the global shortcut ready after login."
        case .notFound: loginStatus.stringValue = "Off. Enable to register this copy of Explorer for login."
        @unknown default: loginStatus.stringValue = "Login status is unavailable."
        }
    }
    private func showShortcutStatus(_ text: String, error: Bool = false) {
        shortcutStatus.stringValue = text; shortcutStatus.textColor = error ? .systemRed : .secondaryLabelColor
    }
    private func updateShortcutStatus() {
        if !preferences.shortcutEnabled { showShortcutStatus("Global shortcut is off.") }
        else if shortcutController.activeShortcut == preferences.shortcut { showShortcutStatus("\(preferences.shortcut.title) is ready to open Explorer.") }
        else { showShortcutStatus("The shortcut is unavailable. Choose another combination or turn it off and on to retry.", error: true) }
    }
    private func finishRecording(_ binding: LaunchShortcut?) {
        do {
            try shortcutController.apply(preferences.shortcutEnabled ? (binding ?? preferences.shortcut) : nil)
            if let binding { preferences.shortcut = binding }
            recorder.title = preferences.shortcut.title; updateShortcutStatus()
        } catch {
            let message = error.localizedDescription
            // Recording temporarily releases the old key; restore it on failure/cancel.
            try? shortcutController.apply(preferences.shortcutEnabled ? preferences.shortcut : nil)
            recorder.title = preferences.shortcut.title
            showShortcutStatus(message + (shortcutController.activeShortcut != nil ? " Your previous shortcut is still active." : ""), error: true)
        }
    }
    @objc private func enabledChanged() {
        recorder.cancel()
        do {
            let enabled = shortcutEnabled.state == .on
            try shortcutController.apply(enabled ? preferences.shortcut : nil)
            preferences.shortcutEnabled = enabled; updateShortcutStatus()
        } catch {
            shortcutEnabled.state = preferences.shortcutEnabled ? .on : .off
            showShortcutStatus(error.localizedDescription, error: true)
        }
    }
    @objc private func resetShortcut() { recorder.cancel(); finishRecording(.defaultShortcut) }
    @objc private func startupChanged() { preferences.startupLocation = StartupLocation.allCases[startup.indexOfSelectedItem] }
    @objc private func appearanceChanged() { preferences.appearance = AppAppearance.allCases[appearance.indexOfSelectedItem] }
    @objc private func viewChanged() { preferences.viewMode = FileViewMode.allCases[viewMode.indexOfSelectedItem] }
    @objc private func scopeChanged() { preferences.searchScope = scope.indexOfSelectedItem == 0 ? .folder : .subfolders }
    @objc private func hiddenChanged() { preferences.showHidden = hidden.state == .on }
    @objc private func shortcutActionChanged() { preferences.shortcutOpensNewWindow = shortcutAction.indexOfSelectedItem == 1 }
    @objc private func loginChanged() {
        do {
            if launchAtLogin.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch {
            refreshLoginStatus(); loginStatus.stringValue = "Could not update login settings: \(error.localizedDescription)"
        }
    }
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    func windowWillClose(_ notification: Notification) { recorder.cancel() }
    func windowDidResignKey(_ notification: Notification) { recorder.cancel() }
}
