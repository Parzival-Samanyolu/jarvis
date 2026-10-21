// Draws the Mycroft app icon (a bowler hat, monocle and moustache over a Union Jack, with a teabag tag
// hanging off the brim) and writes assets/AppIcon.icns and assets/logo.png.
// Usage: swift scripts/make-icon.swift   (run from the repo root)
import AppKit

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }   // unit square, y up

    let navy = NSColor(red: 0.004, green: 0.129, blue: 0.412, alpha: 1)   // #012169
    let red = NSColor(red: 0.784, green: 0.063, blue: 0.180, alpha: 1)    // #C8102E
    let ink = NSColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
    let gold = NSColor(red: 0.86, green: 0.70, blue: 0.32, alpha: 1)

    // Background: macOS icon grid leaves ~10% margin; continuous-corner squircle.
    let inset = s * 0.1, body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.5).cgColor)
    NSColor.black.setFill(); bg.fill()
    cg.restoreGState()
    cg.saveGState()
    bg.addClip()

    // Union Jack, squared to the icon. Proportions from the flag (height 30): saltire 6 (red 2, counterchanged),
    // white cross 10, red cross 6.
    let u = body.height / 30, c = NSPoint(x: body.midX, y: body.midY)
    navy.setFill(); body.fill()
    func stripe(_ a: NSPoint, _ b: NSPoint, _ w: CGFloat, _ color: NSColor) {
        let l = NSBezierPath(); l.move(to: a); l.line(to: b); l.lineWidth = w; l.lineCapStyle = .butt; color.setStroke(); l.stroke()
    }
    stripe(NSPoint(x: body.minX, y: body.minY), NSPoint(x: body.maxX, y: body.maxY), 6 * u, .white)
    stripe(NSPoint(x: body.minX, y: body.maxY), NSPoint(x: body.maxX, y: body.minY), 6 * u, .white)
    // Red diagonals: in each arm the red sits on the anticlockwise side of the centre line, giving the pinwheel.
    for deg in [45.0, 135.0, 225.0, 315.0] {
        let a = deg * .pi / 180, perp = a + .pi / 2
        let off = NSPoint(x: cos(perp) * u, y: sin(perp) * u)   // centre of a 2u-wide stripe sits 1u off the line
        let far = body.width
        stripe(NSPoint(x: c.x + off.x, y: c.y + off.y), NSPoint(x: c.x + off.x + cos(a) * far, y: c.y + off.y + sin(a) * far), 2 * u, red)
    }
    stripe(NSPoint(x: c.x, y: body.minY), NSPoint(x: c.x, y: body.maxY), 10 * u, .white)
    stripe(NSPoint(x: body.minX, y: c.y), NSPoint(x: body.maxX, y: c.y), 10 * u, .white)
    stripe(NSPoint(x: c.x, y: body.minY), NSPoint(x: c.x, y: body.maxY), 6 * u, red)
    stripe(NSPoint(x: body.minX, y: c.y), NSPoint(x: body.maxX, y: c.y), 6 * u, red)
    // Soften the flag so the figure reads first: a dark vignette, lighter in the middle.
    NSGradient(colors: [NSColor.black.withAlphaComponent(0.05), NSColor.black.withAlphaComponent(0.35)])!
        .draw(fromCenter: c, radius: 0, toCenter: c, radius: body.width * 0.75, options: [])

    // The figure, drawn as one layer with a soft light halo so it lifts off the flag.
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: s * 0.035, color: NSColor.white.withAlphaComponent(0.85).cgColor)
    cg.beginTransparencyLayer(auxiliaryInfo: nil)

    // Teabag string and tag (the wink), hanging from the brim on the left.
    let string = NSBezierPath()
    string.move(to: p(0.285, 0.585))
    string.curve(to: p(0.245, 0.43), controlPoint1: p(0.27, 0.53), controlPoint2: p(0.23, 0.48))
    string.lineWidth = s * 0.006; NSColor(white: 0.93, alpha: 1).setStroke(); string.stroke()
    let tag = NSBezierPath(roundedRect: NSRect(x: 0.195 * s, y: 0.335 * s, width: 0.10 * s, height: 0.10 * s), xRadius: s * 0.008, yRadius: s * 0.008)
    NSColor(red: 0.98, green: 0.95, blue: 0.86, alpha: 1).setFill(); tag.fill()
    NSBezierPath(rect: NSRect(x: 0.195 * s, y: 0.405 * s, width: 0.10 * s, height: 0.012 * s)).fill(with: red)

    // Bowler crown, band and curled brim.
    ink.setFill()
    let crown = NSBezierPath()
    crown.move(to: p(0.315, 0.585))
    crown.curve(to: p(0.5, 0.815), controlPoint1: p(0.30, 0.73), controlPoint2: p(0.38, 0.815))
    crown.curve(to: p(0.685, 0.585), controlPoint1: p(0.62, 0.815), controlPoint2: p(0.70, 0.73))
    crown.close(); crown.fill()
    cg.saveGState()
    crown.addClip()
    NSColor(white: 0.28, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0.3 * s, y: 0.585 * s, width: 0.4 * s, height: 0.045 * s)).fill()
    // A touch of sheen on the felt
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: p(0.43, 0.75), radius: 0, toCenter: p(0.43, 0.75), radius: s * 0.13, options: [])
    cg.restoreGState()
    ink.setFill()
    let brim = NSBezierPath()
    brim.move(to: p(0.215, 0.605))
    brim.curve(to: p(0.5, 0.565), controlPoint1: p(0.25, 0.575), controlPoint2: p(0.38, 0.565))
    brim.curve(to: p(0.785, 0.605), controlPoint1: p(0.62, 0.565), controlPoint2: p(0.75, 0.575))
    brim.curve(to: p(0.5, 0.595), controlPoint1: p(0.72, 0.6), controlPoint2: p(0.60, 0.595))
    brim.curve(to: p(0.215, 0.605), controlPoint1: p(0.40, 0.595), controlPoint2: p(0.28, 0.6))
    brim.close()
    let brimBody = NSBezierPath(roundedRect: NSRect(x: 0.225 * s, y: 0.565 * s, width: 0.55 * s, height: 0.035 * s), xRadius: s * 0.0175, yRadius: s * 0.0175)
    brim.fill(); brimBody.fill()

    // Eyebrows: the monocle side raised, naturally.
    for (a, b, cp) in [(p(0.37, 0.505), p(0.46, 0.50), p(0.415, 0.525)), (p(0.54, 0.53), p(0.65, 0.535), p(0.595, 0.565))] {
        let brow = NSBezierPath(); brow.move(to: a); brow.curve(to: b, controlPoint1: cp, controlPoint2: cp)
        brow.lineWidth = s * 0.02; brow.lineCapStyle = .round; ink.setStroke(); brow.stroke()
    }
    // Plain eye, then the monocle with its gold rim, glass and chain.
    NSBezierPath(ovalIn: NSRect(x: 0.393 * s, y: 0.43 * s, width: 0.045 * s, height: 0.045 * s)).fill(with: ink)
    let mono = NSRect(x: 0.525 * s, y: 0.385 * s, width: 0.14 * s, height: 0.14 * s)
    NSBezierPath(ovalIn: mono).fill(with: NSColor(white: 1, alpha: 0.25))
    NSBezierPath(ovalIn: NSRect(x: 0.573 * s, y: 0.433 * s, width: 0.045 * s, height: 0.045 * s)).fill(with: ink)
    let rim = NSBezierPath(ovalIn: mono); rim.lineWidth = s * 0.016; gold.setStroke(); rim.stroke()
    let glint = NSBezierPath(); glint.appendArc(withCenter: p(0.595, 0.455), radius: s * 0.05, startAngle: 110, endAngle: 160)
    glint.lineWidth = s * 0.01; glint.lineCapStyle = .round; NSColor.white.withAlphaComponent(0.9).setStroke(); glint.stroke()
    let chain = NSBezierPath()
    chain.move(to: p(0.66, 0.42))
    chain.curve(to: p(0.70, 0.22), controlPoint1: p(0.72, 0.36), controlPoint2: p(0.66, 0.27))
    chain.lineWidth = s * 0.008; chain.setLineDash([s * 0.012, s * 0.008], count: 2, phase: 0); gold.setStroke(); chain.stroke()

    // Handlebar moustache, mirrored about the centre.
    for f: CGFloat in [1, -1] {
        func q(_ dx: CGFloat, _ y: CGFloat) -> NSPoint { p(0.5 + dx * f, y) }
        let m = NSBezierPath()
        m.move(to: q(0, 0.345))
        m.curve(to: q(0.155, 0.325), controlPoint1: q(0.05, 0.375), controlPoint2: q(0.11, 0.33))
        m.curve(to: q(0.175, 0.375), controlPoint1: q(0.20, 0.32), controlPoint2: q(0.205, 0.36))
        m.curve(to: q(0.15, 0.295), controlPoint1: q(0.215, 0.33), controlPoint2: q(0.19, 0.29))
        m.curve(to: q(0, 0.315), controlPoint1: q(0.10, 0.30), controlPoint2: q(0.04, 0.30))
        m.close()
        ink.setFill(); m.fill()
    }

    cg.endTransparencyLayer()
    cg.restoreGState()
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

extension NSBezierPath { func fill(with c: NSColor) { c.setFill(); fill() } }

let fm = FileManager.default
let preview = CommandLine.arguments.dropFirst().first   // optional: write only a 1024px PNG here
if let preview {
    try! draw(1024).write(to: URL(fileURLWithPath: preview)); print("Wrote \(preview)"); exit(0)
}
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! fm.createDirectory(atPath: "assets", withIntermediateDirectories: true)
try! draw(1024).write(to: URL(fileURLWithPath: "assets/logo.png"))
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", set.path, "-o", "assets/AppIcon.icns"]
try! proc.run(); proc.waitUntilExit()
print(proc.terminationStatus == 0 ? "Wrote assets/AppIcon.icns and assets/logo.png" : "iconutil failed")
exit(proc.terminationStatus)
