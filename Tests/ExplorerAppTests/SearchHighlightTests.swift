import AppKit
import Testing
import ExplorerCore
@testable import ExplorerApp

@Suite @MainActor
struct SearchHighlightTests {
    @Test func matchesKeepOriginalUnicodeRangesAndFindEveryOccurrence() {
        let samples: [(String, String, [String])] = [
            ("IAG_iag_IaG.xlsx", " iag ", ["IAG", "iag", "IaG"]),
            ("🗂 Résumé-re\u{301}sume\u{301}.txt", "resume", ["Résumé", "re\u{301}sume\u{301}"]),
            ("👩‍💻-👩‍💻.png", "👩‍💻", ["👩‍💻", "👩‍💻"]),
            ("report.txt", " ", []), ("report.txt", "missing", [])
        ]
        for (text, query, expected) in samples {
            let ranges = SearchHighlight.ranges(in: text, query: query)
            #expect(ranges.map { (text as NSString).substring(with: $0) } == expected)
            for pair in zip(ranges, ranges.dropFirst()) { #expect(NSMaxRange(pair.0) <= pair.1.location) }
        }
    }

    @Test func reusedIconsClearBothFilenameAndLocationHighlights() throws {
        _ = NSApplication.shared
        let cell = FileIconItem()
        let item = FileItem(url: URL(fileURLWithPath: "/tmp/report-report.txt"), name: "report-report.txt", isDirectory: false)
        cell.configure(item, mode: .small, fallback: NSImage(), dimmed: false, scale: 2, location: "Reports/Archive", query: "report")
        let name = try #require(cell.textField)
        let location = try #require(cell.view.subviews.compactMap { $0 as? NSTextField }.first { $0 !== name })
        #expect(name.attributedStringValue.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
        #expect(name.attributedStringValue.attribute(.backgroundColor, at: 7, effectiveRange: nil) != nil)
        #expect(name.attributedStringValue.attribute(.backgroundColor, at: 6, effectiveRange: nil) == nil)
        #expect(location.attributedStringValue.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
        cell.configure(item, mode: .small, fallback: NSImage(), dimmed: false, scale: 2, location: "Reports/Archive", query: "")
        for label in [name, location] {
            let value = label.attributedStringValue
            for index in 0..<value.length { #expect(value.attribute(.backgroundColor, at: index, effectiveRange: nil) == nil) }
        }
        #expect(name.stringValue == item.name)
        #expect(name.alignment == .left)
        #expect(location.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
    }
}
