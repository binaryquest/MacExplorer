import AppKit
import ExplorerCore
import UniformTypeIdentifiers

@MainActor
final class CrashReportExporter {
    private(set) var exporting = false

    func start() {
        guard !exporting else { return }
        exporting = true
        let bundle = Bundle.main
        let identifier = bundle.bundleIdentifier ?? PreferenceMigration.bundleID
        let identifiers: Set<String> = identifier == PreferenceMigration.bundleID
            ? [identifier, PreferenceMigration.legacyBundleID] : [identifier]
        let executable = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "Explorer"
        let directory = URL.homeDirectory.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let versions = CrashReport.Versions(
            app: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            macOS: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
        Task {
            defer { exporting = false }
            do {
                let report = try await Task.detached(priority: .utility) {
                    try CrashReport.latest(in: directory, executable: executable, bundleIdentifiers: identifiers)
                }.value
                guard let report else {
                    showAlert(L10n.text("No Explorer crash report found"),
                              detail: L10n.text("If Explorer just crashed, give macOS a moment to finish writing the report and try again."))
                    return
                }

                let panel = NSSavePanel()
                panel.title = L10n.text("Export Crash Report")
                panel.message = L10n.text("The ZIP includes the crash report and version details. Review the report for personal information before sharing it.")
                panel.allowedContentTypes = [.zip]
                panel.nameFieldStringValue = "Explorer-Crash-Report.zip"
                let response: NSApplication.ModalResponse
                if let window = presentationWindow { response = await panel.beginSheetModal(for: window) }
                else { response = await panel.begin() }
                guard response == .OK, let destination = panel.url else { return }
                try await Task.detached(priority: .utility) {
                    try await report.export(to: destination, running: versions)
                }.value
            } catch {
                showAlert(L10n.text("Couldn’t export the crash report"), detail: error.localizedDescription, style: .warning)
            }
        }
    }

    private var presentationWindow: NSWindow? {
        guard let window = NSApp.keyWindow, window.sheetParent == nil, window.attachedSheet == nil else { return nil }
        return window
    }

    private func showAlert(_ title: String, detail: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: L10n.text("OK"))
        if let window = presentationWindow { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}
