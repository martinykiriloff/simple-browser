// Renders the 1024x1024 master PNG for AppIcon.icns.
//
//   swift packaging/render-icon.swift packaging/AppIcon-1024.png
//
// A night-sky tile holding a glowing portal ring, its colours sweeping from
// cyan through violet and pink to amber, with a compass needle at its heart
// pointing the way. Drawn with Core Graphics so it stays crisp at every size
// and needs no external artwork. Re-run scripts/make-dmg.sh afterwards to
// rebuild AppIcon.icns, and `swift build` to refresh the copy the app shows
// in the Dock when run from the build folder.
import AppKit

let side = 1024
let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: locations)!
}

/// Linear interpolation through a list of colour stops, for the ring's sweep.
func sweep(_ t: CGFloat, _ stops: [(CGFloat, UInt32)]) -> CGColor {
    let t = t - floor(t)
    for (a, b) in zip(stops, stops.dropFirst()) where t >= a.0 && t <= b.0 {
        let f = (t - a.0) / (b.0 - a.0)
        func channel(_ hex: UInt32, _ shift: UInt32) -> CGFloat { CGFloat((hex >> shift) & 0xFF) / 255 }
        return CGColor(srgbRed: channel(a.1, 16) + (channel(b.1, 16) - channel(a.1, 16)) * f,
                       green: channel(a.1, 8) + (channel(b.1, 8) - channel(a.1, 8)) * f,
                       blue: channel(a.1, 0) + (channel(b.1, 0) - channel(a.1, 0)) * f, alpha: 1)
    }
    return rgb(stops[0].1)
}

guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("could not allocate bitmap")
}

let canvas = CGRect(x: 0, y: 0, width: side, height: side)
let center = CGPoint(x: canvas.midX, y: canvas.midY)

// MARK: Tile — the macOS grid: an 824pt shape centred on the 1024 canvas.

let tile = canvas.insetBy(dx: 100, dy: 100)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185).cgPath

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(0x000000, 0.45))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x070A1F))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
// Night sky: indigo at the top, near-black at the bottom.
ctx.drawLinearGradient(gradient([rgb(0x1B1F5E), rgb(0x0C0F33), rgb(0x04050F)], [0, 0.5, 1]),
                       start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])
// Nebula haze, violet low left and teal high right.
ctx.drawRadialGradient(gradient([rgb(0x7C3AED, 0.45), rgb(0x7C3AED, 0)], [0, 1]),
                       startCenter: CGPoint(x: tile.minX + 180, y: tile.minY + 200), startRadius: 0,
                       endCenter: CGPoint(x: tile.minX + 180, y: tile.minY + 200), endRadius: 460, options: [])
ctx.drawRadialGradient(gradient([rgb(0x06B6D4, 0.30), rgb(0x06B6D4, 0)], [0, 1]),
                       startCenter: CGPoint(x: tile.maxX - 150, y: tile.maxY - 170), startRadius: 0,
                       endCenter: CGPoint(x: tile.maxX - 150, y: tile.maxY - 170), endRadius: 420, options: [])

// Stars: a fixed seed, so every render is the same sky.
var seed: UInt64 = 0x5EB_B0C5
func random() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat((seed >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
}
for _ in 0..<70 {
    let point = CGPoint(x: tile.minX + random() * tile.width, y: tile.minY + random() * tile.height)
    // None inside the portal: it should read as a window onto somewhere else.
    if hypot(point.x - center.x, point.y - center.y) < 300 { _ = random(); _ = random(); continue }
    let size = 1.5 + random() * 4
    ctx.setFillColor(rgb(0xFFFFFF, 0.25 + random() * 0.6))
    ctx.fillEllipse(in: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
}
ctx.restoreGState()

// MARK: Portal ring

let ringRadius: CGFloat = 268
let ringWidth: CGFloat = 64
let stops: [(CGFloat, UInt32)] = [(0, 0x22D3EE), (0.22, 0x6366F1), (0.45, 0xA855F7), (0.66, 0xEC4899), (0.84, 0xF59E0B), (1, 0x22D3EE)]

func drawRing(width: CGFloat, alpha: CGFloat) {
    // A conic sweep, as 720 thin wedges clipped to the annulus.
    ctx.saveGState()
    let annulus = CGMutablePath()
    annulus.addEllipse(in: CGRect(x: center.x - ringRadius - width / 2, y: center.y - ringRadius - width / 2,
                                  width: (ringRadius + width / 2) * 2, height: (ringRadius + width / 2) * 2))
    annulus.addEllipse(in: CGRect(x: center.x - ringRadius + width / 2, y: center.y - ringRadius + width / 2,
                                  width: (ringRadius - width / 2) * 2, height: (ringRadius - width / 2) * 2))
    ctx.addPath(annulus)
    ctx.clip(using: .evenOdd)
    ctx.setAlpha(alpha)
    let steps = 720
    for i in 0..<steps {
        let a0 = CGFloat(i) / CGFloat(steps) * 2 * .pi + .pi / 2
        let a1 = CGFloat(i + 1) / CGFloat(steps) * 2 * .pi + .pi / 2 + 0.01
        let wedge = CGMutablePath()
        wedge.move(to: center)
        wedge.addArc(center: center, radius: ringRadius + width, startAngle: a0, endAngle: a1, clockwise: false)
        wedge.closeSubpath()
        ctx.addPath(wedge)
        ctx.setFillColor(sweep(CGFloat(i) / CGFloat(steps), stops))
        ctx.fillPath()
    }
    ctx.restoreGState()
}

// Glow: the ring drawn wide and faint, blurred by a shadow of itself.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 70, color: rgb(0x8B5CF6, 0.9))
drawRing(width: ringWidth + 30, alpha: 0.35)
ctx.restoreGState()
drawRing(width: ringWidth, alpha: 1)

// Glass on the ring: a bright inner edge on the top half.
ctx.saveGState()
ctx.setBlendMode(.screen)
ctx.addArc(center: center, radius: ringRadius - ringWidth / 2 + 6, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: false)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.55))
ctx.setLineWidth(5)
ctx.setLineCap(.round)
ctx.strokePath()
ctx.restoreGState()

