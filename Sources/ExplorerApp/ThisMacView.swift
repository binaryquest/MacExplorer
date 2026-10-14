import AppKit
import ExplorerCore

@MainActor
private enum StorageArtwork {
    static func icon(_ kind: StorageLocation.Kind) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 54), flipped: false) { _ in
            let top = NSBezierPath()
            top.move(to: NSPoint(x: 3, y: 20)); top.line(to: NSPoint(x: 16, y: 40))
            top.line(to: NSPoint(x: 49, y: 40)); top.line(to: NSPoint(x: 61, y: 20)); top.close()
            NSGradient(starting: NSColor(calibratedWhite: 0.92, alpha: 1), ending: NSColor(calibratedWhite: 0.64, alpha: 1))?.draw(in: top, angle: -90)
            let front = NSBezierPath(roundedRect: NSRect(x: 3, y: 7, width: 58, height: 17), xRadius: 3, yRadius: 3)
            NSGradient(starting: NSColor(calibratedWhite: 0.34, alpha: 1), ending: NSColor(calibratedWhite: 0.13, alpha: 1))?.draw(in: front, angle: -90)
            (kind == .network ? NSColor.systemGreen : NSColor.systemBlue).setFill()
            NSBezierPath(ovalIn: NSRect(x: 9, y: 12, width: 4, height: 4)).fill()
            if kind == .network { NSColor.systemGreen.setFill(); NSRect(x: 3, y: 7, width: 58, height: 4).fill() }
            if kind == .googleDrive {
                // A small three-color provider badge keeps multiple cloud services distinct.
                for (color, points) in [
                    (NSColor.systemGreen, [NSPoint(x: 34,y: 25), NSPoint(x: 43,y: 42), NSPoint(x: 48,y: 34), NSPoint(x: 39,y: 17)]),
                    (NSColor.systemYellow, [NSPoint(x: 43,y: 42), NSPoint(x: 52,y: 42), NSPoint(x: 62,y: 25), NSPoint(x: 53,y: 25)]),
                    (NSColor.systemBlue, [NSPoint(x: 39,y: 17), NSPoint(x: 57,y: 17), NSPoint(x: 62,y: 25), NSPoint(x: 44,y: 25)])
                ] {
                    let path = NSBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }; path.close(); color.setFill(); path.fill()
                }
            } else if kind == .cloud {
                NSColor.systemBlue.setFill()
                NSBezierPath(roundedRect: NSRect(x: 34, y: 23, width: 29, height: 12), xRadius: 6, yRadius: 6).fill()
                NSBezierPath(ovalIn: NSRect(x: 40, y: 29, width: 15, height: 14)).fill()
                NSBezierPath(ovalIn: NSRect(x: 50, y: 26, width: 12, height: 12)).fill()
            }
            return true
        }
    }
}

@MainActor
private final class CapacityBar: NSView {
    var capacity: StorageCapacity? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.12).setFill(); bounds.fill()
        if let capacity {
            (capacity.lowSpace ? NSColor.systemRed : NSColor.systemBlue).setFill()
            NSRect(x: 0, y: 0, width: bounds.width * capacity.usedFraction, height: bounds.height).fill()
        }
        NSColor.separatorColor.setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

@MainActor
private final class StorageTile: FolderDropSurface {
    var selected = false { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if selected { Palette.selected.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4).fill() }
    }
}

