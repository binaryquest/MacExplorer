import Foundation

public struct Favorite: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let path: String
    public let name: String
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public init(id: UUID = UUID(), url: URL, name: String? = nil) {
        self.id = id; path = url.standardizedFileURL.path
        self.name = name ?? (url.lastPathComponent.isEmpty ? "Macintosh HD" : url.lastPathComponent)
    }
}

public struct Favorites: Codable, Equatable, Sendable {
    public private(set) var items: [Favorite]
    public init(_ items: [Favorite] = []) {
        var paths: Set<String> = [], ids: Set<UUID> = []
        self.items = items.filter { item in
            let path = item.url.standardizedFileURL.path
            guard item.path.hasPrefix("/"), !paths.contains(path), !ids.contains(item.id) else { return false }
            paths.insert(path); ids.insert(item.id); return true
        }
    }
    public func contains(_ url: URL) -> Bool { items.contains { $0.url.standardizedFileURL.path == url.standardizedFileURL.path } }
    @discardableResult public mutating func pin(_ url: URL, name: String? = nil) -> Bool {
        guard url.isFileURL, !contains(url) else { return false }
        items.append(Favorite(url: url, name: name)); return true
    }
    public mutating func unpin(_ url: URL) { items.removeAll { $0.url.standardizedFileURL.path == url.standardizedFileURL.path } }
    public mutating func move(_ id: UUID, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, index + offset), items.count - 1)
        guard target != index else { return }
        items.insert(items.remove(at: index), at: target)
    }
}
