import AppKit

/// Native text editing inside a Windows-style search surface.
@MainActor
final class SearchBox: Surface, NSTextFieldDelegate {
    let field = NSTextField()
    private(set) var clearButton: ActionButton!
    private(set) var searchButton: ActionButton!
    var onChange: (() -> Void)?
    var onSubmit: (() -> Void)?
    var onClear: (() -> Void)?
    private var editing = false
    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue; updateClearButton() }
    }
    var placeholderString: String? {
        get { field.placeholderString }
        set { field.placeholderString = newValue; field.setAccessibilityLabel(newValue) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 12); field.delegate = self
        field.cell?.usesSingleLineMode = true; field.cell?.isScrollable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        clearButton = ActionButton(symbol: "xmark", tooltip: "Clear search") { [weak self] in
            self?.onClear?(); self?.focus()
        }
        searchButton = ActionButton(symbol: "magnifyingglass", tooltip: "Search") { [weak self] in self?.onSubmit?() }
        clearButton.image = Palette.buttonSymbol("xmark", size: 10)
        searchButton.image = Palette.buttonSymbol("magnifyingglass", size: 12)
        for child in [field, clearButton!, searchButton!] {
            addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            searchButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            searchButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: searchButton.leadingAnchor),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateClearButton()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func focus() { window?.makeFirstResponder(field); field.selectText(nil) }
    private func updateClearButton() { clearButton.isHidden = stringValue.isEmpty }
    func controlTextDidBeginEditing(_ obj: Notification) { editing = true; needsDisplay = true }
    func controlTextDidEndEditing(_ obj: Notification) { editing = false; needsDisplay = true }
    func controlTextDidChange(_ obj: Notification) { updateClearButton(); onChange?() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onClear?(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { onSubmit?(); return true }
        return false
    }
    override func mouseDown(with event: NSEvent) { focus() }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.setFill(); shape.fill()
        Palette.line.setStroke(); shape.lineWidth = 0.5; shape.stroke()
        if editing {
            NSGraphicsContext.saveGraphicsState(); shape.addClip()
            NSColor.systemBlue.setFill(); NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
