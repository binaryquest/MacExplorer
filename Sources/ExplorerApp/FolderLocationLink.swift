import AppKit

@MainActor
final class FolderLocationLink: NSTextField {
    private var openFolder: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var pressPoint: NSPoint?
    private var normalValue = NSAttributedString(string: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
        lineBreakMode = .byTruncatingMiddle
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ text: String, query: String, file: URL, onOpen: (() -> Void)?) {
        openFolder = onOpen; pressPoint = nil
        SearchHighlight.apply(text, to: self, query: query, color: onOpen == nil ? .secondaryLabelColor : .linkColor)
        normalValue = attributedStringValue
        toolTip = "\(file.deletingLastPathComponent().path)\nOpen containing folder and select \(file.lastPathComponent)"
        setAccessibilityElement(true)
        setAccessibilityRole(onOpen == nil ? .staticText : .link)
        setAccessibilityLabel(onOpen == nil ? text : "Open containing folder for \(file.lastPathComponent)")
        setAccessibilityValue(text)
        setAccessibilityHelp(onOpen == nil ? nil : "Opens this folder in the current pane and selects \(file.lastPathComponent).")
        window?.invalidateCursorRects(for: self)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if openFolder != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        guard openFolder != nil else { return }
        let value = NSMutableAttributedString(attributedString: normalValue)
        value.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: value.length))
        attributedStringValue = value
    }
    override func mouseExited(with event: NSEvent) { attributedStringValue = normalValue }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard openFolder != nil, !isHidden, bounds.contains(convert(point, from: superview)) else { return super.hitTest(point) }
        return self
    }
    override func mouseDown(with event: NSEvent) { pressPoint = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        if let start = pressPoint, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 { pressPoint = nil }
    }
    override func mouseUp(with event: NSEvent) {
        let pressed = pressPoint != nil; pressPoint = nil
        if pressed, event.clickCount == 1, bounds.contains(convert(event.locationInWindow, from: nil)) { openFolder?() }
    }
    override func accessibilityPerformPress() -> Bool {
        guard let openFolder else { return false }; openFolder(); return true
    }
}
