import Foundation
import Darwin

/// Uses macOS's libarchive-backed bsdtar. No shell, extra installation, or
/// password prompt; every output stays private until the engine commits it.
enum ZIPArchives {
    static func compress(_ sources: [URL], to output: URL, workspace: URL) async throws {
        guard let first = sources.first else { throw FileOperationError("Select at least one item to compress.") }
        var parent = first.deletingLastPathComponent()
        while sources.contains(where: { !($0.path.hasPrefix(parent.path == "/" ? "/" : parent.path + "/")) }) {
            parent.deleteLastPathComponent()
        }
        // NUL-delimited relative paths support newlines, leading dashes and @.
        // A common parent also retains distinct paths for search-result selections.
        let prefix = parent.path == "/" ? "/" : parent.path + "/"
        let paths = sources.map { "./" + $0.path.dropFirst(prefix.count) }
        let list = workspace.appendingPathComponent("inputs")
        try Data((paths.joined(separator: "\0") + "\0").utf8).write(to: list)
        try await run(["-c", "--format", "zip", "--no-mac-metadata", "-f", output.path,
                       "--null", "-T", list.path], directory: parent, workspace: workspace)
    }

    static func extract(_ source: URL, to output: URL, workspace: URL) async throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw FileOperationError("Choose a regular ZIP file to extract.") }
        let file = try FileHandle(forReadingFrom: source); defer { try? file.close() }
        let header = try file.read(upToCount: 4) ?? Data()
        guard [Data([0x50, 0x4b, 3, 4]), Data([0x50, 0x4b, 5, 6]), Data([0x50, 0x4b, 7, 8])].contains(header) else {
            throw FileOperationError("This file is not a supported ZIP archive.")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        // Never use -P or -U: bsdtar's default checks reject ../ paths and writes
        // through symlinks; absolute names are confined by stripping their root.
        try await run(["-x", "-f", source.path, "--no-same-owner", "--no-same-permissions",
                       "--no-mac-metadata", "--no-xattrs", "--no-acls", "--no-fflags", "--safe-writes"],
                      directory: output, workspace: workspace)
        guard try FileManager.default.attributesOfItem(atPath: output.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw FileOperationError("The ZIP attempted to replace the extraction folder.")
        }
        try propagateQuarantine(from: source, to: output)
    }

    private static func run(_ arguments: [String], directory: URL, workspace: URL) async throws {
        try Task.checkCancellation()
        let log = workspace.appendingPathComponent("archive.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errors = try FileHandle(forWritingTo: log); defer { try? errors.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments; process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "COPYFILE_DISABLE": "1"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        do {
            while process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
            try Task.checkCancellation()
        } catch {
            if process.isRunning { process.terminate() }
            var waits = 0
            while process.isRunning {
                if waits == 20 { kill(process.processIdentifier, SIGKILL) }
                // A detached sleep lets the child exit before staging is removed,
                // even though the parent operation has already been cancelled.
                await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
                waits += 1
            }
            throw error
        }
        guard process.terminationStatus == 0 else {
            let reader = try FileHandle(forReadingFrom: log); defer { try? reader.close() }
            let data = try reader.read(upToCount: 4096) ?? Data()
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw FileOperationError("The ZIP operation could not finish. Password-protected archives are not supported.\n\n\(detail)")
        }
    }

    /// Downloaded contents must retain the archive's Gatekeeper quarantine.
    private static func propagateQuarantine(from source: URL, to folder: URL) throws {
        let key = "com.apple.quarantine"
        let count = getxattr(source.path, key, nil, 0, 0, 0)
        if count < 0 {
            if errno == ENOATTR || errno == ENOTSUP { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard count <= 65_536 else { throw FileOperationError("The ZIP’s quarantine information could not be preserved.") }
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { getxattr(source.path, key, $0.baseAddress, count, 0, 0) }
        guard read == count else { throw FileOperationError("The ZIP’s quarantine information changed. Try extracting again.") }
        func apply(_ url: URL) throws {
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            // Never follow an archive symlink when applying metadata.
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return }
            let result = data.withUnsafeBytes { setxattr(url.path, key, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
            guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try apply(child) }
            }
        }
        try apply(folder)
    }
}
