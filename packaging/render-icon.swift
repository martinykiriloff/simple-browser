// Renders the 1024x1024 master PNG for AppIcon.icns.
//
//   swift packaging/render-icon.swift packaging/AppIcon-1024.png
//
// Glass brackets: a pair of frosted-glass angle brackets on deep teal,
// holding a small amber sun. The web, as source; the sun shows through the
// glass, blurred, the way a layered macOS icon reads. Drawn with Core
// Graphics and Core Image so it stays crisp at every size and needs no
// external artwork. Re-run scripts/make-dmg.sh afterwards to rebuild
// AppIcon.icns, and copy a 512px version to Sources/BrowserApp/AppIcon for
// the Dock icon of a build run from the build folder:
//
//   sips -z 512 512 packaging/AppIcon-1024.png --out Sources/BrowserApp/AppIcon/AppIcon.png
import AppKit
import CoreImage

let side: CGFloat = 1024
let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

func linear(_ ctx: CGContext, _ g: CGGradient, from: CGPoint, to: CGPoint) {
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

guard let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("could not allocate bitmap")
}

// MARK: Tile — the macOS grid: an 824pt shape centred on the 1024 canvas.

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
let center = CGPoint(x: 512, y: 512)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 26, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x06171D))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

// Deep teal, lighter at the top, as the system lighting expects.
linear(ctx, gradient([rgb(0x10404D), rgb(0x06171D)]), from: CGPoint(x: 0, y: tile.maxY), to: CGPoint(x: 0, y: tile.minY))

// The sun: a warm halo and a solid disc.
ctx.drawRadialGradient(gradient([rgb(0xFFD27A, 0.9), rgb(0xF59E0B, 0.35), rgb(0xF59E0B, 0)], [0, 0.45, 1]),
                       startCenter: center, startRadius: 0, endCenter: center, endRadius: 150, options: [])
ctx.setFillColor(rgb(0xFFB547))
ctx.fillEllipse(in: CGRect(x: center.x - 60, y: center.y - 60, width: 120, height: 120))

// MARK: Glass brackets

/// A bracket as one closed outline with no overlaps, so its rim follows only the outside edge.
func bracket(_ points: [CGPoint]) -> CGPath {
    let line = CGMutablePath()
    line.addLines(between: points)
    return line.copy(strokingWithWidth: 112, lineCap: .round, lineJoin: .round, miterLimit: 10).normalized()
}

let ci = CIContext(options: [.workingColorSpace: space])
func blurred(_ image: CGImage, sigma: CGFloat) -> CGImage {
    let input = CIImage(cgImage: image)
    let output = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
    return ci.createCGImage(output, from: output.extent)!
}

/// Frosted glass: what lies beneath, blurred and lifted, with a soft shadow and a lit rim.
func glass(_ path: CGPath) {
    let beneath = blurred(ctx.makeImage()!, sigma: 26)
    let box = path.boundingBox
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0x000000, 0.30))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0xFFFFFF, 0.01))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.draw(beneath, in: CGRect(x: 0, y: 0, width: side, height: side))
    ctx.setFillColor(rgb(0xFFFFFF, 0.34))
    ctx.fill(box)
    linear(ctx, gradient([rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)]), from: CGPoint(x: box.minX, y: box.maxY), to: CGPoint(x: box.midX, y: box.midY))
    ctx.restoreGState()

    // Rim: brightest where the light falls, top left.
    ctx.saveGState()
    ctx.addPath(path.copy(strokingWithWidth: 7, lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.clip()
    linear(ctx, gradient([rgb(0xFFFFFF, 0.95), rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0.5)]),
           from: CGPoint(x: box.minX, y: box.maxY), to: CGPoint(x: box.maxX, y: box.minY))
    ctx.restoreGState()
}

glass(bracket([CGPoint(x: 370, y: 730), CGPoint(x: 210, y: 512), CGPoint(x: 370, y: 294)]))
glass(bracket([CGPoint(x: 654, y: 730), CGPoint(x: 814, y: 512), CGPoint(x: 654, y: 294)]))
ctx.restoreGState()

// MARK: The tile's own rim, lighter at the top

ctx.saveGState()
ctx.addPath(tilePath.copy(strokingWithWidth: 6, lineCap: .round, lineJoin: .round, miterLimit: 10))
ctx.clip()
linear(ctx, gradient([rgb(0xFFFFFF, 0.32), rgb(0xFFFFFF, 0.04)]), from: CGPoint(x: 0, y: tile.maxY), to: CGPoint(x: 0, y: tile.minY))
ctx.restoreGState()

guard let image = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
