import Foundation

public struct StorageCapacity: Equatable, Sendable {
    public let total: Int64
    public let available: Int64
    public init?(total: Int64?, available: Int64?) {
        guard let total, let available, total > 0, available >= 0 else { return nil }
        self.total = total; self.available = min(available, total)
    }
    public var usedFraction: Double { Double(total - available) / Double(total) }
    public var lowSpace: Bool { Double(available) / Double(total) < 0.1 }
}

public struct StorageLocation: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case internalDrive, externalDrive, network, googleDrive, cloud }
    public var id: String { url.path }
    public let url: URL
    public var title: String
    public var detail: String
    public var kind: Kind
    public var capacity: StorageCapacity?
    public var readOnly: Bool
    public var children: [StorageLocation]
    public var isNetworkLocation: Bool { kind == .network || kind == .googleDrive || kind == .cloud }
    public init(url: URL, title: String, detail: String = "", kind: Kind, capacity: StorageCapacity? = nil, readOnly: Bool = false, children: [StorageLocation] = []) {
        self.url = url; self.title = title; self.detail = detail; self.kind = kind
        self.capacity = capacity; self.readOnly = readOnly; self.children = children
    }
}

public enum StorageDiscovery {
    /// Exclude macOS's implementation mounts, while preserving separately mounted user volumes.
    public static func visibleVolumes(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return ([URL(fileURLWithPath: "/")] + urls).filter { url in
            guard url.isFileURL else { return false }
            let path = url.standardizedFileURL.path
            guard path == "/" || (!path.hasPrefix("/System/") && !path.hasPrefix("/private/") && !path.hasPrefix("/var/") && !path.hasPrefix("/dev/") && !path.split(separator: "/").contains(where: { $0.hasPrefix(".") })) else { return false }
            return seen.insert(path).inserted
        }
    }
    public static func volumeURLs() -> [URL] {
        visibleVolumes(FileManager().mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
    }
    public static func volume(_ url: URL) -> StorageLocation {
        let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsReadOnlyKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let kind: StorageLocation.Kind = values?.volumeIsLocal == false ? .network : (values?.volumeIsInternal == true || url.path == "/" ? .internalDrive : .externalDrive)
        // The writable Data volume is the useful free-space source for the startup disk.
        let capacityURL = url.path == "/" && FileManager().fileExists(atPath: "/System/Volumes/Data") ? URL(fileURLWithPath: "/System/Volumes/Data") : url
        let capacity = try? capacityURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsReadOnlyKey])
        let readOnly = values?.volumeIsReadOnly ?? false
        return StorageLocation(url: url, title: values?.volumeName ?? (url.path == "/" ? "Macintosh HD" : url.lastPathComponent),
            detail: kind == .network ? "Network drive" : url.path == "/" ? "Local disk" : readOnly ? "Read-only volume" : kind == .internalDrive ? "Local disk" : "External volume", kind: kind,
            capacity: StorageCapacity(total: capacity?.volumeTotalCapacity.map(Int64.init), available: capacity?.volumeAvailableCapacity.map(Int64.init)), readOnly: readOnly)
    }
    /// Only enumerate provider roots and familiar entry folders, never their file contents.
    public static func cloudRoots(home: URL, mounted: [URL]) -> [URL] {
        let directory = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let providers = (try? FileManager().contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let legacy = home.appendingPathComponent("Google Drive", isDirectory: true)
        var candidates = providers + mounted.filter { $0.lastPathComponent.hasPrefix("GoogleDrive") || $0.lastPathComponent.hasPrefix("Google Drive") }
        if FileManager().fileExists(atPath: legacy.path) { candidates.append(legacy) }
        var seen = Set<String>()
        return candidates.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && seen.insert($0.standardizedFileURL.path).inserted }
    }
    public static func cloudRoot(_ url: URL) -> StorageLocation {
        let name = url.lastPathComponent
        let google = name.hasPrefix("GoogleDrive") || name.hasPrefix("Google Drive")
        let provider = google ? "Google Drive" : name.hasPrefix("OneDrive") ? "OneDrive" : name.hasPrefix("Dropbox") ? "Dropbox" : name.components(separatedBy: "-").first ?? name
        let prefix = google && name.hasPrefix("GoogleDrive") ? "GoogleDrive" : provider
        let account = String(name.dropFirst(min(prefix.count, name.count))).trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        let detail = account.isEmpty ? provider : "\(provider) · \(account)"
        let kind: StorageLocation.Kind = google ? .googleDrive : .cloud
        return StorageLocation(url: url, title: account.isEmpty ? provider : "\(provider) (\(account))", detail: detail, kind: kind)
    }
    public static func cloud(_ url: URL) -> StorageLocation {
        var root = cloudRoot(url)
        if root.kind == .googleDrive {
            let known = ["my drive", "shared drives", "other computers", "computers"]
            let urls = (try? FileManager().contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            root.children = urls.filter { known.contains($0.lastPathComponent.lowercased()) && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { StorageLocation(url: $0, title: $0.lastPathComponent, detail: root.detail, kind: root.kind) }
        }
        return root
    }
    public static func overview(_ locations: [StorageLocation], query: String = "") -> [StorageLocation] {
        let cloudPaths = Set(locations.filter { $0.kind == .googleDrive || $0.kind == .cloud }.map(\.id))
        return locations.filter { !cloudPaths.contains($0.id) || $0.kind == .googleDrive || $0.kind == .cloud }
            .flatMap { $0.children.isEmpty ? [$0] : $0.children }
            .filter { query.isEmpty || ($0.title + " " + $0.detail).localizedStandardContains(query) }
            .sorted { a, b in
                if (a.url.path == "/") != (b.url.path == "/") { return a.url.path == "/" }
                let result = a.title.localizedStandardCompare(b.title)
                return result == .orderedSame ? a.detail.localizedStandardCompare(b.detail) == .orderedAscending : result == .orderedAscending
            }
    }
}