// Inside the portal: a deeper glow, as if lit from beyond.
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - ringRadius + ringWidth / 2, y: center.y - ringRadius + ringWidth / 2,
                          width: (ringRadius - ringWidth / 2) * 2, height: (ringRadius - ringWidth / 2) * 2))
ctx.clip()
ctx.drawRadialGradient(gradient([rgb(0x312E81, 0.95), rgb(0x1E1B4B, 0.9), rgb(0x0B0B26, 0.95)], [0, 0.6, 1]),
                       startCenter: CGPoint(x: center.x, y: center.y + 40), startRadius: 0,
                       endCenter: center, endRadius: ringRadius, options: [])
ctx.drawRadialGradient(gradient([rgb(0x67E8F9, 0.35), rgb(0x67E8F9, 0)], [0, 1]),
                       startCenter: center, startRadius: 0, endCenter: center, endRadius: 190, options: [])
ctx.restoreGState()

// MARK: Compass needle

let needleLength: CGFloat = 225
let needleWidth: CGFloat = 78
let heading: CGFloat = .pi / 4          // north-east: onward

func needleHalf(north: Bool) -> CGPath {
    let path = CGMutablePath()
    let sign: CGFloat = north ? 1 : -1
    path.move(to: CGPoint(x: 0, y: sign * needleLength))
    path.addLine(to: CGPoint(x: needleWidth / 2, y: 0))
    path.addLine(to: CGPoint(x: -needleWidth / 2, y: 0))
    path.closeSubpath()
    return path
}

ctx.saveGState()
ctx.translateBy(x: center.x, y: center.y)
ctx.rotate(by: -heading)

// Shadow under the whole needle.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 26, color: rgb(0x000000, 0.6))
ctx.addPath(needleHalf(north: true))
ctx.addPath(needleHalf(north: false))
ctx.setFillColor(rgb(0x000000, 1))
ctx.fillPath()
ctx.restoreGState()

for north in [true, false] {
    let half = needleHalf(north: north)
    // Left and right facets, shaded differently, so the needle reads as a
    // ridged blade rather than a flat shape.
    for side in [CGFloat(-1), 1] {
        let facet = CGMutablePath()
        let tip = CGPoint(x: 0, y: (north ? 1 : -1) * needleLength)
        facet.move(to: tip)
        facet.addLine(to: CGPoint(x: side * needleWidth / 2, y: 0))
        facet.addLine(to: .zero)
        facet.closeSubpath()
        ctx.saveGState()
        ctx.addPath(facet)
        ctx.clip()
        let colors: [CGColor]
        if north {
            colors = side < 0 ? [rgb(0xFFFFFF), rgb(0xCFFAFE)] : [rgb(0xE0F2FE), rgb(0x7DD3FC)]
        } else {
            colors = side < 0 ? [rgb(0xF472B6), rgb(0xBE185D)] : [rgb(0xDB2777), rgb(0x831843)]
        }
        ctx.drawLinearGradient(gradient(colors, [0, 1]), start: tip, end: .zero, options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }
    ctx.addPath(half)
    ctx.setStrokeColor(rgb(0xFFFFFF, north ? 0.5 : 0.25))
    ctx.setLineWidth(2)
    ctx.strokePath()
}
ctx.restoreGState()

// Hub.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 8, color: rgb(0x000000, 0.5))
let hub = CGRect(x: center.x - 20, y: center.y - 20, width: 40, height: 40)
ctx.addEllipse(in: hub)
ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF), rgb(0xA5B4FC)], [0, 1]),
                       start: CGPoint(x: hub.midX, y: hub.maxY), end: CGPoint(x: hub.midX, y: hub.minY), options: [])
ctx.restoreGState()

// MARK: Spark on the ring, where the needle points

let sparkAngle = CGFloat.pi / 2 - heading
let spark = CGPoint(x: center.x + cos(sparkAngle) * ringRadius, y: center.y + sin(sparkAngle) * ringRadius)
ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 1), rgb(0xFDE68A, 0.7), rgb(0xFDE68A, 0)], [0, 0.25, 1]),
                       startCenter: spark, startRadius: 0, endCenter: spark, endRadius: 70, options: [])
ctx.saveGState()
ctx.setFillColor(rgb(0xFFFFFF))
for angle in [CGFloat(0), .pi / 2] {
    // A four-point twinkle.
    ctx.saveGState()
    ctx.translateBy(x: spark.x, y: spark.y)
    ctx.rotate(by: angle + .pi / 4)
    ctx.fillEllipse(in: CGRect(x: -46, y: -3, width: 92, height: 6))
    ctx.restoreGState()
}
ctx.restoreGState()

// MARK: Sheen across the top of the tile

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)], [0, 1]),
                       start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.midY + 80), options: [])
ctx.addPath(tilePath)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
ctx.setLineWidth(4)
ctx.strokePath()
ctx.restoreGState()

guard let image = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
