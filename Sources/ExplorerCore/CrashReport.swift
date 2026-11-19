import Foundation

package struct CrashReport: Sendable {
    package struct Versions: Sendable {
        let app: String?
        let build: String?
        let macOS: String?

        package init(app: String?, build: String?, macOS: String?) {
            self.app = app
            self.build = build
            self.macOS = macOS
        }
    }

    private let contents: Data
    private let fileExtension: String
    private let date: Date
    private let versions: Versions

    package static func latest(in directory: URL, executable: String, bundleIdentifiers: Set<String>) throws -> Self? {
        let retired = directory.appendingPathComponent("Retired", isDirectory: true)
        let retiredValues = try? retired.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let directories = retiredValues?.isDirectory == true && retiredValues?.isSymbolicLink == false
            ? [directory, retired] : [directory]
        let files = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var latest: Self?
        for folder in directories {
            let candidates: [URL]
            do {
                candidates = try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            }
            for url in candidates {
                let ext = url.pathExtension.lowercased()
                let name = url.lastPathComponent
                guard ["ips", "crash"].contains(ext), name.hasPrefix(executable + "-") || name.hasPrefix(executable + "_"),
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink == false,
                      let contents = try? Data(contentsOf: url),
                      let (timestamp, versions) = metadata(in: contents, extension: ext, bundleIdentifiers: bundleIdentifiers)
                else { continue }
                let date = parseDate(timestamp) ?? values.contentModificationDate ?? .distantPast
                if latest.map({ date > $0.date }) ?? true {
                    latest = Self(contents: contents, fileExtension: ext, date: date, versions: versions)
                }
            }
        }
        return latest
    }

    private static func metadata(in data: Data, extension ext: String, bundleIdentifiers: Set<String>) -> (String?, Versions)? {
        if ext == "crash" {
            let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).prefix(40)
            func field(_ name: String) -> String? {
                lines.first { $0.hasPrefix(name + ":") }?.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
            }
            guard let identifier = field("Identifier"), bundleIdentifiers.contains(identifier) else { return nil }
            // Legacy reports put the version and build on the same line.
            let parts = field("Version")?.components(separatedBy: " (")
            let build = parts?.count == 2 ? parts?.last?.trimmingCharacters(in: CharacterSet(charactersIn: "()")) : nil
            return (field("Date/Time"), Versions(app: parts?.first, build: build, macOS: field("OS Version")))
        }

        // Apple stores the incident metadata as JSON on the first line, followed by a second JSON object.
        guard let newline = data.firstIndex(of: 0x0a),
              let header = (try? JSONSerialization.jsonObject(with: data[..<newline])) as? [String: Any],
              (header["bug_type"] as? String == "309" || header["bug_type"] as? Int == 309),
              let incident = (try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...])) as? [String: Any]
        else { return nil }
        let bundle = incident["bundleInfo"] as? [String: Any]
        let incidentID = bundle?["CFBundleIdentifier"] as? String
        guard let identifier = header["bundleID"] as? String ?? incidentID, bundleIdentifiers.contains(identifier),
              incidentID == nil || incidentID == identifier else { return nil }
        let system = incident["osVersion"] as? [String: Any]
        let systemVersion = (system?["train"] as? String).map { train in
            (system?["build"] as? String).map { "\(train) (\($0))" } ?? train
        }
        return (header["timestamp"] as? String ?? incident["captureTime"] as? String,
                Versions(app: bundle?["CFBundleShortVersionString"] as? String ?? header["app_version"] as? String,
                         build: bundle?["CFBundleVersion"] as? String ?? header["build_version"] as? String,
                         macOS: header["os_version"] as? String ?? systemVersion))
    }

    private static func parseDate(_ timestamp: String?) -> Date? {
        guard let timestamp else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        if let date = formatter.date(from: timestamp) { return date }
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: timestamp)
    }

    package func export(to destination: URL, running: Versions) async throws {
        let files = FileManager.default
        let workspace = files.temporaryDirectory.appendingPathComponent("Explorer-Crash-\(UUID())", isDirectory: true)
        try files.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: workspace) }
        let report = workspace.appendingPathComponent("Explorer.\(fileExtension)")
        let summary = workspace.appendingPathComponent("Versions.txt")
        let archive = workspace.appendingPathComponent("Report.zip")
        try contents.write(to: report)
        try """
        At the crash
        Explorer version \(versions.app ?? "Unknown")
        Explorer build \(versions.build ?? "Unknown")
        Operating system \(versions.macOS ?? "Unknown")

        At export
        Explorer version \(running.app ?? "Unknown")
        Explorer build \(running.build ?? "Unknown")
        Operating system \(running.macOS ?? "Unknown")

        """.write(to: summary, atomically: true, encoding: .utf8)
        try await ZIPArchives.compress([report, summary], to: archive, workspace: workspace)
        try Data(contentsOf: archive).write(to: destination, options: .atomic)
    }
}