@MainActor
private final class StorageCard: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("StorageCard")
    private let picture = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let capacityLabel = NSTextField(labelWithString: "")
    private let bar = CapacityBar()
    override func loadView() {
        view = StorageTile()
        for child in [picture, name, subtitle, bar, capacityLabel] { view.addSubview(child) }
        picture.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 13); subtitle.font = .systemFont(ofSize: 10)
        capacityLabel.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor; capacityLabel.textColor = .secondaryLabelColor
        for label in [name, subtitle, capacityLabel] { label.lineBreakMode = .byTruncatingMiddle }
        view.setAccessibilityElement(true); view.setAccessibilityRole(.button)
    }
    override var isSelected: Bool { didSet { (view as? StorageTile)?.selected = isSelected; view.setAccessibilitySelected(isSelected) } }
    override func viewDidLayout() {
        super.viewDidLayout()
        picture.frame = NSRect(x: 10, y: 22, width: 48, height: 48)
        let x: CGFloat = 70, width = max(0, view.bounds.width - 82)
        name.frame = NSRect(x: x, y: 8, width: width, height: 20)
        subtitle.frame = NSRect(x: x, y: 29, width: width, height: 15)
        bar.frame = NSRect(x: x, y: 49, width: width, height: 13)
        capacityLabel.frame = NSRect(x: x, y: bar.isHidden ? 48 : 66, width: width, height: 17)
    }
    func configure(_ location: StorageLocation, query: String, onSelect: @escaping () -> Void) {
        loadViewIfNeeded()
        SearchHighlight.apply(location.title, to: name, query: query)
        SearchHighlight.apply(location.detail, to: subtitle, query: query, color: .secondaryLabelColor)
        picture.image = StorageArtwork.icon(location.kind)
        bar.capacity = location.capacity; bar.isHidden = location.capacity == nil
        if let capacity = location.capacity {
            capacityLabel.stringValue = "\(ByteCountFormatter.string(fromByteCount: capacity.available, countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: capacity.total, countStyle: .file))"
            capacityLabel.textColor = capacity.lowSpace ? .systemRed : .secondaryLabelColor
        } else {
            capacityLabel.stringValue = location.kind == .googleDrive || location.kind == .cloud ? "Cloud storage" : "Storage information unavailable"
            capacityLabel.textColor = .secondaryLabelColor
        }
        let tile = view as! StorageTile
        tile.onPress = onSelect
        tile.dropDestination = location.readOnly ? nil : { location.url }
        view.toolTip = location.url.path + "\n" + capacityLabel.stringValue
        view.setAccessibilityLabel("\(location.title), \(location.detail), \(capacityLabel.stringValue)")
        view.setAccessibilityHelp("Double-click or press Return to open this location.")
        view.needsLayout = true
    }
}

