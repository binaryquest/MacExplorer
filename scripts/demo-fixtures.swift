import AppKit
import CoreText

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let manager = FileManager.default
for path in ["Projects/Brand refresh", "Projects/Website launch", "Projects/Product catalog", "Projects/Research",
             "Documents", "Pictures", "Downloads", "Devices/Macintosh HD", "Devices/Studio SSD", "Devices/Archive",
             "Devices/Shared Projects", "Cloud/Google Drive/My Drive", "Cloud/Google Drive/Shared drives", "Cloud/OneDrive"] {
    try manager.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
}
for (path, text) in [
    ("Projects/Project roadmap.md", "# Studio roadmap\n\n- Gather ideas\n- Explore design directions\n- Build a prototype\n- Share the first release\n"),
    ("Projects/Release checklist.md", "# Release checklist\n\n- Review changes\n- Run tests\n- Update documentation\n"),
    ("Projects/Budget estimate.csv", "Category,Estimate\nDesign,2400\nDevelopment,6000\nTesting,1200\n"),
    ("Projects/Studio notes.txt", "All files in this workspace are fictional samples for MacExplorer screenshots.\n"),
    ("Projects/Brand refresh/Design notes.md", "# Design notes\n\nWarm colors, simple shapes, and clear typography.\n"),
    ("Projects/Website launch/Design review.md", "# Design review\n\nReview navigation, accessibility, and responsive layouts.\n"),
    ("Projects/Product catalog/Design inventory.csv", "Asset,Status\nProduct cards,Ready\nCategory icons,In review\n"),
    ("Documents/Welcome.md", "# Welcome to MacExplorer\n\nA native file browser with familiar Windows-style navigation.\n")
] { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }

let pdfURL = root.appendingPathComponent("Projects/Brand refresh/Design brief.pdf")
var page = CGRect(x: 0, y: 0, width: 595, height: 842)
let pdf = CGContext(pdfURL as CFURL, mediaBox: &page, nil)!
pdf.beginPDFPage(nil)
pdf.setFillColor(CGColor(gray: 0.97, alpha: 1)); pdf.fill(page)
for (text, y, size) in [("Studio / Design brief", 740.0, 28.0), ("A fictional sample project", 695.0, 16.0),
                        ("Clear navigation. Thoughtful details.", 640.0, 15.0), ("Built for everyday work.", 610.0, 15.0)] {
    pdf.textPosition = CGPoint(x: 55, y: y)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.darkGray]))
    CTLineDraw(line, pdf)
}
pdf.endPDFPage(); pdf.closePDF()

let palettes: [(String, NSColor, NSColor)] = [
    ("Coastal design", .systemTeal, .systemBlue), ("Sunset study", .systemOrange, .systemPink),
    ("Forest palette", .systemMint, .systemGreen), ("Lavender forms", .systemPurple, .systemIndigo)
]
for (name, first, second) in palettes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 960, pixelsHigh: 640, bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGradient(starting: first, ending: second)!.draw(in: NSRect(x: 0, y: 0, width: 960, height: 640), angle: -35)
    NSColor.white.withAlphaComponent(0.22).setFill()
    NSBezierPath(ovalIn: NSRect(x: 430, y: 100, width: 620, height: 620)).fill()
    NSColor.white.withAlphaComponent(0.16).setFill()
    NSBezierPath(roundedRect: NSRect(x: -60, y: -90, width: 760, height: 370), xRadius: 130, yRadius: 130).fill()
    name.draw(at: NSPoint(x: 55, y: 65), withAttributes: [.font: NSFont.systemFont(ofSize: 45, weight: .semibold), .foregroundColor: NSColor.white])
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Pictures/" + name + ".png"))
}
for (name, tag) in [("Brand refresh", "Orange\n7"), ("Website launch", "Blue\n4"), ("Product catalog", "Green\n2")] {
    var url = root.appendingPathComponent("Projects/" + name), values = URLResourceValues()
    values.tagNames = [tag]; try url.setResourceValues(values)
}
