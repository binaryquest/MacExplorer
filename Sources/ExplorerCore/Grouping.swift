import Foundation

public enum FileGroupKey: String, CaseIterable, Codable, Sendable {
    case none, name, modified, kind, size, created
    public var title: String {
        switch self {
        case .none: "None"
        case .name: "Name"
        case .modified: "Date modified"
        case .kind: "Type"
        case .size: "Size"
        case .created: "Date created"
        }
    }
    public var defaultAscending: Bool { self != .modified && self != .created }
}

public struct FileGrouping: Codable, Equatable, Sendable {
    public var key: FileGroupKey
    public var ascending: Bool
    public init(key: FileGroupKey = .none, ascending: Bool? = nil) {
        self.key = key; self.ascending = ascending ?? key.defaultAscending
    }
    public func sections(from sortedItems: [FileItem], now: Date = Date(), calendar: Calendar = .current) -> [FileGroup] {
        guard !sortedItems.isEmpty else { return [] }
        guard key != .none else { return [FileGroup(id: "all", title: "", items: sortedItems)] }
        var buckets: [Bucket: [FileItem]] = [:]
        for item in sortedItems { buckets[bucket(item, now: now, calendar: calendar), default: []].append(item) }
        return buckets.keys.sorted { a, b in
            if a.unknown != b.unknown { return !a.unknown }
            let comparison = a.rank == b.rank ? a.title.localizedStandardCompare(b.title) : (a.rank < b.rank ? ComparisonResult.orderedAscending : .orderedDescending)
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }.map { FileGroup(id: key.rawValue + ":" + $0.id, title: $0.title, items: buckets[$0]!) }
    }
    private struct Bucket: Hashable { let id: String; let title: String; var rank = 0; var unknown = false }
    private func bucket(_ item: FileItem, now: Date, calendar: Calendar) -> Bucket {
        switch key {
        case .none: return Bucket(id: "all", title: "")
        case .kind: return Bucket(id: item.kind, title: item.kind)
        case .name:
            let first = String(item.name.prefix(1)).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).uppercased()
            if first.rangeOfCharacter(from: .decimalDigits) != nil { return Bucket(id: "digits", title: "0–9", rank: 0) }
            if ("A"..."H").contains(first) { return Bucket(id: "a-h", title: "A–H", rank: 1) }
            if ("I"..."P").contains(first) { return Bucket(id: "i-p", title: "I–P", rank: 2) }
            if ("Q"..."Z").contains(first) { return Bucket(id: "q-z", title: "Q–Z", rank: 3) }
            return Bucket(id: "other", title: "Other", rank: 4)
        case .size:
            if item.isDirectory { return Bucket(id: "folders", title: "Folders", rank: -1) }
            guard let size = item.size, size >= 0 else { return Bucket(id: "unknown", title: "Unspecified", unknown: true) }
            let limits: [(Int64, String)] = [(0, "Empty"), (16_384, "Tiny (up to 16 KB)"), (1_048_576, "Small (16 KB–1 MB)"), (134_217_728, "Medium (1–128 MB)"), (1_073_741_824, "Large (128 MB–1 GB)"), (4_294_967_296, "Huge (1–4 GB)")]
            for (rank, entry) in limits.enumerated() where size <= entry.0 { return Bucket(id: "size-\(rank)", title: entry.1, rank: rank) }
            return Bucket(id: "gigantic", title: "Gigantic (over 4 GB)", rank: limits.count)
        case .modified, .created:
            guard let date = key == .modified ? item.modified : item.created else { return Bucket(id: "unknown", title: "Unspecified", unknown: true) }
            let today = calendar.startOfDay(for: now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
            let week = calendar.dateInterval(of: .weekOfYear, for: now)!.start
            let lastWeek = calendar.date(byAdding: .day, value: -7, to: week)!
            let month = calendar.dateInterval(of: .month, for: now)!.start
            let lastMonth = calendar.date(byAdding: .month, value: -1, to: month)!
            let year = calendar.dateInterval(of: .year, for: now)!.start
            if date >= tomorrow { return Bucket(id: "future", title: "Future", rank: 8) }
            if date >= today { return Bucket(id: "today", title: "Today", rank: 7) }
            if date >= yesterday { return Bucket(id: "yesterday", title: "Yesterday", rank: 6) }
            if date >= week { return Bucket(id: "this-week", title: "Earlier this week", rank: 5) }
            if date >= lastWeek { return Bucket(id: "last-week", title: "Last week", rank: 4) }
            if date >= month { return Bucket(id: "this-month", title: "Earlier this month", rank: 3) }
            if date >= lastMonth { return Bucket(id: "last-month", title: "Last month", rank: 2) }
            if date >= year { return Bucket(id: "this-year", title: "Earlier this year", rank: 1) }
            return Bucket(id: "older", title: "A long time ago", rank: 0)
        }
    }
}

public struct FileGroup: Sendable, Equatable {
    public let id: String
    public let title: String
    public let items: [FileItem]
    public init(id: String, title: String, items: [FileItem]) { self.id = id; self.title = title; self.items = items }
}

/// Shared mapping for table rows, icon sections, selection and drag targets.
/// Group headings never map to a file, and collapsed items have no visible position.
public struct FileDisplayIndex: Sendable {
    public enum Row: Equatable, Sendable { case header(Int), item(Int) }
    public struct Position: Hashable, Sendable { public let section: Int; public let item: Int }
    public let rows: [Row]
    public let ranges: [Range<Int>]
    public let collapsed: Set<Int>
    private let itemRows: [Int: Int]
    private let itemPositions: [Int: Position]
    public init(groups: [FileGroup] = [], grouped: Bool = false, collapsedIDs: Set<String> = []) {
        var rows: [Row] = [], ranges: [Range<Int>] = [], hidden: Set<Int> = [], rowMap: [Int: Int] = [:], positions: [Int: Position] = [:]
        var offset = 0
        for (section, group) in groups.enumerated() {
            let range = offset..<(offset + group.items.count); ranges.append(range)
            if grouped { rows.append(.header(section)) }
            if grouped && collapsedIDs.contains(group.id) { hidden.insert(section) }
            else {
                for (local, index) in range.enumerated() {
                    rowMap[index] = rows.count; positions[index] = Position(section: section, item: local); rows.append(.item(index))
                }
            }
            offset = range.upperBound
        }
        self.rows = rows; self.ranges = ranges; self.collapsed = hidden; self.itemRows = rowMap; self.itemPositions = positions
    }
    public func item(atRow row: Int) -> Int? {
        guard rows.indices.contains(row), case let .item(index) = rows[row] else { return nil }; return index
    }
    public func item(section: Int, offset: Int) -> Int? {
        guard ranges.indices.contains(section), !collapsed.contains(section), offset >= 0, offset < ranges[section].count else { return nil }
        return ranges[section].lowerBound + offset
    }
    public func row(forItem item: Int) -> Int? { itemRows[item] }
    public func position(forItem item: Int) -> Position? { itemPositions[item] }
    public func count(inSection section: Int) -> Int { ranges.indices.contains(section) && !collapsed.contains(section) ? ranges[section].count : 0 }
}

public struct TabPresentation: Codable, Equatable, Sendable {
    public var sort: FileSort
    public var grouping: FileGrouping
    public init(sort: FileSort = FileSort(), grouping: FileGrouping = FileGrouping()) { self.sort = sort; self.grouping = grouping }
}