@MainActor
final class ThisMacView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSMenuDelegate {
    let collection = FileCollectionView()
    private let scroll = NSScrollView()
    private let flow = NSCollectionViewFlowLayout()
    private var sections: [(String, [StorageLocation])] = []
    private var collapsed = Set<String>()
    private var query = ""
    private let empty = NSTextField(wrappingLabelWithString: "")
    var onOpen: ((URL, Bool) -> Void)?
    var onOtherPane: ((URL) -> Void)?
    var onBack: (() -> Void)?
    var onSelection: (() -> Void)?
    var itemCount: Int { sections.reduce(0) { $0 + $1.1.count } }
    var selectedLocation: StorageLocation? { collection.selectionIndexPaths.sorted().first.flatMap(location) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        collection.collectionViewLayout = flow; collection.isSelectable = true
        collection.backgroundColors = [.controlBackgroundColor]; collection.autoresizingMask = [.width]
        collection.dataSource = self; collection.delegate = self
        collection.register(StorageCard.self, forItemWithIdentifier: StorageCard.identifier)
        collection.register(FileGroupHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: FileGroupHeader.identifier)
        collection.setAccessibilityLabel("This Mac drives and network locations")
        collection.onOpen = { [weak self] in self?.openSelection(newTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true) }
        collection.onBack = { [weak self] in self?.onBack?() }
        collection.onContext = { [weak self] path in self?.collection.selectionIndexPaths = path.map { [$0] } ?? []; self?.onSelection?() }
        collection.onTypeSelect = { [weak self] text in
            guard let self else { return }
            for (section, value) in self.sections.enumerated() where !self.collapsed.contains(value.0) {
                if let index = value.1.firstIndex(where: { $0.title.lowercased().hasPrefix(text.lowercased()) }) {
                    let path = IndexPath(item: index, section: section)
                    self.collection.selectionIndexPaths = [path]; self.collection.scrollToItems(at: [path], scrollPosition: .nearestVerticalEdge); self.onSelection?(); return
                }
            }
        }
        let menu = NSMenu(); menu.delegate = self; collection.menu = menu
        flow.minimumInteritemSpacing = 10; flow.minimumLineSpacing = 8
        scroll.documentView = collection; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
        empty.font = .systemFont(ofSize: 13); empty.textColor = .secondaryLabelColor; empty.alignment = .center
        addSubview(empty); empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor), empty.centerXAnchor.constraint(equalTo: centerXAnchor), empty.centerYAnchor.constraint(equalTo: centerYAnchor), empty.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); flow.invalidateLayout() }
    func update(_ locations: [StorageLocation], query: String, loading: Bool) {
        self.query = query
        let selected = selectedLocation?.id
        let values = StorageDiscovery.overview(locations, query: query)
        sections = [("Devices and drives", values.filter { !$0.isNetworkLocation }), ("Network locations", values.filter(\.isNetworkLocation))].filter { !$0.1.isEmpty }
        collection.reloadData(); flow.invalidateLayout()
        if let selected {
            for (section, entry) in sections.enumerated() where !collapsed.contains(entry.0) {
                if let item = entry.1.firstIndex(where: { $0.id == selected }) { collection.selectionIndexPaths = [IndexPath(item: item, section: section)] }
            }
        }
        empty.stringValue = loading ? "Discovering drives and cloud folders…" : query.isEmpty ? "No storage locations are available." : "No locations match “\(query)”."
        empty.isHidden = !values.isEmpty
    }
    func location(_ path: IndexPath) -> StorageLocation? {
        guard sections.indices.contains(path.section), !collapsed.contains(sections[path.section].0), sections[path.section].1.indices.contains(path.item) else { return nil }
        return sections[path.section].1[path.item]
    }
    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { collapsed.contains(sections[section].0) ? 0 : sections[section].1.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt path: IndexPath) -> NSCollectionViewItem {
        let card = collectionView.makeItem(withIdentifier: StorageCard.identifier, for: path) as! StorageCard
        if let location = location(path) { card.configure(location, query: query) { [weak self] in self?.collection.selectionIndexPaths = [path]; self?.window?.makeFirstResponder(self?.collection); self?.onSelection?() } }
        return card
    }
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        let available = max(240, collectionView.bounds.width - 24)
        let columns = max(1, Int((available + 10) / 330))
        return NSSize(width: min(410, floor((available - CGFloat(columns - 1) * 10) / CGFloat(columns))), height: 96)
    }
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, insetForSectionAt section: Int) -> NSEdgeInsets { NSEdgeInsets(top: 4, left: 12, bottom: 12, right: 12) }
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> NSSize { NSSize(width: collectionView.bounds.width, height: 36) }
    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: String, at path: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: FileGroupHeader.identifier, for: path) as! FileGroupHeader
        let section = sections[path.section]
        header.configure(title: section.0, count: section.1.count, collapsed: collapsed.contains(section.0))
        header.onToggle = { [weak self] in
            guard let self else { return }
            if self.collapsed.contains(section.0) { self.collapsed.remove(section.0) } else { self.collapsed.insert(section.0) }
            self.collection.selectionIndexPaths = []; self.collection.reloadData(); self.flow.invalidateLayout(); self.onSelection?()
        }
        return header
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { onSelection?() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { onSelection?() }
    func openSelection(newTab: Bool = false) { if let selectedLocation { onOpen?(selectedLocation.url, newTab) } }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard selectedLocation != nil else { return }
        for (title, action) in [("Open", #selector(open)), ("Open in New Tab", #selector(openInTab)), ("Open in Other Pane", #selector(openInOtherPane)), ("Copy Path", #selector(copyPath))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
    }
    @objc private func open() { openSelection() }
    @objc private func openInTab() { openSelection(newTab: true) }
    @objc private func openInOtherPane() { if let selectedLocation { onOtherPane?(selectedLocation.url) } }
    @objc func copyPath() { if let selectedLocation { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selectedLocation.url.path, forType: .string) } }
}
