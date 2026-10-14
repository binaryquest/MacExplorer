import AppKit

@MainActor
final class AboutWindowController: NSWindowController {
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 430),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About Explorer"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        guard let content = window.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
        ])

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel("Explorer app icon")
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 80), icon.heightAnchor.constraint(equalToConstant: 80)])
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label("Explorer", size: 27, weight: .semibold))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        stack.addArrangedSubview(label("Version \(version)" + (build.map { " (\($0))" } ?? ""), size: 12, secondary: true))
        let description = label("A native Mac file manager inspired by Windows Explorer.\nFamiliar navigation. Made for your Mac.", size: 14)
        description.maximumNumberOfLines = 0
        description.preferredMaxLayoutWidth = 370
        stack.addArrangedSubview(description)
        stack.setCustomSpacing(20, after: description)

        let publisher = NSButton(title: "Developed by Binary Quest ↗", target: self, action: #selector(openPublisher))
        publisher.bezelStyle = .inline
        publisher.font = .systemFont(ofSize: 13, weight: .medium)
        publisher.toolTip = "www.binaryquest.com"
        stack.addArrangedSubview(publisher)
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        for (title, action) in [("Website", #selector(openWebsite)), ("Source Code", #selector(openSource))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            buttons.addArrangedSubview(button)
        }
        stack.addArrangedSubview(buttons)
        stack.setCustomSpacing(20, after: buttons)
        stack.addArrangedSubview(label("Free and open source · MIT license", size: 11, secondary: true))
        stack.addArrangedSubview(label("© Binary Quest Software Pty Ltd", size: 11, secondary: true))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.alignment = .center
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.isSelectable = true
        return field
    }

    @objc private func openWebsite() { open("https://explorer.bquick.io") }
    @objc private func openSource() { open("https://github.com/binaryquest/MacExplorer") }
    @objc private func openPublisher() { open("https://www.binaryquest.com") }
    private func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}
