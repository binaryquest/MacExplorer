import Foundation
import Darwin

public enum FinderColor: Int, CaseIterable, Sendable, Codable {
    case none = 0, gray, green, purple, blue, yellow, red, orange
    public var name: String {
        switch self {
        case .none: "None"
        case .gray: "Gray"
        case .green: "Green"
        case .purple: "Purple"
        case .blue: "Blue"
        case .yellow: "Yellow"
        case .red: "Red"
        case .orange: "Orange"
        }
    }
    public static let menuOrder: [Self] = [.red, .orange, .yellow, .green, .blue, .purple, .gray, .none]
}

public struct FinderColorSummary: Sendable, Equatable {
    public var colors: [FinderColor] = []
    public var names: [String] = []
    public init(colors: [FinderColor] = [], names: [String] = []) { self.colors = colors; self.names = names }
}

/// Finder keeps modern named tags and the legacy color label separately.
/// Retain the raw tag payload for exact Undo; never replace unrelated metadata.
public enum FinderColors {
    static let attribute = "com.apple.metadata:_kMDItemUserTags"
    struct State: Sendable, Equatable {
        var tags: Data?
        var label: Int
        var entries: [String] {
            get throws {
                guard let tags else { return [] }
                guard let entries = try PropertyListSerialization.propertyList(from: tags, format: nil) as? [String] else {
                    throw FileOperationError("Finder tags could not be read. Existing tags were left untouched.")
                }
                return entries
            }
        }
    }
    static func read(_ url: URL) throws -> State {
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.labelNumberKey])
        return State(tags: try readTags(url), label: values.labelNumber ?? 0)
    }
    private static func readTags(_ url: URL) throws -> Data? {
        for _ in 0..<3 {
            let count = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
            if count < 0 {
                if errno == ENOATTR || errno == ENOTSUP { return nil }
                throw posixError(url)
            }
            guard count <= 1_048_576 else { throw FileOperationError("Finder tags are too large to edit safely: \(url.lastPathComponent)") }
            var data = Data(count: count)
            let read = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, count, 0, XATTR_NOFOLLOW) }
            if read >= 0 { return data.prefix(read) }
            if errno != ERANGE { throw posixError(url) }
        }
        throw FileOperationError("Finder tags changed while being read. Try again.")
    }
    static func split(_ entry: String) -> (name: String, color: FinderColor) {
        guard let newline = entry.lastIndex(of: "\n"), let number = Int(entry[entry.index(after: newline)...]),
              let color = FinderColor(rawValue: number) else { return (entry, .none) }
        return (String(entry[..<newline]), color)
    }
    public static func summary(at url: URL, legacyLabel: Int? = nil) -> FinderColorSummary {
        let state: State
        if let legacyLabel { state = State(tags: try? readTags(url), label: legacyLabel) }
        else { guard let read = try? read(url) else { return FinderColorSummary() }; state = read }
        let entries = (try? state.entries) ?? []
        var colors: [FinderColor] = []
        for color in entries.map({ split($0).color }) + [FinderColor(rawValue: state.label) ?? .none] {
            if color != .none && !colors.contains(color) { colors.append(color) }
        }
        return FinderColorSummary(colors: colors, names: entries.map { split($0).name })
    }
    static func changing(_ old: State, to color: FinderColor) throws -> State {
        // Only replace standard color-name tags. Custom named tags, including
        // their colors, survive changing or removing a standard color label.
        var entries = try old.entries.filter {
            let tag = split($0)
            return tag.color == .none || tag.name != tag.color.name
        }
        if color != .none { entries.insert("\(color.name)\n\(color.rawValue)", at: 0) }
        return State(tags: entries.isEmpty ? nil : try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0), label: color.rawValue)
    }
    static func replace(_ url: URL, expected: State, with desired: State) throws {
        guard try read(url) == expected else { throw FileOperationError("Finder tags changed on \(url.lastPathComponent). Refresh and try again.") }
        do { try write(desired, at: url) }
        catch {
            let failure = error
            do { try write(expected, at: url) }
            catch { throw FileOperationError("\(failure.localizedDescription) Restoring the original tags also failed: \(error.localizedDescription)") }
            throw failure
        }
    }
    private static func write(_ state: State, at url: URL) throws {
        var fresh = URL(fileURLWithPath: url.path), values = URLResourceValues()
        values.labelNumber = state.label; try fresh.setResourceValues(values)
        if let tags = state.tags {
            let result = tags.withUnsafeBytes { setxattr(url.path, attribute, $0.baseAddress, tags.count, 0, XATTR_NOFOLLOW) }
            if result != 0 { throw posixError(url) }
        } else if removexattr(url.path, attribute, XATTR_NOFOLLOW) != 0 && errno != ENOATTR {
            throw posixError(url)
        }
    }
    private static func posixError(_ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}
