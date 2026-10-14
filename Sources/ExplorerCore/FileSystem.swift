import Foundation

public struct FileItem: Identifiable, Sendable, Equatable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isHidden: Bool
    public let isSymbolicLink: Bool
    public let modified: Date?
    public let created: Date?
    public let size: Int64?
    public let finderColors: FinderColorSummary
    public var isNavigable: Bool { isDirectory && !isPackage }
    public var kind: String {
        if isNavigable { return "Folder" }
        if url.pathExtension.lowercased() == "app" { return "Application" }
        if isPackage { return "Package" }
        return url.pathExtension.isEmpty ? "File" : "\(url.pathExtension.uppercased()) file"
    }

    public init(url: URL, name: String, isDirectory: Bool, isPackage: Bool = false,
                isHidden: Bool = false, isSymbolicLink: Bool = false, modified: Date? = nil, created: Date? = nil, size: Int64? = nil,
                finderColors: FinderColorSummary = FinderColorSummary()) {
        self.url = url; self.name = name; self.isDirectory = isDirectory
        self.isPackage = isPackage; self.isHidden = isHidden; self.isSymbolicLink = isSymbolicLink
        self.modified = modified; self.created = created; self.size = size
        self.finderColors = finderColors
    }
}

public enum FileSortKey: String, Sendable, Codable { case name, modified, kind, size, created }

public struct FileSort: Sendable, Equatable, Codable {
    public var key: FileSortKey
    public var ascending: Bool
    public init(key: FileSortKey = .name, ascending: Bool = true) {
        self.key = key; self.ascending = ascending
    }

    public func apply(to items: [FileItem], query: String = "", showHidden: Bool = false) -> [FileItem] {
        let visible = items.filter {
            (showHidden || !$0.isHidden) && (query.isEmpty || $0.name.localizedStandardContains(query))
        }
        return visible.sorted { a, b in
            // Folders stay first, even when descending.
            if a.isNavigable != b.isNavigable { return a.isNavigable }
            let result: ComparisonResult
            switch key {
            case .name: result = a.name.localizedStandardCompare(b.name)
            case .kind: result = a.kind.localizedStandardCompare(b.kind)
            case .modified: result = (a.modified ?? .distantPast).compare(b.modified ?? .distantPast)
            case .created: result = (a.created ?? .distantPast).compare(b.created ?? .distantPast)
            case .size:
                let left = a.size ?? -1, right = b.size ?? -1
                result = left < right ? .orderedAscending : left > right ? .orderedDescending : .orderedSame
            }
            if result == .orderedSame {
                let nameOrder = a.name.localizedStandardCompare(b.name)
                return nameOrder == .orderedSame ? a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending : nameOrder == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }
}

public enum FileSystem {
    /// Blocking work: call from a detached task, never the main actor.
    public static func list(_ directory: URL) throws -> [FileItem] {
        try Task.checkCancellation()
        let manager = FileManager()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isHiddenKey,
            .isSymbolicLinkKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey, .labelNumberKey]
        let urls = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        var result: [FileItem] = []
        result.reserveCapacity(urls.count)
        for url in urls {
            try Task.checkCancellation()
            // A child may disappear or deny metadata access during enumeration. Keep its name visible.
            let values = try? url.resourceValues(forKeys: keys)
            var directory = values?.isDirectory ?? false
            if values?.isSymbolicLink == true {
                // URL.resolvingSymlinksInPath canonicalizes /private/tmp back to /tmp
                // on macOS, so URL metadata can still describe the link itself.
                var targetIsDirectory = ObjCBool(false)
                if manager.fileExists(atPath: url.path, isDirectory: &targetIsDirectory) {
                    directory = targetIsDirectory.boolValue
                }
            }
            result.append(FileItem(url: url, name: url.lastPathComponent,
                isDirectory: directory, isPackage: values?.isPackage ?? false,
                isHidden: values?.isHidden == true || url.lastPathComponent.hasPrefix("."),
                isSymbolicLink: values?.isSymbolicLink ?? false,
                modified: values?.contentModificationDate, created: values?.creationDate,
                size: directory ? nil : values?.fileSize.map(Int64.init),
                finderColors: FinderColors.summary(at: url, legacyLabel: values?.labelNumber ?? 0)))
        }
        return result
    }

    public static func validateDirectory(_ url: URL) throws {
        var isDirectory = ObjCBool(false)
        guard FileManager().fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                userInfo: [NSFilePathErrorKey: url.path])
        }
        guard isDirectory.boolValue else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnsupportedSchemeError,
                userInfo: [NSLocalizedDescriptionKey: "This path is not a folder."])
        }
    }
}
