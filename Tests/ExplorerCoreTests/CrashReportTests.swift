import Foundation
import Testing
@testable import ExplorerCore

struct CrashReportTests {
    private let explorerID = "io.bquick.explorer"

    @Test func exportsLatestExplorerCrashUnchangedWithCrashAndExportVersions() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let retired = root.appendingPathComponent("Retired", isDirectory: true)
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: false)

        let old = try makeIPS(timestamp: "2026-11-19 10:00:00.25 +0000")
        let latest = try makeIPS(timestamp: "2026-11-19 17:00:00.2500 +0600")
        let oldURL = root.appendingPathComponent("Explorer-old.ips")
        let latestURL = retired.appendingPathComponent("Explorer-latest.ips")
        try old.write(to: oldURL)
        try latest.write(to: latestURL)
        // Copying an old report changes its modification time, but not the incident date.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)], ofItemAtPath: oldURL.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: latestURL.path)
        try makeIPS(timestamp: "2026-11-20 12:00:00.00 +0000", identifier: "com.example.explorer")
            .write(to: root.appendingPathComponent("Explorer-unrelated.ips"))
        try makeIPS(timestamp: "2026-11-20 12:00:00.00 +0000", bugType: "288")
            .write(to: root.appendingPathComponent("Explorer-stackshot.ips"))
        try Data("{\"bundleID\":\"io.bquick.explorer\",\"bug_type\":\"309\"}\n".utf8)
            .write(to: root.appendingPathComponent("Explorer-incomplete.ips"))

        let selected = try CrashReport.latest(in: root, executable: "Explorer", bundleIdentifiers: [explorerID])
        let report = try #require(selected)
        let extracted = try await export(report, at: root)
        #expect(try Data(contentsOf: extracted.appendingPathComponent("Explorer.ips")) == latest)
        let versions = try String(contentsOf: extracted.appendingPathComponent("Versions.txt"), encoding: .utf8)
        #expect(versions.contains("At the crash\nExplorer version 0.12.0\nExplorer build 29\nOperating system macOS 15.8.2 (24H232)"))
        #expect(versions.contains("At export\nExplorer version 0.13.0\nExplorer build 30\nOperating system macOS 27.2.1"))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: extracted.path)) == ["Explorer.ips", "Versions.txt"])
    }

    @Test func skipsOtherProcessesAndSymbolicLinksAndHandlesMissingDirectories() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = root.appendingPathComponent("DifferentProcess-1.ips")
        try makeIPS(timestamp: "2026-11-19 10:00:00 +0000").write(to: report)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Explorer-link.ips"), withDestinationURL: report)
        try makeIPS(timestamp: "2026-11-19 11:00:00 +0000", identifier: "com.example.other")
            .write(to: root.appendingPathComponent("Explorer-unrelated.ips"))

        #expect(try CrashReport.latest(in: root, executable: "Explorer", bundleIdentifiers: [explorerID]) == nil)
        #expect(try CrashReport.latest(in: root.appendingPathComponent("Missing"), executable: "Explorer", bundleIdentifiers: [explorerID]) == nil)
    }

    @Test func exportsLegacyCrashWhenItIsTheLatestExplorerReport() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = Data("""
        Process:               Explorer [100]
        Identifier:            dev.local.explorer
        Version:               0.10.0 (24)
        Date/Time:             2026-11-19 18:10:00.123 +0600
        OS Version:            macOS 14.7.8 (23H730)

        Thread 0 Crashed:
        """.utf8)
        try legacy.write(to: root.appendingPathComponent("Explorer_legacy.crash"))
        try makeIPS(timestamp: "2026-11-19 10:00:00.00 +0000").write(to: root.appendingPathComponent("Explorer-previous.ips"))
        let selected = try CrashReport.latest(in: root, executable: "Explorer", bundleIdentifiers: [explorerID, "dev.local.explorer"])
        let report = try #require(selected)
        let extracted = try await export(report, at: root)
        #expect(try Data(contentsOf: extracted.appendingPathComponent("Explorer.crash")) == legacy)
        let versions = try String(contentsOf: extracted.appendingPathComponent("Versions.txt"), encoding: .utf8)
        #expect(versions.contains("At the crash\nExplorer version 0.10.0\nExplorer build 24\nOperating system macOS 14.7.8 (23H730)"))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Explorer-Crash-Tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func makeIPS(timestamp: String, identifier: String? = nil, bugType: String = "309") throws -> Data {
        let identifier = identifier ?? explorerID
        let header = ["bundleID": identifier, "bug_type": bugType, "timestamp": timestamp]
        let incident = [
            "bundleInfo": ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": "0.12.0", "CFBundleVersion": "29"],
            "osVersion": ["train": "macOS 15.8.2", "build": "24H232"]
        ]
        return try JSONSerialization.data(withJSONObject: header, options: .sortedKeys) + Data([0x0a]) +
            JSONSerialization.data(withJSONObject: incident, options: [.prettyPrinted, .sortedKeys])
    }

    private func export(_ report: CrashReport, at directory: URL) async throws -> URL {
        let archive = directory.appendingPathComponent("Support.zip")
        try await report.export(to: archive, running: .init(app: "0.13.0", build: "30", macOS: "macOS 27.2.1"))
        let output = directory.appendingPathComponent("Extracted", isDirectory: true)
        try await ZIPArchives.extract(archive, to: output, workspace: directory)
        return output
    }
}
