// Renders the 1024x1024 master PNG for AppIcon.icns.
//
//   swift packaging/render-icon.swift packaging/AppIcon-1024.png
//
// A deep-blue tile holding a lit globe circled by an orbit ring, drawn with
// Core Graphics so it stays crisp and needs no external artwork. Re-run
// scripts/make-dmg.sh afterwards to rebuild AppIcon.icns.
import AppKit

let side = 1024
let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colors: colors as CFArray, locations: locations)!
}

guard let ctx = CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("could not allocate bitmap")
}

let canvas = CGRect(x: 0, y: 0, width: side, height: side)
let center = CGPoint(x: canvas.midX, y: canvas.midY)

// MARK: Tile — macOS grid: 824pt shape centred on the 1024 canvas.

let tile = canvas.insetBy(dx: 100, dy: 100)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185).cgPath

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x0B2E8A))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
ctx.drawLinearGradient(
    gradient([rgb(0x1F6BFF), rgb(0x1242C4), rgb(0x0A1F6E)], [0, 0.55, 1]),
    start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: []
)
// Soft glow behind the globe.
ctx.drawRadialGradient(
    gradient([rgb(0x6FD0FF, 0.45), rgb(0x6FD0FF, 0)], [0, 1]),
    startCenter: center, startRadius: 0, endCenter: center, endRadius: 420, options: []
)
// Hairline highlight along the top edge.
ctx.addPath(tilePath)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.18))
ctx.setLineWidth(4)
ctx.strokePath()
ctx.restoreGState()

// MARK: Orbit ring geometry

let radius: CGFloat = 250
let ringTilt: CGFloat = -0.38          // radians, rising to the right
let ringSize = CGSize(width: radius * 2.9, height: radius * 0.78)
let ringRect = CGRect(x: -ringSize.width / 2, y: -ringSize.height / 2,
                      width: ringSize.width, height: ringSize.height)
let ringWidth: CGFloat = 26

func strokeRing(frontOnly: Bool) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: ringTilt)
    if frontOnly {
        // The half nearer the viewer is the lower half in the ring's frame.
        ctx.clip(to: CGRect(x: -ringSize.width, y: -ringSize.height, width: ringSize.width * 2, height: ringSize.height))
    }
    ctx.addEllipse(in: ringRect)
    ctx.setLineWidth(ringWidth)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(0xFFB547), rgb(0xFF6A5C), rgb(0xFF4F9A)], [0, 0.5, 1]),
        start: CGPoint(x: ringRect.minX, y: 0), end: CGPoint(x: ringRect.maxX, y: 0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()
}

// Whole ring first; the globe then hides its far side.
strokeRing(frontOnly: false)

// MARK: Globe

let sphere = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0x020A2E, 0.55))
ctx.addEllipse(in: sphere)
ctx.setFillColor(rgb(0x1A5BE0))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addEllipse(in: sphere)
ctx.clip()

// Body: lit from the upper left.
let light = CGPoint(x: center.x - radius * 0.38, y: center.y + radius * 0.42)
ctx.drawRadialGradient(
    gradient([rgb(0xB8F0FF), rgb(0x45B6FF), rgb(0x1C63E6), rgb(0x0B2C9A)], [0, 0.3, 0.7, 1]),
    startCenter: light, startRadius: 0, endCenter: center, endRadius: radius * 1.05,
    options: [.drawsAfterEndLocation]
)

// Graticule.
ctx.setStrokeColor(rgb(0xFFFFFF, 0.42))
ctx.setLineWidth(9)
for fraction in [0.0, 0.5, 0.866] as [CGFloat] {   // meridians at 90°, 60°, 30° from the limb
    let w = radius * fraction
    ctx.strokeEllipse(in: CGRect(x: center.x - w, y: sphere.minY, width: w * 2, height: radius * 2))
}
for latitude in [-50.0, -22.0, 0.0, 22.0, 50.0] as [CGFloat] {
    let phi = latitude * .pi / 180
    let y = center.y + radius * sin(phi)
    let half = radius * cos(phi)
    // Parallels as shallow ellipses give the sphere some depth.
    let h = half * 0.16
    ctx.strokeEllipse(in: CGRect(x: center.x - half, y: y - h, width: half * 2, height: h * 2))
}

// Limb darkening.
ctx.drawRadialGradient(
    gradient([rgb(0x061A66, 0), rgb(0x061A66, 0), rgb(0x061A66, 0.55)], [0, 0.72, 1]),
    startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: []
)
// Specular highlight.
ctx.drawRadialGradient(
    gradient([rgb(0xFFFFFF, 0.75), rgb(0xFFFFFF, 0)], [0, 1]),
    startCenter: light, startRadius: 0, endCenter: light, endRadius: radius * 0.42, options: []
)
ctx.restoreGState()

// Crisp rim.
ctx.addEllipse(in: sphere.insetBy(dx: 2, dy: 2))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.28))
ctx.setLineWidth(4)
ctx.strokePath()

// MARK: Front half of the ring, over the globe

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x020A2E, 0.45))
strokeRing(frontOnly: true)
ctx.restoreGState()

// Satellite: a bright dot riding the front of the ring.
let t: CGFloat = -0.32 * .pi
let local = CGPoint(x: ringSize.width / 2 * cos(t), y: ringSize.height / 2 * sin(t))
let dot = CGPoint(
    x: center.x + local.x * cos(ringTilt) - local.y * sin(ringTilt),
    y: center.y + local.x * sin(ringTilt) + local.y * cos(ringTilt)
)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 30, color: rgb(0xFFE3A8, 0.9))
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillEllipse(in: CGRect(x: dot.x - 26, y: dot.y - 26, width: 52, height: 52))
ctx.restoreGState()

// MARK: Write

guard let image = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
