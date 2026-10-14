import AppKit
import ExplorerCore

@MainActor
final class FileCollectionView: NSCollectionView, ExplorerDragSource, NSUserInterfaceValidations {
    var onOpen: (() -> Void)?
    var onBack: (() -> Void)?
    var onPreview: (() -> Void)?
    var onFileAction: ((FileAction) -> Void)?
    var canFileAction: ((FileAction) -> Bool)?
    var onContext: ((IndexPath?) -> Void)?
    var onTypeSelect: ((String) -> Void)?
    override func accessibilityChildren() -> [Any]? {
        let children = super.accessibilityChildren() ?? []
        // AppKit omits empty sections; keep their expand buttons accessible.
        let collapsed = visibleSupplementaryViews(ofKind: NSCollectionView.elementKindSectionHeader).compactMap { $0 as? FileGroupHeader }.filter(\.collapsed).map(\.accessibilityButton)
        return children + collapsed
    }
    private var typed = ""
    private var typedAt = Date.distantPast
    @objc func cut(_ sender: Any?) { onFileAction?(.cut) }
    @objc func copy(_ sender: Any?) { onFileAction?(.copy) }
    @objc func paste(_ sender: Any?) { onFileAction?(.paste) }
    @objc func undo(_ sender: Any?) { onFileAction?(.undo) }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let actions: [Selector: FileAction] = [#selector(cut): .cut, #selector(copy(_:)): .copy, #selector(paste): .paste, #selector(undo): .undo]
        if let action = item.action, let fileAction = actions[action] {
            if fileAction == .undo, let menu = item as? NSMenuItem { menu.title = FileOperationController.shared.undoTitle.map { "Undo \($0)" } ?? "Undo" }
            return canFileAction?(fileAction) == true
        }
        return true
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil { onOpen?() }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        onContext?(indexPathForItem(at: convert(event.locationInWindow, from: nil)))
        return super.menu(for: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            switch event.keyCode {
            case 36, 76: onOpen?(); return
            case 51: onBack?(); return
            case 49: onPreview?(); return
            default: break
            }
            if let characters = event.characters, characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
                if Date().timeIntervalSince(typedAt) > 1 { typed = "" }
                typed += characters; typedAt = Date(); onTypeSelect?(typed); return
            }
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class IconTile: Surface {
    var selected = false { didSet { needsDisplay = true } }
    var dropTarget = false { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
    private var hovering = false
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if selected || hovering || dropTarget {
            (selected || dropTarget ? Palette.selected : NSColor.labelColor.withAlphaComponent(0.04)).setFill()
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7)
            shape.fill()
            if dropTarget || selected { NSColor.controlAccentColor.withAlphaComponent(dropTarget ? 1 : 0.35).setStroke(); shape.lineWidth = dropTarget ? 2 : 1; shape.stroke() }
        }
    }
}

@MainActor
final class FileIconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileIconItem")
    private let picture = NSImageView()
    private let name = NSTextField(wrappingLabelWithString: "")
    private let location = FolderLocationLink()
    private var thumbnail: UUID?
    private var representedPath: String?
    private var mode = FileViewMode.large
    override func loadView() {
        view = IconTile()
        picture.imageScaling = .scaleProportionallyUpOrDown
        name.isEditable = false; name.isSelectable = false
        name.font = .systemFont(ofSize: 12); name.alignment = .center
        name.maximumNumberOfLines = 2; name.lineBreakMode = .byTruncatingMiddle
        view.addSubview(picture); view.addSubview(name); view.addSubview(location)
        location.font = .systemFont(ofSize: 10); location.textColor = .secondaryLabelColor; location.lineBreakMode = .byTruncatingMiddle
        imageView = picture; textField = name
        view.setAccessibilityElement(true); view.setAccessibilityRole(.button)
    }
    override var isSelected: Bool { didSet { (view as? IconTile)?.selected = isSelected; view.setAccessibilitySelected(isSelected) } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { (view as? IconTile)?.dropTarget = highlightState == .asDropTarget } }
    override func viewDidLayout() {
        super.viewDidLayout()
        let width = view.bounds.width, size = CGFloat(mode.iconSize)
        if mode == .small {
            picture.frame = NSRect(x: 8, y: (view.bounds.height - size) / 2, width: size, height: size)
            name.frame = NSRect(x: size + 17, y: location.isHidden ? (view.bounds.height - 18) / 2 : 6, width: max(0, width - size - 25), height: 18)
            location.frame = NSRect(x: size + 17, y: 27, width: max(0, width - size - 25), height: 16)
        } else {
            picture.frame = NSRect(x: (width - size) / 2, y: 10, width: size, height: size)
            name.frame = NSRect(x: 6, y: size + 18, width: max(0, width - 12), height: 35)
            location.frame = NSRect(x: 6, y: size + 53, width: max(0, width - 12), height: 16)
        }
    }
    func configure(_ item: FileItem, mode: FileViewMode, fallback: NSImage, dimmed: Bool, scale: CGFloat, location: String? = nil, query: String = "", onReveal: (() -> Void)? = nil) {
        cancelThumbnail(); _ = view
        self.mode = mode; representedPath = item.id
        self.location.isHidden = location == nil
        self.location.alignment = mode == .small ? .left : .center
        name.alignment = mode == .small ? .left : .center
        name.maximumNumberOfLines = mode == .small ? 1 : 2
        SearchHighlight.apply(item.name, to: name, query: query)
        self.location.configure(location ?? "", query: query, file: item.url, onOpen: location == nil ? nil : onReveal)
        picture.image = fallback
        picture.alphaValue = dimmed ? 0.35 : item.isHidden ? 0.6 : 1; name.alphaValue = picture.alphaValue
        view.toolTip = [item.url.path, FileColors.description(item.finderColors)].filter { !$0.isEmpty }.joined(separator: "\n")
        view.setAccessibilityLabel([item.name, FileColors.description(item.finderColors)].filter { !$0.isEmpty }.joined(separator: ", "))
        view.setAccessibilityHelp(item.isNavigable ? "Folder. Double-click to open, or drop files here." : "Press Space for Quick Look.")
        view.needsLayout = true
        guard mode != .small else { return }
        thumbnail = ThumbnailStore.shared.request(item, size: mode.iconSize, scale: scale) { [weak self] image in
            guard let self, self.representedPath == item.id else { return }
            self.picture.image = FileColors.badged(image, colors: item.finderColors.colors)
        }
    }
    func onAccessibilityPress(_ action: @escaping () -> Void) { (view as? IconTile)?.onPress = action }
    func cancelThumbnail() { ThumbnailStore.shared.cancel(thumbnail); thumbnail = nil; representedPath = nil }
    override func prepareForReuse() {
        cancelThumbnail()
        location.configure("", query: "", file: URL(fileURLWithPath: "/"), onOpen: nil)
        super.prepareForReuse()
    }
}
