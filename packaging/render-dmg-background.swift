// Renders the background of the disk image's window: the app on the left,
// the Applications folder on the right, an arrow between them, and one
// line saying what to do. Positions match scripts/make-dmg.sh.
//
//   swift packaging/render-dmg-background.swift packaging/dmg-background.png packaging/dmg-background@2x.png
import AppKit

let size = NSSize(width: 660, height: 400)
let outputs = Array(CommandLine.arguments.dropFirst())

func render(scale: CGFloat) -> Data? {
    let pixels = NSSize(width: size.width * scale, height: size.height * scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bounds = NSRect(origin: .zero, size: size)

    // A soft light wash, with the icon's teal and amber kept for the corner glow.
    NSGradient(colors: [NSColor(srgbRed: 0.97, green: 0.98, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.90, green: 0.94, blue: 0.94, alpha: 1)])?
        .draw(in: bounds, angle: -90)
    NSGradient(colors: [NSColor(srgbRed: 0.96, green: 0.62, blue: 0.04, alpha: 0.10), .clear])?
        .draw(fromCenter: NSPoint(x: 600, y: 360), radius: 0, toCenter: NSPoint(x: 600, y: 360), radius: 320, options: [])

    // The arrow, between the two icons (Finder's y runs down; here it runs up).
    let y = size.height - 190
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 260, y: y))
    arrow.curve(to: NSPoint(x: 392, y: y), controlPoint1: NSPoint(x: 300, y: y + 26), controlPoint2: NSPoint(x: 352, y: y + 26))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    let ink = NSColor(srgbRed: 0.06, green: 0.36, blue: 0.42, alpha: 0.9)
    ink.setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 376, y: y + 16))
    head.line(to: NSPoint(x: 396, y: y - 1))
    head.line(to: NSPoint(x: 372, y: y - 8))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // What to do, in one line.
    let caption = NSAttributedString(string: "Drag SimpleBrowser to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 17, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.25, green: 0.25, blue: 0.32, alpha: 1),
    ])
    let captionSize = caption.size()
    caption.draw(at: NSPoint(x: (size.width - captionSize.width) / 2, y: 58))
    let note = NSAttributedString(string: "Then open it from your Applications folder.", attributes: [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: NSColor(srgbRed: 0.40, green: 0.40, blue: 0.47, alpha: 1),
    ])
    note.draw(at: NSPoint(x: (size.width - note.size().width) / 2, y: 36))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for (index, path) in outputs.enumerated() {
    guard let data = render(scale: CGFloat(index + 1)) else { fatalError("could not render") }
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
