// Draws the SiriAsk app icon as a 1024×1024 PNG.
// Usage: swift Tools/make_icon.swift <output.png>
// (build_icon.sh turns the PNG into Resources/AppIcon.icns.)
//
// Design: a 3D Earth floating in deep space — oceans, terrain-shaded continents (shapes from the
// system "globe.americas.fill" symbol), curling clouds, a night-side terminator, sun glint on the
// sea and a glowing blue atmosphere, on a starry tile.
import AppKit
import CoreImage

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext() -> CGContext {
    CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}
func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: stops.map { $0.0 } as CFArray, locations: stops.map { $0.1 })!
}
/// Gaussian-blurs a full-canvas image (used for soft glows and the colour swirl).
func blurred(_ image: CGImage, _ radius: CGFloat) -> CGImage {
    let ci = CIImage(cgImage: image).clampedToExtent()
        .applyingGaussianBlur(sigma: radius)
        .cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
    return CIContext().createCGImage(ci, from: CGRect(x: 0, y: 0, width: S, height: S))!
}

// Siri palette (matches siriColors in SiriPanel.swift).
let cyan   = rgb(0.25, 0.82, 1.00)
let blue   = rgb(0.30, 0.42, 1.00)
let violet = rgb(0.71, 0.36, 1.00)
let pink   = rgb(1.00, 0.31, 0.63)
let orange = rgb(1.00, 0.64, 0.23)

// MARK: Tile — Apple-style continuous-corner squircle on the macOS 824 pt grid.

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2, c = CGPoint(x: r.midX, y: r.midY)
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = c.x + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = c.y + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}
let tile = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)   // macOS icon template radius

let ctx = makeContext()

// Soft drop shadow under the tile (as macOS draws for its own icons).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.45))
ctx.addPath(tile)
ctx.setFillColor(rgb(0.05, 0.04, 0.09))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tile)
ctx.clip()

