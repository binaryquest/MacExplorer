import Foundation

public enum SearchScope: String, Codable, Sendable { case folder, subfolders }

public struct SearchUpdate: Sendable {
    public let matches: [FileItem]
    public let scanned: Int
    public let unreadableFolders: Int
    public let reachedLimit: Bool
}

public enum DirectorySearch {
    /// Runs on a worker task. Directory symlinks and packages are returned as results,
    /// but never descended into. This prevents cycles and surprises inside app bundles.
    public static func run(root: URL, query: String, showHidden: Bool = false, resultLimit: Int = 20_000,
                           onUpdate: @Sendable (SearchUpdate) async -> Void) async throws -> SearchUpdate {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, resultLimit > 0 else { return SearchUpdate(matches: [], scanned: 0, unreadableFolders: 0, reachedLimit: false) }
        try Task.checkCancellation()
        let searchRoot = URL(fileURLWithPath: root.resolvingSymlinksInPath().path, isDirectory: true)
        try FileSystem.validateDirectory(searchRoot)
        var folders = [searchRoot], batch: [FileItem] = [], scanned = 0, unreadable = 0, found = 0
        var lastUpdate = ContinuousClock.now, limited = false
        scan: while let folder = folders.popLast() {
            try Task.checkCancellation()
            let items: [FileItem]
            do { items = try FileSystem.list(folder) }
            catch is CancellationError { throw CancellationError() }
            catch {
                if folder == searchRoot { throw error }
                unreadable += 1; continue
            }
            for item in items {
                try Task.checkCancellation()
                guard showHidden || !item.isHidden else { continue }
                scanned += 1
                if item.name.localizedStandardContains(query) {
                    batch.append(item); found += 1
                    if found >= resultLimit { limited = true; break scan }
                }
                if item.isNavigable && !item.isSymbolicLink { folders.append(item.url) }
                if batch.count >= 100 || lastUpdate.duration(to: .now) >= .milliseconds(200) {
                    await onUpdate(SearchUpdate(matches: batch, scanned: scanned, unreadableFolders: unreadable, reachedLimit: false))
                    batch.removeAll(keepingCapacity: true); lastUpdate = .now
                }
            }
        }
        try Task.checkCancellation()
        let final = SearchUpdate(matches: batch, scanned: scanned, unreadableFolders: unreadable, reachedLimit: limited)
        await onUpdate(final)
        return SearchUpdate(matches: [], scanned: scanned, unreadableFolders: unreadable, reachedLimit: limited)
    }
    public static func location(of item: URL, relativeTo root: URL) -> String {
        var parent = item.deletingLastPathComponent().standardizedFileURL.path, base = root.standardizedFileURL.path
        // Enumeration can return a physical path when the search root uses an alias
        // such as /tmp or a user-created directory symlink.
        if parent != base && !parent.hasPrefix(base == "/" ? "/" : base + "/") {
            parent = item.deletingLastPathComponent().resolvingSymlinksInPath().path
            base = root.resolvingSymlinksInPath().path
        }
        if parent == base { return root.lastPathComponent.isEmpty ? "/" : root.lastPathComponent }
        let prefix = base == "/" ? "/" : base + "/"
        return parent.hasPrefix(prefix) ? String(parent.dropFirst(prefix.count)) : parent
    }
}
