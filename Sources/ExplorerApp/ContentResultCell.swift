import AppKit
import ExplorerCore

/// Explorer's Content view: a full-width result with its context alongside it.
@MainActor
final class ContentResultCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ContentResultCell")
    static let compactWidth: CGFloat = 720
    static func rowHeight(for width: CGFloat) -> CGFloat { width < compactWidth ? 82 : 62 }
    let nameLabel = NSTextField(labelWithString: "")
    let modifiedLabel = NSTextField(labelWithString: "")
    let locationLabel = FolderLocationLink()
    let sizeLabel = NSTextField(labelWithString: "")
    let kindLabel = NSTextField(labelWithString: "")
    private let picture = NSImageView()
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        autoresizingMask = [.width, .height]
        for child in [picture, nameLabel, modifiedLabel, locationLabel, sizeLabel, kindLabel] { addSubview(child) }
        picture.imageScaling = .scaleProportionallyUpOrDown
        imageView = picture; textField = nameLabel
        nameLabel.font = .systemFont(ofSize: 13)
        locationLabel.font = .systemFont(ofSize: 12)
        for label in [modifiedLabel, sizeLabel, kindLabel] {
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        }
        for label in [nameLabel, modifiedLabel, locationLabel, sizeLabel, kindLabel] {
            label.lineBreakMode = .byTruncatingMiddle
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: FileItem, query: String, icon: NSImage, modified: String, dimmed: Bool, onReveal: (() -> Void)? = nil) {
        let path = item.url.deletingLastPathComponent().path
        SearchHighlight.apply(item.name, to: nameLabel, query: query)
        locationLabel.configure(path, query: query, file: item.url, onOpen: onReveal)
        modifiedLabel.stringValue = "Date modified: \(modified)"
        sizeLabel.stringValue = "Size: " + (item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
        kindLabel.stringValue = "Type: \(item.kind)"
        picture.image = icon
        alphaValue = dimmed ? 0.35 : item.isHidden ? 0.6 : 1
        nameLabel.toolTip = item.name
        modifiedLabel.toolTip = modifiedLabel.stringValue; sizeLabel.toolTip = sizeLabel.stringValue
        toolTip = [item.url.path, modifiedLabel.stringValue, sizeLabel.stringValue, kindLabel.stringValue, FileColors.description(item.finderColors)]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width, leading: CGFloat = 58, trailing: CGFloat = 16
        let compact = width < Self.compactWidth
        picture.frame = NSRect(x: 14, y: compact ? 15 : 14, width: 32, height: 32)
        kindLabel.isHidden = compact
        if compact {
            let available = max(0, width - leading - trailing)
            nameLabel.frame = NSRect(x: leading, y: 9, width: available, height: 19)
            locationLabel.frame = NSRect(x: leading, y: 31, width: available, height: 17)
            let sizeWidth = min(110, available * 0.34)
            modifiedLabel.frame = NSRect(x: leading, y: 55, width: max(0, available - sizeWidth - 10), height: 16)
            sizeLabel.frame = NSRect(x: width - trailing - sizeWidth, y: 55, width: sizeWidth, height: 16)
        } else {
            let locationX = width * 0.48, sizeX = width * 0.81
            nameLabel.frame = NSRect(x: leading, y: 11, width: locationX - leading - 22, height: 19)
            modifiedLabel.frame = NSRect(x: leading, y: 34, width: locationX - leading - 22, height: 16)
            locationLabel.frame = NSRect(x: locationX, y: 12, width: sizeX - locationX - 20, height: 18)
            sizeLabel.frame = NSRect(x: sizeX, y: 13, width: width - sizeX - trailing, height: 16)
            kindLabel.frame = NSRect(x: sizeX, y: 34, width: width - sizeX - trailing, height: 16)
        }
    }
}

extension BrowserViewController {
    func configureTablePresentation() {
        let content = viewMode == .content
        if content != tableShowsContent {
            if content { detailColumnWidths = Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier.rawValue, $0.width) }) }
            else {
                for column in table.tableColumns {
                    if let width = detailColumnWidths[column.identifier.rawValue] { column.width = width }
                }
            }
            tableShowsContent = content
            table.headerView = content ? nil : detailsHeaderView
            tableScroll.hasHorizontalScroller = !content
            table.intercellSpacing = NSSize(width: 0, height: content ? 0 : 1)
            table.enumerateAvailableRowViews { row, index in
                (row as? FileRowView)?.contentSeparator = content && self.file(atRow: index) != nil
            }
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
        }
        for column in table.tableColumns {
            switch column.identifier.rawValue {
            case "name": column.isHidden = false
            case "location": column.isHidden = content || !tab.isRecursiveSearch
            case "created": column.isHidden = content || (tab.sort.key != .created && tab.grouping.key != .created)
            default: column.isHidden = content
            }
        }
        table.setAccessibilityLabel(content ? (tab.hasSearchQuery ? "Search results, Content view" : "Files, Content view") : "Files in current folder")
        fitContentTable()
    }

    @objc func contentTableResized(_ notification: Notification) { fitContentTable() }
    func fitContentTable() {
        guard tableShowsContent else { return }
        let width = max(220, tableScroll.contentSize.width)
        if table.frame.width != width { table.setFrameSize(NSSize(width: width, height: table.frame.height)) }
        if let name = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")), name.width != width { name.width = width }
        let compact = width < ContentResultCell.compactWidth
        if compact != compactContentRows {
            compactContentRows = compact
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
        }
    }
}