// Deep space background, a touch lighter at the top.
ctx.drawLinearGradient(gradient([(rgb(0.15, 0.13, 0.24), 0), (rgb(0.06, 0.05, 0.11), 0.55), (rgb(0.03, 0.03, 0.06), 1)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// MARK: Earth geometry

let orbC = CGPoint(x: 512, y: 512)
let orbR: CGFloat = 290
let orbRect = CGRect(x: orbC.x - orbR, y: orbC.y - orbR, width: orbR * 2, height: orbR * 2)
let orbPath = CGPath(ellipseIn: orbRect, transform: nil)
let full = CGRect(x: 0, y: 0, width: S, height: S)

// Starfield: a few faint stars in deep space.
do {
    var seed: UInt64 = 7
    func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
    for _ in 0..<70 {
        let p = CGPoint(x: 100 + rnd() * 824, y: 100 + rnd() * 824)
        if hypot(p.x - orbC.x, p.y - orbC.y) < orbR + 40 { continue }
        let r = 1.2 + rnd() * 2.6
        ctx.setFillColor(rgb(1, 1, 1, 0.25 + rnd() * 0.5))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }
}

// Atmosphere glow around the planet.
do {
    let g = makeContext()
    g.setFillColor(rgb(0.30, 0.65, 1.0, 0.9))
    g.fillEllipse(in: orbRect.insetBy(dx: -6, dy: -6))
    ctx.saveGState()
    ctx.setBlendMode(.plusLighter)
    ctx.setAlpha(0.75)
    ctx.draw(blurred(g.makeImage()!, 34), in: full)
    ctx.restoreGState()
}

// Continent mask from the system "globe.americas.fill" symbol: the land shapes sit inside a ring;
// drawing the symbol slightly oversized and clipping to the planet leaves only the land.
func landMask() -> CGImage {
    let gray = CGColorSpaceCreateDeviceGray()
    let m = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                      space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    m.setFillColor(gray: 0, alpha: 1)
    m.fill(full)
    m.addPath(orbPath)
    m.clip()
    let cfg = NSImage.SymbolConfiguration(pointSize: 600, weight: .regular)
    let sym = NSImage(systemSymbolName: "globe.americas.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(cfg)!
    // In the symbol, the inner (ocean) circle is ~73% of its drawing rect; scale so it just exceeds the planet.
    let side = orbR * 2 / 0.725
    // Render the symbol white on transparent (symbols draw black; tint over the drawn pixels only).
    let white = NSImage(size: NSSize(width: side, height: side))
    white.lockFocus()
    sym.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSColor.white.set()
    NSRect(x: 0, y: 0, width: side, height: side).fill(using: .sourceAtop)
    white.unlockFocus()
    var r = NSRect(x: 0, y: 0, width: side, height: side)
    let cg = white.cgImage(forProposedRect: &r, context: nil, hints: nil)!
    m.draw(cg, in: CGRect(x: orbC.x - side / 2, y: orbC.y - side / 2, width: side, height: side))
    return m.makeImage()!
}
let land = landMask()
if let dbg = ProcessInfo.processInfo.environment["MASK_OUT"] {
    try! NSBitmapImageRep(cgImage: land).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dbg))
}

ctx.saveGState()
ctx.addPath(orbPath)
ctx.clip()

// Ocean: luminous blue, deeper towards the far side.
ctx.drawRadialGradient(gradient([(rgb(0.22, 0.62, 1.0), 0), (rgb(0.06, 0.36, 0.86), 0.5), (rgb(0.02, 0.14, 0.45), 1)]),
                       startCenter: CGPoint(x: orbC.x - 90, y: orbC.y + 110), startRadius: 0,
                       endCenter: orbC, endRadius: orbR * 1.05, options: [.drawsAfterEndLocation])

// Land: lush green, lit from the top-left, with a soft coastline shadow for relief.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 3, height: -4), blur: 8, color: rgb(0, 0.05, 0.15, 0.6))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.clip(to: full, mask: land)
ctx.drawLinearGradient(gradient([(rgb(0.55, 0.85, 0.40), 0), (rgb(0.22, 0.66, 0.30), 0.45), (rgb(0.10, 0.42, 0.22), 0.8), (rgb(0.55, 0.45, 0.28), 1)]),
                       start: CGPoint(x: orbC.x - 200, y: orbRect.maxY), end: CGPoint(x: orbC.x + 120, y: orbRect.minY), options: [])
// Terrain: blurred patches of deep forest, dry plains and highlands so the land isn't one flat green.
do {
    let t = makeContext()
    var seed: UInt64 = 42
    func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
    let tones = [rgb(0.05, 0.30, 0.16, 0.8), rgb(0.70, 0.62, 0.38, 0.6), rgb(0.40, 0.75, 0.35, 0.6), rgb(0.08, 0.36, 0.20, 0.7)]
    for i in 0..<60 {
        let p = CGPoint(x: orbRect.minX + rnd() * orbR * 2, y: orbRect.minY + rnd() * orbR * 2)
        let r = 18 + rnd() * 46
        t.setFillColor(tones[i % tones.count])
        t.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r * 0.7, width: r * 2, height: r * 1.4))
    }
    ctx.draw(blurred(t.makeImage()!, 14), in: full)
}
// Snow on the northern reaches.
ctx.drawLinearGradient(gradient([(rgb(0.95, 0.98, 1, 0.6), 0), (rgb(0.95, 0.98, 1, 0.15), 0.5), (rgb(0.95, 0.98, 1, 0), 1)]),
                       start: CGPoint(x: 512, y: orbRect.maxY - 10), end: CGPoint(x: 512, y: orbRect.maxY - 150), options: [])
ctx.endTransparencyLayer()
ctx.restoreGState()

