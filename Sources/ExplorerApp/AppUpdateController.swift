import AppKit
import Sparkle

struct UpdateConfiguration {
    let enabled: Bool
    let feedURL: String
    let publicKey: String

    init(info: [String: Any]) {
        enabled = info["ExplorerUpdatesEnabled"] as? Bool == true && info["ExplorerDemo"] as? Bool != true
        feedURL = info["SUFeedURL"] as? String ?? ""
        publicKey = info["SUPublicEDKey"] as? String ?? ""
    }
    var isValid: Bool {
        guard enabled, let url = URL(string: feedURL), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil, Data(base64Encoded: publicKey)?.count == 32 else { return false }
        return true
    }
}

@MainActor
final class UpdateRelaunchGate {
    private var pending: (() -> Void)?
    private let isReady: () -> Bool
    init(isReady: @escaping () -> Bool) { self.isReady = isReady }
    func postpone(_ handler: @escaping () -> Void) -> Bool {
        guard !isReady() else { return false }
        pending = handler
        return true
    }
    func resumeIfReady() {
        guard isReady(), let handler = pending else { return }
        pending = nil
        handler()
    }
    var hasPendingRelaunch: Bool { pending != nil }
}

@MainActor
final class AppUpdateController: NSObject, SPUUpdaterDelegate {
    static let changed = Notification.Name("ExplorerUpdatesChanged")
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    private var relaunchTimer: Timer?
    private let gate = UpdateRelaunchGate {
        !FileOperationController.shared.busy && NSApp.modalWindow == nil && !NSApp.windows.contains { $0.attachedSheet != nil }
    }
    private(set) var status = "Automatic updates are available in official releases."
    var isAvailable: Bool { controller != nil }
    var canCheck: Bool { controller?.updater.canCheckForUpdates == true }
    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; notify() }
    }
    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue; notify() }
    }

    func start() {
        guard controller == nil, UpdateConfiguration(info: Bundle.main.infoDictionary ?? [:]).isValid else { return }
        let value = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try value.updater.start()
            controller = value
            status = "Updates are downloaded securely from bquick.io."
            observations = [
                value.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.notify() } },
                value.updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.notify() } },
                value.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.notify() } },
                value.updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.notify() } }
            ]
        } catch { status = "Updates could not start: \(error.localizedDescription)" }
        notify()
    }
    @objc func checkForUpdates(_ sender: Any?) { controller?.checkForUpdates(sender) }
    private func notify() { NotificationCenter.default.post(name: Self.changed, object: self) }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard gate.postpone(installHandler) else { return false }
        status = "Update ready. Waiting for file operations and dialogs to finish."
        notify()
        relaunchTimer?.invalidate()
        relaunchTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(resumeUpdateIfReady), userInfo: nil, repeats: true)
        return true
    }
    @objc private func resumeUpdateIfReady() {
        gate.resumeIfReady()
        if !gate.hasPendingRelaunch { relaunchTimer?.invalidate(); relaunchTimer = nil }
    }
}
