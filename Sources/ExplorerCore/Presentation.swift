import Foundation

public enum FileViewMode: String, CaseIterable, Sendable {
    case extraLarge, large, medium, small, details, content
    public var usesTable: Bool { self == .details || self == .content }
    public var title: String {
        switch self {
        case .extraLarge: "Extra large icons"
        case .large: "Large icons"
        case .medium: "Medium icons"
        case .small: "Small icons"
        case .details: "Details"
        case .content: "Content"
        }
    }
    public var shortcutNumber: String {
        switch self {
        case .extraLarge: "1"
        case .large: "2"
        case .medium: "3"
        case .small: "4"
        case .details: "6"
        case .content: "8"
        }
    }
    public var iconSize: Double {
        switch self {
        case .extraLarge: 160
        case .large: 96
        case .medium: 64
        case .small: 24
        case .details: 18
        case .content: 32
        }
    }
}

public struct FileDropPlan: Equatable, Sendable {
    public enum Action: Sendable { case copy, move }
    public let sources: [URL]
    public let destination: URL
    public let action: Action

    /// Fast, lexical hover validation. The operation engine revalidates real paths,
    /// permissions, symlinks and conflicts before modifying the filesystem.
    public static func make(sources: [URL], destination: URL, internalDrag: Bool,
                            copyRequested: Bool, moveRequested: Bool,
                            supportsCopy: Bool, supportsMove: Bool) -> Self? {
        guard destination.isFileURL, !sources.isEmpty, sources.allSatisfy(\.isFileURL) else { return nil }
        let sources = Array(Set(sources.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        let destination = destination.standardizedFileURL
        guard sources.allSatisfy({ source in
            source.path != "/" && source.path != destination.path && !destination.path.hasPrefix(source.path + "/")
        }) else { return nil }
        let action: Action = copyRequested ? .copy : (moveRequested || internalDrag ? .move : .copy)
        guard action == .copy ? supportsCopy : supportsMove else { return nil }
        if action == .move, sources.allSatisfy({ $0.deletingLastPathComponent().path == destination.path }) { return nil }
        return Self(sources: sources, destination: destination, action: action)
    }
    public var operation: FileOperation {
        action == .copy ? .copy(sources, to: destination) : .move(sources, to: destination)
    }
}

public struct ThumbnailIdentity: Hashable, Sendable {
    public let path: String
    public let modified: Date?
    public let size: Int64?
    public let pixels: Int
    public init(item: FileItem, pixels: Int) {
        path = item.id; modified = item.modified; size = item.size; self.pixels = pixels
    }
}
