import AppKit
import ExplorerCore

@MainActor
enum FileColors {
    static func color(_ value: FinderColor) -> NSColor {
        switch value {
        case .none: .clear
        case .gray: .systemGray
        case .green: .systemGreen
        case .purple: .systemPurple
        case .blue: .systemBlue
        case .yellow: .systemYellow
        case .red: .systemRed
        case .orange: .systemOrange
        }
    }
    static func cacheKey(_ item: FileItem) -> NSString {
        (item.id + "\ncolors:" + item.finderColors.colors.map { String($0.rawValue) }.joined(separator: ",")) as NSString
    }
    static func icon(_ item: FileItem) -> NSImage {
        if item.isNavigable && !item.isSymbolicLink {
            let base = item.finderColors.colors.first.map { Palette.makeFolderIcon(tint: color($0)) } ?? Palette.folderIcon
            return badged(base, colors: Array(item.finderColors.colors.dropFirst()))
        }
        return badged(NSWorkspace.shared.icon(forFile: item.url.path), colors: item.finderColors.colors)
    }
    static func badged(_ image: NSImage, colors: [FinderColor]) -> NSImage {
        guard !colors.isEmpty else { return image }
        return NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            let scale = min(rect.width / max(1, image.size.width), rect.height / max(1, image.size.height))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            for (index, value) in colors.prefix(3).reversed().enumerated() {
                let dot = NSBezierPath(ovalIn: NSRect(x: 91 - CGFloat(index) * 22, y: 3, width: 32, height: 32))
                NSColor.white.setStroke(); dot.lineWidth = 5; dot.stroke()
                color(value).setFill(); dot.fill()
            }
            return true
        }
    }
    static func description(_ info: FinderColorSummary) -> String {
        let names = info.names.isEmpty ? info.colors.map(\.name) : info.names
        return names.isEmpty ? "" : "Tags: " + names.joined(separator: ", ")
    }
}

@MainActor
final class FileColorMenu: NSObject {
    static let shared = FileColorMenu()
    private final class Choice {
        let urls: [URL]
        let color: FinderColor
        weak var window: NSWindow?
        init(_ urls: [URL], _ color: FinderColor, _ window: NSWindow) { self.urls = urls; self.color = color; self.window = window }
    }
    func item(urls: [URL], summaries: [FinderColorSummary], window: NSWindow) -> NSMenuItem {
        let parent = NSMenuItem(title: "Color Label", action: nil, keyEquivalent: "")
        let menu = NSMenu(); menu.autoenablesItems = false
        for value in FinderColor.menuOrder {
            let item = NSMenuItem(title: value == .none ? "Remove Color Label" : value.name, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = Choice(urls, value, window)
            item.isEnabled = !FileOperationController.shared.busy && window.attachedSheet == nil && !urls.isEmpty
            if value != .none {
                item.image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
                    FileColors.color(value).setFill(); NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 10, height: 10)).fill(); return true
                }
                let count = summaries.filter { $0.colors.contains(value) }.count
                item.state = count == 0 ? .off : count == urls.count ? .on : .mixed
            }
            item.toolTip = "Shared with Finder. Custom named tags are preserved."
            if value == .none { menu.addItem(.separator()) }
            menu.addItem(item)
        }
        parent.submenu = menu; return parent
    }
    @objc private func choose(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice, let window = choice.window,
              !FileOperationController.shared.busy, window.attachedSheet == nil else { return }
        FileOperationController.shared.run(.color(choice.urls, choice.color), window: window)
    }
}