// Clouds: curling bands of small puffs, like weather systems seen from orbit.
do {
    let g = makeContext()
    var seed: UInt64 = 11
    func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
    /// A band of puffs along a circular arc (centre, radius, start/end angle in degrees).
    func band(_ c: CGPoint, _ radius: CGFloat, _ a0: CGFloat, _ a1: CGFloat, _ size: CGFloat, _ alpha: CGFloat) {
        let n = Int(abs(a1 - a0) / 4)
        for i in 0...n {
            let a = (a0 + (a1 - a0) * CGFloat(i) / CGFloat(n)) * .pi / 180
            let taper = sin(CGFloat(i) / CGFloat(n) * .pi)          // thin at both ends
            let r = size * (0.35 + 0.65 * taper) * (0.7 + rnd() * 0.6)
            let p = CGPoint(x: c.x + cos(a) * radius + (rnd() - 0.5) * size,
                            y: c.y + sin(a) * radius + (rnd() - 0.5) * size)
            g.setFillColor(rgb(1, 1, 1, alpha * (0.6 + rnd() * 0.4)))
            g.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
    }
    band(CGPoint(x: 420, y: 560), 200, 70, 140, 34, 0.7)      // northern arc over the Pacific
    band(CGPoint(x: 660, y: 640), 110, 140, 300, 26, 0.65)    // swirl over the Atlantic
    band(CGPoint(x: 520, y: 470), 250, 205, 245, 30, 0.6)     // southern band
    band(CGPoint(x: 560, y: 900), 640, 258, 282, 24, 0.55)    // equatorial wisp
    ctx.saveGState()
    ctx.setAlpha(0.6)
    ctx.draw(blurred(g.makeImage()!, 16), in: full)
    ctx.restoreGState()
}

// Night side: the terminator darkens the lower-right of the globe.
ctx.drawRadialGradient(gradient([(rgb(0, 0, 0, 0), 0), (rgb(0, 0, 0, 0), 0.45), (rgb(0.0, 0.02, 0.08, 0.55), 0.8), (rgb(0.0, 0.01, 0.05, 0.85), 1)]),
                       startCenter: CGPoint(x: orbC.x - 110, y: orbC.y + 120), startRadius: 0,
                       endCenter: CGPoint(x: orbC.x - 40, y: orbC.y + 40), endRadius: orbR * 1.15, options: [.drawsAfterEndLocation])

// Atmospheric scattering: a blue haze hugging the limb.
ctx.setBlendMode(.plusLighter)
ctx.drawRadialGradient(gradient([(rgb(0.3, 0.7, 1, 0), 0), (rgb(0.3, 0.7, 1, 0), 0.8), (rgb(0.45, 0.8, 1, 0.55), 1)]),
                       startCenter: orbC, startRadius: 0, endCenter: orbC, endRadius: orbR, options: [])
ctx.setBlendMode(.normal)

// Sun glint on the ocean.
ctx.setBlendMode(.plusLighter)
ctx.drawRadialGradient(gradient([(rgb(1, 1, 1, 0.45), 0), (rgb(0.8, 0.9, 1, 0.12), 0.4), (rgb(1, 1, 1, 0), 1)]),
                       startCenter: CGPoint(x: orbC.x - 120, y: orbC.y + 130), startRadius: 0,
                       endCenter: CGPoint(x: orbC.x - 120, y: orbC.y + 130), endRadius: 170, options: [])
ctx.setBlendMode(.normal)
ctx.restoreGState()

// Thin bright rim of atmosphere on the lit edge.
ctx.saveGState()
ctx.addPath(orbPath)
ctx.setLineWidth(4)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(gradient([(rgb(0.75, 0.92, 1, 0.9), 0), (rgb(0.4, 0.7, 1, 0.25), 0.55), (rgb(0.3, 0.5, 1, 0.05), 1)]),
                       start: CGPoint(x: orbRect.minX, y: orbRect.maxY), end: CGPoint(x: orbRect.maxX, y: orbRect.minY), options: [])
ctx.restoreGState()

ctx.restoreGState()   // end tile clip

// Tile edge: a fine bevel, lit from above.
ctx.saveGState()
ctx.addPath(tile)
ctx.setLineWidth(4)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(gradient([(rgb(1, 1, 1, 0.28), 0), (rgb(1, 1, 1, 0.04), 0.5), (rgb(1, 1, 1, 0.10), 1)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
