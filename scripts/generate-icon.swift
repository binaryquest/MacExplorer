import AppKit

let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func drawIcon(pixels: Int, file: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }
    let background = NSBezierPath(roundedRect: NSRect(x: 58, y: 58, width: 908, height: 908), xRadius: 204, yRadius: 204)
    NSGradient(starting: color(0.99, 0.995, 1), ending: color(0.86, 0.90, 0.94))!.draw(in: background, angle: -90)
    NSColor.white.withAlphaComponent(0.85).setStroke(); background.lineWidth = 3; background.stroke()

    // A familiar golden folder, with an original blue insert and clasp.
    let back = NSBezierPath()
    back.move(to: NSPoint(x: 175, y: 292))
    back.line(to: NSPoint(x: 175, y: 718))
    back.curve(to: NSPoint(x: 219, y: 762), controlPoint1: NSPoint(x: 175, y: 750), controlPoint2: NSPoint(x: 187, y: 762))
    back.line(to: NSPoint(x: 410, y: 762))
    back.curve(to: NSPoint(x: 463, y: 738), controlPoint1: NSPoint(x: 440, y: 762), controlPoint2: NSPoint(x: 447, y: 754))
    back.line(to: NSPoint(x: 508, y: 691)); back.line(to: NSPoint(x: 802, y: 691))
    back.curve(to: NSPoint(x: 848, y: 645), controlPoint1: NSPoint(x: 834, y: 691), controlPoint2: NSPoint(x: 848, y: 677))
    back.line(to: NSPoint(x: 848, y: 292)); back.close()
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
    shadow.shadowOffset = NSSize(width: 0, height: -16); shadow.shadowBlurRadius = 24; shadow.set()
    color(0.94, 0.57, 0.07).setFill(); back.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(1, 0.78, 0.21), ending: color(0.92, 0.56, 0.06))!.draw(in: back, angle: -90)

    let insert = NSBezierPath(roundedRect: NSRect(x: 223, y: 471, width: 577, height: 183), xRadius: 20, yRadius: 20)
    NSGradient(starting: color(0.39, 0.79, 1), ending: color(0.10, 0.48, 0.90))!.draw(in: insert, angle: -90)
    NSColor.white.withAlphaComponent(0.62).setFill()
    NSBezierPath(roundedRect: NSRect(x: 238, y: 624, width: 546, height: 8), xRadius: 4, yRadius: 4).fill()

    let front = NSBezierPath(roundedRect: NSRect(x: 141, y: 245, width: 742, height: 350), xRadius: 48, yRadius: 48)
    NSGraphicsContext.saveGraphicsState()
    let lipShadow = NSShadow(); lipShadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
    lipShadow.shadowOffset = NSSize(width: 0, height: -9); lipShadow.shadowBlurRadius = 14; lipShadow.set()
    color(1, 0.72, 0.09).setFill(); front.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(1, 0.88, 0.35), ending: color(1, 0.67, 0.04))!.draw(in: front, angle: -90)
    NSColor.white.withAlphaComponent(0.34).setStroke(); front.lineWidth = 3; front.stroke()
    let clasp = NSBezierPath(roundedRect: NSRect(x: 592, y: 288, width: 184, height: 37), xRadius: 12, yRadius: 12)
    NSGradient(starting: color(0.19, 0.63, 0.96), ending: color(0.07, 0.39, 0.78))!.draw(in: clasp, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(file))
}

for size in [16, 32, 128, 256, 512] {
    try drawIcon(pixels: size, file: "icon_\(size)x\(size).png")
    try drawIcon(pixels: size * 2, file: "icon_\(size)x\(size)@2x.png")
}

// Modern ICNS stores PNG payloads in typed, big-endian records.
func uint32(_ value: Int) -> Data {
    var value = UInt32(value).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
var records = Data()
for (type, name) in [("icp4", "16x16"), ("icp5", "32x32"), ("ic07", "128x128"),
                     ("ic08", "256x256"), ("ic09", "512x512"), ("ic10", "512x512@2x"),
                     ("ic11", "16x16@2x"), ("ic12", "32x32@2x"), ("ic13", "128x128@2x"), ("ic14", "256x256@2x")] {
    let payload = try Data(contentsOf: URL(fileURLWithPath: output).appendingPathComponent("icon_\(name).png"))
    records.append(Data(type.utf8)); records.append(uint32(payload.count + 8)); records.append(payload)
}
var container = Data("icns".utf8); container.append(uint32(records.count + 8)); container.append(records)
try container.write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("icns"))
