import AppKit
import Quartz
import ExplorerCore

@MainActor
final class FilePreviewSidebar: NSView {
    private let heading = NSTextField(labelWithString: "预览")
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let body = NSView()
    private let hint = NSTextField(labelWithString: "选择文件以预览")
    private let emptyIcon = NSImageView()
    private var markdown: MarkdownPreview?
    private var renderer: QLPreviewView?
    private var selected: FileItem?
    private var count = -1

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        let glyph = NSImageView(image: Palette.buttonSymbol("sidebar.right") ?? NSImage())
        let header = NSStackView(views: [glyph, heading])
        header.spacing = 7
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        emptyIcon.contentTintColor = .tertiaryLabelColor
        let empty = NSStackView(views: [emptyIcon, hint])
        empty.orientation = .vertical
        empty.spacing = 10
        let captions = NSStackView(views: [name, detail])
        captions.orientation = .vertical
        captions.alignment = .leading
        captions.spacing = 3
        let footer = NSStackView(views: [icon, captions])
        footer.spacing = 9
        let rule = NSBox()
        rule.boxType = .separator
        for child in [header, body, rule, footer] {
            addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        body.addSubview(empty)
        empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            empty.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            emptyIcon.widthAnchor.constraint(equalToConstant: 32), emptyIcon.heightAnchor.constraint(equalToConstant: 32),
            rule.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 8),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor), rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            footer.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 8),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            icon.heightAnchor.constraint(equalToConstant: 28), icon.widthAnchor.constraint(equalToConstant: 28)
        ])
        update([])
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ items: [FileItem]) {
        let item = items.count == 1 ? items[0] : nil
        guard selected != item || count != items.count else { return }
        selected = item
        count = items.count
        let show = item.map { !$0.isDirectory } ?? false
        let isMarkdown = show && ["md", "markdown", "mdown", "mkd"].contains(item?.url.pathExtension.lowercased() ?? "")
        if isMarkdown, let item {
            let preview = markdown ?? MarkdownPreview(frame: body.bounds)
            if markdown == nil { body.addSubview(preview); markdown = preview }
            preview.display(item.url)
        } else {
            markdown?.clear()
        }
        if show, !isMarkdown, let item {
            if renderer == nil, let preview = QLPreviewView(frame: body.bounds, style: .normal) {
                preview.autostarts = false
                preview.autoresizingMask = [.width, .height]
                body.addSubview(preview)
                renderer = preview
            }
            renderer?.previewItem = item.url as NSURL
        } else if let preview = renderer {
            preview.previewItem = nil
            preview.close()
            preview.removeFromSuperview()
            renderer = nil
        }
        emptyIcon.superview?.isHidden = isMarkdown || (show && renderer != nil)
        emptyIcon.image = NSImage(systemSymbolName: item?.isDirectory == true ? "folder" : "doc.text", accessibilityDescription: nil)
        hint.stringValue = item?.isDirectory == true ? item!.kind : items.count > 1 ? "已选中 \(items.count) 项" : item == nil ? "选择文件以预览" : "无法预览此文件"
        icon.image = item.map { NSWorkspace.shared.icon(forFile: $0.url.path) }
        name.stringValue = item?.name ?? ""
        name.toolTip = item?.name
        detail.stringValue = [item?.kind, item?.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }].compactMap { $0 }.joined(separator: "  ·  ")
    }
}

/// The gutter belongs to the preview split, so hiding the sidebar reclaims it.
@MainActor
final class FilePreviewSplitView: NSSplitView {
    private let gutter: CGFloat = 14
    private let stroke: CGFloat = 2

    override var dividerThickness: CGFloat { gutter + stroke }

    override func drawDivider(in rect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        rect.fill()
        Palette.line.setFill()
        NSRect(x: rect.maxX - stroke, y: rect.minY, width: stroke, height: rect.height).fill()
    }
}
