import AppKit

@MainActor
private final class ContextMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

@MainActor
enum ContextMenu {
    static func item(_ title: String, symbol: String, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let item = ContextMenuItem(title: title, handler: action)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.isEnabled = enabled
        return item
    }
    static func configure(_ menu: NSMenu) {
        menu.removeAllItems(); menu.autoenablesItems = false
        menu.minimumWidth = 270
    }
    static func addFileActions(to menu: NSMenu, enabled: (FileAction) -> Bool, perform: @escaping (FileAction) -> Void) {
        // AppKit's inline palette retains native keyboard navigation, VoiceOver,
        // disabled states, and menu tracking while matching Explorer's action row.
        let palette = NSMenu(); palette.autoenablesItems = false; palette.presentationStyle = .palette
        for action in [FileAction.cut, .copy, .paste, .rename, .trash] {
            let item = item(action == .rename ? "Rename" : action.title, symbol: action.menuSymbol, enabled: enabled(action)) { perform(action) }
            item.toolTip = action.title
            palette.addItem(item)
        }
        let row = NSMenuItem(title: "File Actions", action: nil, keyEquivalent: ""); row.submenu = palette
        menu.addItem(row); menu.addItem(.separator())
    }
}

extension FileAction {
    var menuSymbol: String {
        switch self {
        case .cut: "scissors"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .rename: "character.cursor.ibeam"
        case .trash: "trash"
        case .compress: "doc.zipper"
        case .extract: "archivebox"
        case .properties: "info.circle"
        case .move: "folder"
        case .newFolder: "folder.badge.plus"
        case .undo: "arrow.uturn.backward"
        case .cancel: "xmark.circle"
        }
    }
}
