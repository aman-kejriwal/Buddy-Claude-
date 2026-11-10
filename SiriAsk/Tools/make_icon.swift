// Draws the SiriAsk app icon as a 1024×1024 PNG.
// Usage: swift Tools/make_icon.swift <output.png>
// (build-icon.sh turns the PNG into Resources/AppIcon.icns.)
import AppKit
import QuartzCore

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

// Siri palette (matches siriColors in SiriPanel.swift).
let cyan   = rgb(0.25, 0.82, 1.00)
let blue   = rgb(0.30, 0.42, 1.00)
let violet = rgb(0.71, 0.36, 1.00)
let pink   = rgb(1.00, 0.31, 0.63)
let orange = rgb(1.00, 0.64, 0.23)

let center = CGPoint(x: S / 2, y: S / 2)

// macOS icon grid: 824 pt body inside a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0, 0, 0, 0.5))
ctx.addPath(squircle)
ctx.setFillColor(rgb(0.04, 0.03, 0.09))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

// Deep night background.
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0.13, 0.08, 0.26), rgb(0.02, 0.02, 0.07)] as CFArray,
                    locations: [0, 1])!
ctx.drawRadialGradient(bg, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 620, options: [.drawsAfterEndLocation])

// Soft glowing colour blobs that blend into an orb.
func blob(_ p: CGPoint, _ r: CGFloat, _ color: CGColor, _ alpha: CGFloat) {
    let g = CGGradient(colorsSpace: cs,
                       colors: [color.copy(alpha: alpha)!, color.copy(alpha: alpha * 0.35)!, color.copy(alpha: 0)!] as CFArray,
                       locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [])
}

ctx.setBlendMode(.plusLighter)
blob(CGPoint(x: 512, y: 512), 380, violet, 0.35)       // halo
blob(CGPoint(x: 420, y: 590), 230, cyan, 0.75)
blob(CGPoint(x: 610, y: 600), 220, violet, 0.75)
blob(CGPoint(x: 600, y: 420), 220, pink, 0.75)
blob(CGPoint(x: 420, y: 430), 210, blue, 0.8)
blob(CGPoint(x: 530, y: 330), 150, orange, 0.45)
ctx.setBlendMode(.normal)

// Glowing conic ring around the orb.
let ringR: CGFloat = 268, ringW: CGFloat = 26
let ring = CGMutablePath()
ring.addEllipse(in: CGRect(x: center.x - ringR - ringW / 2, y: center.y - ringR - ringW / 2,
                           width: 2 * ringR + ringW, height: 2 * ringR + ringW))
ring.addEllipse(in: CGRect(x: center.x - ringR + ringW / 2, y: center.y - ringR + ringW / 2,
                           width: 2 * ringR - ringW, height: 2 * ringR - ringW))

let conic = CAGradientLayer()
conic.type = .conic
conic.frame = CGRect(x: 0, y: 0, width: S, height: S)
conic.startPoint = CGPoint(x: 0.5, y: 0.5)
conic.endPoint = CGPoint(x: 0.5, y: 0)
conic.colors = [cyan, blue, violet, pink, orange, cyan]

func drawRing(blur: CGFloat, alpha: CGFloat) {
    // Render the conic gradient into its own image, clipped to the ring, then composite with a glow.
    let layerCtx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                             space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    layerCtx.addPath(ring)
    layerCtx.clip(using: .evenOdd)
    conic.render(in: layerCtx)
    let img = layerCtx.makeImage()!

    ctx.saveGState()
    ctx.setAlpha(alpha)
    if blur > 0 {
        ctx.setShadow(offset: .zero, blur: blur, color: rgb(0.75, 0.55, 1.0, 0.95))
    }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: S, height: S))
    ctx.restoreGState()
}
drawRing(blur: 60, alpha: 0.9)
drawRing(blur: 18, alpha: 1.0)

// Four-point sparkle.
func sparkle(at c: CGPoint, radius R: CGFloat, pinch k: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let top = CGPoint(x: c.x, y: c.y + R), right = CGPoint(x: c.x + R, y: c.y)
    let bottom = CGPoint(x: c.x, y: c.y - R), left = CGPoint(x: c.x - R, y: c.y)
    p.move(to: top)
    p.addQuadCurve(to: right, control: CGPoint(x: c.x + k, y: c.y + k))
    p.addQuadCurve(to: bottom, control: CGPoint(x: c.x + k, y: c.y - k))
    p.addQuadCurve(to: left, control: CGPoint(x: c.x - k, y: c.y - k))
    p.addQuadCurve(to: top, control: CGPoint(x: c.x - k, y: c.y + k))
    p.closeSubpath()
    return p
}

func drawSparkle(_ path: CGPath, glow: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: glow, color: rgb(1, 1, 1, 0.95))
    ctx.addPath(path)
    ctx.setFillColor(rgb(1, 1, 1))
    ctx.fillPath()
    ctx.restoreGState()
}

drawSparkle(sparkle(at: center, radius: 190, pinch: 26), glow: 50)
drawSparkle(sparkle(at: CGPoint(x: 700, y: 712), radius: 62, pinch: 9), glow: 26)
drawSparkle(sparkle(at: CGPoint(x: 340, y: 322), radius: 38, pinch: 6), glow: 18)

// Subtle glass sheen on the top half of the tile.
let sheen = CGGradient(colorsSpace: cs, colors: [rgb(1, 1, 1, 0.10), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])

ctx.restoreGState()

// Thin inner edge highlight.
ctx.saveGState()
ctx.addPath(squircle)
ctx.setStrokeColor(rgb(1, 1, 1, 0.12))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
