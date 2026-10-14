import Foundation
import Darwin

public enum FileOperation: Sendable {
    case copy([URL], to: URL)
    case move([URL], to: URL)
    case rename(URL, to: String)
    case newFolder(in: URL, name: String)
    case trash([URL])
    case color([URL], FinderColor)
    case compress([URL], to: URL)
    case extract(URL, to: URL)

    public var title: String {
        switch self {
        case .copy: "Copy"
        case .move: "Move"
        case .rename: "Rename"
        case .newFolder: "New Folder"
        case .trash: "Trash"
        case .color: "Change Color Label"
        case .compress: "Compress"
        case .extract: "Extract All"
        }
    }
}

public enum ConflictChoice: Sendable { case replace, keepBoth, skip, cancel }
public struct ConflictResolution: Sendable {
    public let choice: ConflictChoice
    public let applyToAll: Bool
    public init(_ choice: ConflictChoice, applyToAll: Bool = false) {
        self.choice = choice; self.applyToAll = applyToAll
    }
}
public struct FileConflict: Sendable {
    public let source: URL
    public let destination: URL
    public let destinationIsDirectory: Bool
}
public struct OperationProgress: Sendable {
    public let title: String
    public let item: String
    public let index: Int
    public let total: Int
}
public struct OperationReport: Sendable {
    public var completed: [URL] = []
    public var consumedSources: [URL] = []
    public var skipped = 0
    public var cancelled = false
    public var error: String?
    public var metadataOnly = false
    public init() {}
}
public struct FileOperationError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One serialized queue shared by all windows. Undo records are session-scoped.
/// Existing data is only moved, or sent to the system Trash; it is never unlinked.
public actor FileOperationEngine {
    public typealias ResolveConflict = @Sendable (FileConflict) async -> ConflictResolution
    public typealias ReportProgress = @Sendable (OperationProgress) async -> Void
    public typealias TrashItem = @Sendable (URL) throws -> URL

    private let fm = FileManager()
    private let trashItem: TrashItem
    private let volumeID: @Sendable (URL) throws -> UInt64
    private var busy = false
    private var history: [UndoRecord] = []

    public init(trashItem: @escaping TrashItem = FileOperationEngine.systemTrash,
                volumeID: @escaping @Sendable (URL) throws -> UInt64 = FileOperationEngine.fileVolume) {
        self.trashItem = trashItem; self.volumeID = volumeID
    }
    public static func fileVolume(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager().attributesOfItem(atPath: url.path)
        guard let number = attributes[.systemNumber] as? NSNumber else { throw FileOperationError("Could not identify the volume for \(url.path)") }
        return number.uint64Value
    }
    public var undoTitle: String? { history.last?.title }

    public static func systemTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager().trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw FileOperationError("macOS did not return the item's Trash location.") }
        return result as URL
    }

    public static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains("\0"), !name.contains(":") else {
            throw FileOperationError("Enter a name without /, : or null characters. The name cannot be empty, . or ..")
        }
    }

    public func perform(_ operation: FileOperation,
                        resolve: ResolveConflict = { _ in ConflictResolution(.cancel) },
                        progress: ReportProgress = { _ in }) async -> OperationReport {
        guard !busy else { return failed("Another file operation is running.") }
        busy = true; defer { busy = false }
        switch operation {
        case let .compress(urls, target): return await archive(urls, to: target, extracting: false, resolve: resolve, progress: progress)
        case let .extract(url, target): return await archive([url], to: target, extracting: true, resolve: resolve, progress: progress)
        default: break
        }
        var report = OperationReport()
        if case .color = operation { report.metadataOnly = true }
        var record = UndoRecord(title: operation.title, steps: [])
        var policy: ConflictChoice?
        do {
            let sources: [URL]
            let destinationFolder: URL?
            switch operation {
            case let .copy(urls, destination), let .move(urls, destination):
                sources = try normalizedSelection(urls)
                destinationFolder = destination.resolvingSymlinksInPath().standardizedFileURL
                try FileSystem.validateDirectory(destinationFolder!)
            case let .trash(urls): sources = try normalizedSelection(urls); destinationFolder = nil
            case let .color(urls, _):
                sources = Array(Set(urls.map { canonicalItem($0) })).sorted { $0.path < $1.path }; destinationFolder = nil
            case let .rename(url, name):
                try Self.validateName(name); sources = [canonicalItem(url)]; destinationFolder = nil
            case let .newFolder(parent, name):
                try Self.validateName(name); try FileSystem.validateDirectory(parent)
                sources = [parent.resolvingSymlinksInPath().appendingPathComponent(name)]; destinationFolder = nil
            case .compress, .extract: fatalError("Handled above")
            }
            for (index, source) in sources.enumerated() {
                try Task.checkCancellation()
                await progress(OperationProgress(title: operation.title, item: source.lastPathComponent, index: index + 1, total: sources.count))
                try Task.checkCancellation()
                if case let .color(_, color) = operation {
                    let stamp = try snapshotNode(source)
                    guard stamp.type != FileAttributeType.typeSymbolicLink.rawValue else {
                        throw FileOperationError("Color labels on symbolic links are not supported. The linked item was left untouched.")
                    }
                    let before = try FinderColors.read(source), after = try FinderColors.changing(before, to: color)
                    if before == after { report.skipped += 1; continue }
                    try FinderColors.replace(source, expected: before, with: after)
                    record.steps.insert(.color(source, Snapshot(nodes: ["": stamp]), before: before, after: after), at: 0)
                    report.completed.append(source); continue
                }
                if case .newFolder = operation {
                    // mkdir fails if a file appeared at this name; never replace it.
                    try fm.createDirectory(at: source, withIntermediateDirectories: false)
                    let step = UndoStep.remove(source, try snapshot(source))
                    record.steps.insert(step, at: 0); report.completed.append(source)
                    continue
                }
                try protectRoot(source)
                let original = try snapshot(source)
                if case .trash = operation {
                    let trashed = try trashItem(source)
                    record.steps.insert(.restore(trashed, source, try snapshot(trashed)), at: 0)
                    report.completed.append(source); report.consumedSources.append(source)
                    continue
                }
                var destination: URL
                let copying: Bool
                switch operation {
                case .copy: destination = destinationFolder!.appendingPathComponent(source.lastPathComponent); copying = true
                case .move: destination = destinationFolder!.appendingPathComponent(source.lastPathComponent); copying = false
                case let .rename(_, name): destination = source.deletingLastPathComponent().appendingPathComponent(name); copying = false
                default: fatalError("Handled above")
                }
                if original.isDirectory && isInside(destination, source) {
                    throw FileOperationError("A folder cannot be copied or moved into itself: \(source.lastPathComponent)")
                }
                if isInside(source, destination) {
                    throw FileOperationError("The destination contains the source item. Choose a different destination.")
                }
                let sameEntry = sameIdentity(source, destination)
                if source.path == destination.path {
                    if copying { destination = uniqueCopy(of: destination, directory: original.isDirectory) }
                    else { report.skipped += 1; continue }
                } else if sameEntry {
                    if case .rename = operation, source.lastPathComponent.lowercased() == destination.lastPathComponent.lowercased() {
                        // A case-only rename on a case-insensitive volume needs an intermediate name.
                        let staging = temporarySibling(of: source)
                        try exclusiveMove(source, staging)
                        do { try exclusiveMove(staging, destination) }
                        catch { try exclusiveMove(staging, source); throw error }
                        record.steps.insert(.restore(destination, source, try snapshot(destination)), at: 0)
                        report.completed.append(destination); report.consumedSources.append(source)
                        continue
                    }
                    if copying { destination = uniqueCopy(of: destination, directory: original.isDirectory) }
                    else { report.skipped += 1; continue }
                }
                var replacing: Snapshot?
                if exists(destination) {
                    let existing = try snapshot(destination)
                    let resolution: ConflictResolution
                    if let policy { resolution = ConflictResolution(policy) }
                    else { resolution = await resolve(FileConflict(source: source, destination: destination, destinationIsDirectory: existing.isDirectory)) }
                    try Task.checkCancellation()
                    if resolution.applyToAll { policy = resolution.choice }
                    switch resolution.choice {
                    case .cancel: throw CancellationError()
                    case .skip: report.skipped += 1; continue
                    case .keepBoth: destination = uniqueCopy(of: destination, directory: original.isDirectory)
                    case .replace: replacing = existing
                    }
                }
                // The user may have left a conflict dialog open while another app edited either item.
                try requireUnchanged(source, original)
                let steps = try transfer(source, destination, copying: copying, original: original, replacing: replacing)
                record.steps.insert(contentsOf: steps, at: 0)
                report.completed.append(destination)
                if !copying { report.consumedSources.append(source) }
            }
        } catch is CancellationError { report.cancelled = true }
        catch { report.error = error.localizedDescription }
        if !record.steps.isEmpty { history.append(record) }
        return report
    }

    private func archive(_ urls: [URL], to target: URL, extracting: Bool,
                         resolve: ResolveConflict, progress: ReportProgress) async -> OperationReport {
        var report = OperationReport()
        let title = extracting ? "Extract All" : "Compress"
        do {
            guard target.isFileURL else { throw FileOperationError("Choose a local destination.") }
            let sources = try normalizedSelection(urls)
            guard !sources.isEmpty else { throw FileOperationError("Select at least one item.") }
            var destination = canonicalItem(target)
            try Self.validateName(destination.lastPathComponent)
            let parent = destination.deletingLastPathComponent()
            try FileSystem.validateDirectory(parent)
            for source in sources {
                if source == destination || sameIdentity(source, destination) || isInside(destination, source) || isInside(source, destination) {
                    throw FileOperationError("Choose a destination outside the selected items.")
                }
            }
            let originals = try sources.map { try snapshot($0) }
            var replacing: Snapshot?
            if exists(destination) {
                let existing = try snapshot(destination)
                let resolution = await resolve(FileConflict(source: sources[0], destination: destination, destinationIsDirectory: existing.isDirectory))
                try Task.checkCancellation()
                switch resolution.choice {
                case .cancel: throw CancellationError()
                case .skip: report.skipped = 1; return report
                case .keepBoth: destination = uniqueCopy(of: destination, directory: extracting)
                case .replace: replacing = existing
                }
            }
            let workspace = parent.appendingPathComponent(".explorer-archive-\(UUID())")
            try fm.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: workspace) } // Only our unpublished temporary output.
            let output = workspace.appendingPathComponent(extracting ? "contents" : "output.zip")
            for (source, original) in zip(sources, originals) { try requireUnchanged(source, original) }
            await progress(OperationProgress(title: title, item: destination.lastPathComponent, index: 1, total: 1))
            if extracting { try await ZIPArchives.extract(sources[0], to: output, workspace: workspace) }
            else { try await ZIPArchives.compress(sources, to: output, workspace: workspace) }
            try Task.checkCancellation()
            for (source, original) in zip(sources, originals) { try requireUnchanged(source, original) }
            let created = try snapshot(output)
            var backup: URL?
            var backupSnapshot: Snapshot?
            if let replacing {
                try requireUnchanged(destination, replacing)
                backup = try trashItem(destination)
                // Moving to Trash preserves the identity used by the undo preflight.
                backupSnapshot = replacing
            }
            do { try exclusiveMove(output, destination) }
            catch {
                let failure = error
                if let backup {
                    do { try exclusiveMove(backup, destination) }
                    catch { throw FileOperationError("\(failure.localizedDescription) The original destination remains at \(backup.path).") }
                }
                throw failure
            }
            var steps: [UndoStep] = [.remove(destination, created)]
            if let backup, let backupSnapshot { steps.append(.restore(backup, destination, backupSnapshot)) }
            history.append(UndoRecord(title: title, steps: steps))
            report.completed = [destination]
        } catch is CancellationError { report.cancelled = true }
        catch { report.error = error.localizedDescription }
        return report
    }

    public func undo(progress: ReportProgress = { _ in }) async -> OperationReport {
        guard !busy else { return failed("Another file operation is running.") }
        guard var record = history.last else { return OperationReport() }
        busy = true; defer { busy = false }
        var report = OperationReport()
        report.metadataOnly = record.steps.allSatisfy { $0.colorChange != nil }
        do {
            // Preflight the entire batch before changing anything. Destinations that an earlier
            // inverse step vacates are allowed, but unrelated files are never overwritten.
            var virtual: [String: Snapshot] = [:]
            var vacant: Set<String> = []
            for step in record.steps {
                try Task.checkCancellation()
                let current: Snapshot
                if vacant.contains(step.source.path) { throw FileOperationError("An item needed by Undo is missing: \(step.source.path)") }
                else if let projected = virtual[step.source.path] { current = projected }
                else { current = try step.colorChange == nil ? snapshot(step.source) : Snapshot(nodes: ["": snapshotNode(step.source)]) }
                guard current == step.expected else { throw changedError(step.source) }
                if let change = step.colorChange {
                    guard try FinderColors.read(step.source) == change.after else { throw changedError(step.source) }
                    continue
                }
                if let target = step.destination {
                    let occupied = virtual[target.path] != nil || (!vacant.contains(target.path) && exists(target))
                    if occupied && !isCaseOnlyRename(step.source, target) {
                        throw FileOperationError("Undo stopped because \(target.path) is occupied. Move that item aside, then try Undo again.")
                    }
                    virtual[target.path] = current; vacant.remove(target.path)
                }
                virtual.removeValue(forKey: step.source.path); vacant.insert(step.source.path)
            }
            let total = record.steps.count
            while let step = record.steps.first {
                try Task.checkCancellation()
                await progress(OperationProgress(title: "Undo \(record.title)", item: step.source.lastPathComponent, index: total - record.steps.count + 1, total: total))
                try Task.checkCancellation()
                if let change = step.colorChange {
                    guard try Snapshot(nodes: ["": snapshotNode(step.source)]) == step.expected else { throw changedError(step.source) }
                    try FinderColors.replace(step.source, expected: change.after, with: change.before)
                    report.completed.append(step.source)
                } else if let target = step.destination {
                    try requireUnchanged(step.source, step.expected)
                    if isCaseOnlyRename(step.source, target) {
                        let staging = temporarySibling(of: step.source)
                        try exclusiveMove(step.source, staging)
                        do { try exclusiveMove(staging, target) }
                        catch { try exclusiveMove(staging, step.source); throw error }
                    } else { try exclusiveMove(step.source, target) }
                    report.completed.append(target)
                } else {
                    try requireUnchanged(step.source, step.expected)
                    _ = try trashItem(step.source)
                    report.completed.append(step.source)
                }
                record.steps.removeFirst()
                // Save after each step, so a permission failure or cancellation can be retried.
                history[history.count - 1] = record
            }
            history.removeLast()
        } catch is CancellationError { report.cancelled = true }
        catch { report.error = error.localizedDescription }
        return report
    }

    private func transfer(_ source: URL, _ destination: URL, copying: Bool, original: Snapshot, replacing: Snapshot?) throws -> [UndoStep] {
        let staging = temporarySibling(of: destination)
        let crossVolume = try volumeID(source) != volumeID(destination.deletingLastPathComponent())
        let needsCopy = copying || crossVolume
        var backup: URL?
        var committed = false
        var sourceBackup: URL?
        do {
            if needsCopy {
                try fm.copyItem(at: source, to: staging)
                try Task.checkCancellation()
                // Refuse to commit a copy if the source changed during the copy.
                try requireUnchanged(source, original)
            }
            try Task.checkCancellation()
            if let replacing {
                try requireUnchanged(destination, replacing)
                backup = try trashItem(destination)
            }
            if needsCopy { try exclusiveMove(staging, destination) }
            else { try exclusiveMove(source, destination) }
            committed = true
            if crossVolume && !copying {
                // Retain the original on its own volume for an exact, recoverable undo.
                try requireUnchanged(source, original)
                sourceBackup = try trashItem(source)
            }
            var steps: [UndoStep] = []
            if copying || crossVolume {
                steps.append(.remove(destination, try snapshot(destination)))
                if let sourceBackup { steps.append(.restore(sourceBackup, source, try snapshot(sourceBackup))) }
            } else { steps.append(.restore(destination, source, try snapshot(destination))) }
            if let backup { steps.append(.restore(backup, destination, try snapshot(backup))) }
            return steps
        } catch {
            let failure = error
            do {
                if committed {
                    if needsCopy { _ = try trashItem(destination) }
                    else { try exclusiveMove(destination, source) }
                }
                if let sourceBackup { try exclusiveMove(sourceBackup, source) }
                if let backup { try exclusiveMove(backup, destination) }
            } catch {
                // Keep all recovery locations in the error, including partial rollback.
                throw FileOperationError("\(failure.localizedDescription) Recovery also stopped: \(error.localizedDescription)\nCheck \(destination.path)\(backup.map { "\nOriginal destination: \($0.path)" } ?? "")\(sourceBackup.map { "\nOriginal source: \($0.path)" } ?? "").")
            }
            if exists(staging) { try? fm.removeItem(at: staging) } // Only our incomplete, unpublished copy.
            throw failure
        }
    }

    private func failed(_ message: String) -> OperationReport {
        var report = OperationReport(); report.error = message; return report
    }
    private func protectRoot(_ url: URL) throws {
        guard url.path != "/", url.path != FileManager.default.homeDirectoryForCurrentUser.path else {
            throw FileOperationError("The startup root and your home folder cannot be changed by Explorer.")
        }
    }
    private func canonicalItem(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if standardized.path == "/" { return standardized }
        // Resolve parents, never the selected symlink itself.
        return standardized.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(standardized.lastPathComponent)
    }
    private func normalizedSelection(_ urls: [URL]) throws -> [URL] {
        var unique: [URL] = []
        for url in urls {
            guard url.isFileURL else { throw FileOperationError("Only local file URLs are supported.") }
            let item = canonicalItem(url)
            if !unique.contains(item) { unique.append(item) }
        }
        return try unique.filter { item in
            try !unique.contains { parent in
                guard parent != item, isInside(item, parent) else { return false }
                return try snapshotNode(parent).type == FileAttributeType.typeDirectory.rawValue
            }
        }
    }
    private func isInside(_ child: URL, _ parent: URL) -> Bool {
        child.path.hasPrefix(parent.path == "/" ? "/" : parent.path + "/")
    }
    private func exists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }
    private func isCaseOnlyRename(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.deletingLastPathComponent() == rhs.deletingLastPathComponent() &&
        lhs.lastPathComponent != rhs.lastPathComponent &&
        lhs.lastPathComponent.lowercased() == rhs.lastPathComponent.lowercased() && sameIdentity(lhs, rhs)
    }
    private func sameIdentity(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let a = try? snapshotNode(lhs), let b = try? snapshotNode(rhs) else { return false }
        return a.inode == b.inode && a.device == b.device
    }
    private func uniqueCopy(of url: URL, directory: Bool) -> URL {
        let ext = directory ? "" : url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let suffix = index == 1 ? " - Copy" : " - Copy (\(index))"
            let name = stem + suffix + (ext.isEmpty ? "" : "." + ext)
            let result = url.deletingLastPathComponent().appendingPathComponent(name)
            if !exists(result) { return result }
            index += 1
        }
    }
    private func temporarySibling(of url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".explorer-staging-\(UUID().uuidString)")
    }
    private func exclusiveMove(_ source: URL, _ destination: URL) throws {
        // Unlike POSIX rename(), RENAME_EXCL never silently overwrites a racing writer.
        let result = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in renamex_np(from!, to!, UInt32(RENAME_EXCL)) }
        }
        if result != 0 {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: destination.path,
                NSLocalizedDescriptionKey: "Could not move \(source.lastPathComponent) to \(destination.path): \(String(cString: strerror(code)))"])
        }
    }

    private struct NodeStamp: Equatable, Sendable {
        let type: String
        let inode: UInt64
        let device: UInt64
        let size: UInt64
        let modified: Date?
        let permissions: UInt16
        let link: String?
    }
    private struct Snapshot: Equatable, Sendable {
        let nodes: [String: NodeStamp]
        var isDirectory: Bool { nodes[""]?.type == FileAttributeType.typeDirectory.rawValue }
    }
    private func snapshotNode(_ url: URL) throws -> NodeStamp {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let type = (attributes[.type] as? FileAttributeType)?.rawValue ?? ""
        let directory = type == FileAttributeType.typeDirectory.rawValue
        return NodeStamp(type: type, inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                         device: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
                         size: directory ? 0 : (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                         modified: directory ? nil : attributes[.modificationDate] as? Date,
                         permissions: (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0,
                         link: type == FileAttributeType.typeSymbolicLink.rawValue ? try fm.destinationOfSymbolicLink(atPath: url.path) : nil)
    }
    private func snapshot(_ url: URL) throws -> Snapshot {
        var nodes: [String: NodeStamp] = [:]
        func visit(_ item: URL, relative: String) throws {
            let stamp = try snapshotNode(item); nodes[relative] = stamp
            if stamp.type == FileAttributeType.typeDirectory.rawValue {
                for child in try fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                    try visit(child, relative: relative + "/" + child.lastPathComponent)
                }
            }
        }
        try visit(url, relative: "")
        return Snapshot(nodes: nodes)
    }
    private func requireUnchanged(_ url: URL, _ expected: Snapshot) throws {
        guard try snapshot(url) == expected else {
            throw changedError(url)
        }
    }
    private func changedError(_ url: URL) -> FileOperationError {
        FileOperationError("\(url.path) has changed since this operation was recorded. Explorer left it untouched.")
    }
    private struct UndoStep: Sendable {
        let source: URL
        let destination: URL?
        let expected: Snapshot
        var colorChange: (before: FinderColors.State, after: FinderColors.State)? = nil
        static func remove(_ source: URL, _ expected: Snapshot) -> Self { Self(source: source, destination: nil, expected: expected) }
        static func restore(_ source: URL, _ destination: URL, _ expected: Snapshot) -> Self { Self(source: source, destination: destination, expected: expected) }
        static func color(_ source: URL, _ expected: Snapshot, before: FinderColors.State, after: FinderColors.State) -> Self {
            Self(source: source, destination: nil, expected: expected, colorChange: (before, after))
        }
    }
    private struct UndoRecord: Sendable { let title: String; var steps: [UndoStep] }
}
