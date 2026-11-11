import Foundation

public struct NavigationHistory: Sendable, Codable, Equatable {
    public private(set) var entries: [URL]
    public private(set) var index: Int
    public var current: URL { entries[index] }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index + 1 < entries.count }
    public var parent: URL? {
        guard current.isFileURL else { return nil }
        let parent = current.deletingLastPathComponent().standardizedFileURL
        return parent.path == current.path ? nil : parent
    }

    public init(_ url: URL) { entries = [BrowserLocation.normalized(url)]; index = 0 }

    public mutating func visit(_ url: URL) {
        let url = BrowserLocation.normalized(url)
        if current.isFileURL && url.isFileURL ? current.path == url.path : current == url { return }
        entries = Array(entries.prefix(index + 1))
        entries.append(url)
        if entries.count > 100 { entries.removeFirst() }
        index = entries.count - 1
    }
    @discardableResult public mutating func back() -> URL? {
        guard canGoBack else { return nil }; index -= 1; return current
    }
    @discardableResult public mutating func forward() -> URL? {
        guard canGoForward else { return nil }; index += 1; return current
    }
}

public enum FolderPath {
    public static func resolve(_ text: String, relativeTo current: URL) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.caseInsensitiveCompare("This Mac") == .orderedSame || text == BrowserLocation.thisMac.absoluteString { return BrowserLocation.thisMac }
        if text.hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL else { return nil }
            return url.standardizedFileURL
        }
        let path = (text as NSString).expandingTildeInPath
        if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }
        let base = current.isFileURL ? current : FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }

    /// Folder completions for a partially typed path, as Windows Explorer's address bar offers them.
    /// Each suggestion keeps the text the user typed up to the last "/" and appends a matching folder name,
    /// so "~/Doc" suggests "~/Documents". Hidden folders appear only once the typed name starts with ".".
    public static func suggestions(for text: String, relativeTo current: URL, limit: Int = 200, fileManager: FileManager = .default) -> [String] {
        guard !text.isEmpty, !text.hasPrefix("file://"), text.caseInsensitiveCompare("This Mac") != .orderedSame else {
            return []
        }
        let head: String
        let partial: String
        if let slash = text.lastIndex(of: "/") {
            head = String(text[...slash])
            partial = String(text[text.index(after: slash)...])
        } else {
            head = ""
            partial = text
        }
        guard let directory = resolve(head.isEmpty ? "." : head, relativeTo: current), directory.isFileURL else {
            return []
        }
        let showHidden = partial.hasPrefix(".")
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var matches: [String] = []
        for name in names {
            if !showHidden && name.hasPrefix(".") {
                continue
            }
            if !partial.isEmpty && name.range(of: partial, options: [.caseInsensitive, .anchored]) == nil {
                continue
            }
            var isDirectory: ObjCBool = false
            let path = directory.appendingPathComponent(name).path
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            // Bundles such as apps open as files, not folders.
            if (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
                continue
            }
            matches.append(name)
        }
        matches.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return matches.prefix(limit).map { head + $0 }
    }
}

