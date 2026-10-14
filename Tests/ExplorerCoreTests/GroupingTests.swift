import XCTest
@testable import ExplorerCore

final class GroupingTests: XCTestCase {
    private func file(_ name: String, size: Int64? = 10, modified: Date? = nil, created: Date? = nil, folder: Bool = false) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/fixture/" + name), name: name, isDirectory: folder, modified: modified, created: created, size: folder ? nil : size)
    }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; value.firstWeekday = 2; return value
    }
    private func date(_ year: Int = 2026, _ month: Int = 10, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    func testGroupAndSortAreIndependentAndNoItemsAreLost() {
        let items = [file("z.pdf", size: 3), file("a.txt", size: 40), file("b.txt", size: 1), file("Folder", folder: true)]
        let groups = FileGrouping(key: .kind).sections(from: FileSort(key: .size, ascending: false).apply(to: items))
        XCTAssertEqual(groups.map(\.title), ["Folder", "PDF file", "TXT file"])
        XCTAssertEqual(groups.last?.items.map(\.name), ["a.txt", "b.txt"])
        XCTAssertEqual(Set(groups.flatMap(\.items).map(\.id)), Set(items.map(\.id)))
        let reversedGroups = FileGrouping(key: .kind, ascending: false).sections(from: FileSort(key: .size, ascending: false).apply(to: items))
        XCTAssertEqual(reversedGroups.first?.title, "TXT file")
        XCTAssertEqual(reversedGroups.first?.items.map(\.name), ["a.txt", "b.txt"])
        XCTAssertEqual(FileGrouping().sections(from: items).first?.items, items)
    }
    func testDateBucketsUseCalendarBoundariesAndPlaceUnknownLast() {
        let now = date(2026, 10, 14)
        let items = [file("old", modified: date(2025, 2, 1)), file("today", modified: date(2026, 10, 14, hour: 0)), file("yesterday", modified: date(2026, 10, 13)), file("week", modified: date(2026, 10, 12)), file("lastweek", modified: date(2026, 10, 11)), file("month", modified: date(2026, 10, 2)), file("lastmonth", modified: date(2026, 9, 20)), file("year", modified: date(2026, 2, 1)), file("future", modified: date(2026, 10, 15, hour: 0)), file("unknown")]
        let groups = FileGrouping(key: .modified).sections(from: items, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["Future", "Today", "Yesterday", "Earlier this week", "Last week", "Earlier this month", "Last month", "Earlier this year", "A long time ago", "Unspecified"])
        let ascending = FileGrouping(key: .modified, ascending: true).sections(from: items, now: now, calendar: calendar)
        XCTAssertEqual(ascending.first?.title, "A long time ago"); XCTAssertEqual(ascending.last?.title, "Unspecified")
    }
    func testDateBucketsAcrossNewYearAndDaylightSaving() {
        let yearBoundary = FileGrouping(key: .modified).sections(from: [file("last-year", modified: date(2025, 12, 31))], now: date(2026, 1, 1), calendar: calendar)
        XCTAssertEqual(yearBoundary.first?.title, "Yesterday")
        var local = calendar; local.timeZone = TimeZone(identifier: "America/New_York")!
        let now = local.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 1))!
        let yesterday = local.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0))!
        XCTAssertEqual(FileGrouping(key: .modified).sections(from: [file("dst", modified: yesterday)], now: now, calendar: local).first?.title, "Yesterday")
    }
    func testCreatedDateIsSeparateFromModificationAndCanSort() {
        let first = file("first", modified: date(2026, 10, 14), created: date(2026, 10, 13))
        let second = file("second", modified: date(2026, 10, 13), created: date(2026, 10, 14))
        XCTAssertEqual(FileSort(key: .created, ascending: false).apply(to: [first, second]).map(\.name), ["second", "first"])
        XCTAssertEqual(FileGrouping(key: .created).sections(from: [first, second], now: date(2026, 10, 14), calendar: calendar).first?.items.map(\.name), ["second"])
    }
    func testNameBucketsAndHiddenFilter() {
        let items = [file("99.txt"), file("éclair.txt"), file("notes.txt"), file("zebra.txt"), file("বাংলা.txt")]
        XCTAssertEqual(FileGrouping(key: .name).sections(from: items).map(\.title), ["0–9", "A–H", "I–P", "Q–Z", "Other"])
        let hidden = FileItem(url: URL(fileURLWithPath: "/fixture/.secret"), name: ".secret", isDirectory: false, isHidden: true)
        let groups = FileGrouping(key: .kind).sections(from: FileSort().apply(to: items + [hidden], query: "notes"))
        XCTAssertEqual(groups.flatMap(\.items).map(\.name), ["notes.txt"])
    }
    func testSizeGroupBoundariesAndUnspecified() {
        let items = [file("folder", folder: true), file("empty", size: 0), file("tiny", size: 16_384), file("small", size: 16_385), file("medium", size: 1_048_577), file("large", size: 134_217_729), file("huge", size: 1_073_741_825), file("gigantic", size: 4_294_967_297), file("unknown", size: nil)]
        let groups = FileGrouping(key: .size).sections(from: items)
        XCTAssertEqual(groups.count, 9); XCTAssertEqual(groups.flatMap(\.items), items)
        XCTAssertEqual(groups.first?.title, "Folders"); XCTAssertEqual(groups.last?.title, "Unspecified")
    }
    func testDisplayMappingExcludesHeadersAndCollapsedFiles() {
        let groups = [FileGroup(id: "a", title: "A", items: [file("a"), file("b")]), FileGroup(id: "b", title: "B", items: [file("c"), file("d")])]
        let index = FileDisplayIndex(groups: groups, grouped: true, collapsedIDs: ["a"])
        XCTAssertEqual(index.rows, [.header(0), .header(1), .item(2), .item(3)])
        XCTAssertNil(index.item(atRow: 0)); XCTAssertNil(index.item(atRow: -1)); XCTAssertNil(index.item(atRow: 100))
        XCTAssertNil(index.item(section: 0, offset: 0)); XCTAssertNil(index.row(forItem: 0)); XCTAssertNil(index.position(forItem: 0))
        XCTAssertEqual(index.item(section: 1, offset: 1), 3); XCTAssertNil(index.item(section: 1, offset: 2))
        for item in [2, 3] {
            let position = index.position(forItem: item)!
            XCTAssertEqual(index.item(section: position.section, offset: position.item), item)
            XCTAssertEqual(index.item(atRow: index.row(forItem: item)!), item)
        }
        let expanded = FileDisplayIndex(groups: groups, grouped: true)
        XCTAssertEqual(expanded.row(forItem: 0), 1); XCTAssertEqual(expanded.row(forItem: 2), 4)
    }
    func testPresentationPersistenceAndOlderSessionMigration() throws {
        let presentation = TabPresentation(sort: FileSort(key: .size, ascending: false), grouping: FileGrouping(key: .modified))
        let pane = PaneSession(paths: ["invalid", "/One", "/Two"], modes: ["", "details", "large"], presentations: [TabPresentation(), presentation])
        XCTAssertEqual(pane.presentations, [presentation, TabPresentation()])
        XCTAssertEqual(try JSONDecoder().decode(PaneSession.self, from: JSONEncoder().encode(pane)), pane)
        let old = Data(#"{"paths":["/One"],"active":0,"modes":["details"]}"#.utf8)
        let restored = try JSONDecoder().decode(PaneSession.self, from: old).sanitized
        XCTAssertNil(restored.presentations); XCTAssertEqual(restored.paths, ["/One"])
    }
}
