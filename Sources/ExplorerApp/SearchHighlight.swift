import AppKit

@MainActor
enum SearchHighlight {
    private static let background = NSColor(name: "ExplorerSearchMatch") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.96, green: 0.79, blue: 0.30, alpha: 1)
            : NSColor(calibratedRed: 1, green: 0.96, blue: 0.55, alpha: 1)
    }
    private static let foreground = NSColor(calibratedWhite: 0.08, alpha: 1)

    /// Use the same localized matching as filename search, without converting
    /// the displayed text to lowercase or losing its original Unicode ranges.
    static func ranges(in text: String, query: String) -> [NSRange] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var ranges: [NSRange] = [], start = text.startIndex
        while start < text.endIndex,
              let match = text[start...].localizedStandardRange(of: query), !match.isEmpty {
            ranges.append(NSRange(match, in: text))
            start = match.upperBound
        }
        return ranges
    }

    static func apply(_ text: String, to label: NSTextField, query: String, color: NSColor = .labelColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = label.alignment; paragraph.lineBreakMode = label.lineBreakMode
        let value = NSMutableAttributedString(string: text, attributes: [
            .font: label.font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: color, .paragraphStyle: paragraph
        ])
        for range in ranges(in: text, query: query) {
            value.addAttributes([.backgroundColor: background, .foregroundColor: foreground], range: range)
        }
        // Replace the complete attributed value so reused cells never retain
        // highlights from another query, tab, or a closed search.
        label.attributedStringValue = value
    }
}
