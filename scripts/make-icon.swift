// Draws the Jarvis app icon (an arc-reactor ring on a dark squircle) and writes assets/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the repo root)
import AppKit

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    let c = CGPoint(x: s / 2, y: s / 2)
    let cyan = NSColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 1)

    // Background: macOS icon grid leaves ~10% margin; continuous-corner squircle with a deep navy gradient.
    let inset = s * 0.1, body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.5).cgColor)
    NSColor.black.setFill(); bg.fill()
    cg.restoreGState()
    bg.addClip()
    NSGradient(colors: [NSColor(red: 0.09, green: 0.13, blue: 0.22, alpha: 1), NSColor(red: 0.02, green: 0.03, blue: 0.07, alpha: 1)])!
        .draw(in: body, angle: -90)
    NSGradient(colors: [cyan.withAlphaComponent(0.28), cyan.withAlphaComponent(0)])!
        .draw(fromCenter: c, radius: 0, toCenter: c, radius: s * 0.36, options: [])

    func ring(_ r: CGFloat, _ w: CGFloat, _ color: NSColor, glow: CGFloat) {
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: glow, color: cyan.cgColor)
        let p = NSBezierPath(); p.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
        p.lineWidth = w; color.setStroke(); p.stroke()
        cg.restoreGState()
    }

    // Outer thin ring, segmented middle ring, solid inner ring, bright core.
    ring(s * 0.315, s * 0.012, cyan.withAlphaComponent(0.55), glow: s * 0.02)
    let segs = 10, rMid = s * 0.245, gap = 7.0
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: s * 0.035, color: cyan.cgColor)
    for i in 0..<segs {
        let a0 = Double(i) * 360 / Double(segs) + 90 + gap / 2
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: rMid, startAngle: a0, endAngle: a0 + 360 / Double(segs) - gap)
        p.lineWidth = s * 0.07; cyan.withAlphaComponent(0.9).setStroke(); p.stroke()
    }
    cg.restoreGState()
    ring(s * 0.165, s * 0.022, NSColor(red: 0.75, green: 0.95, blue: 1, alpha: 1), glow: s * 0.04)
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: s * 0.08, color: cyan.cgColor)
    NSGradient(colors: [.white, NSColor(red: 0.6, green: 0.92, blue: 1, alpha: 1), cyan.withAlphaComponent(0.2)])!
        .draw(fromCenter: c, radius: 0, toCenter: c, radius: s * 0.11, options: [])
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! fm.createDirectory(atPath: "assets", withIntermediateDirectories: true)
try! draw(1024).write(to: URL(fileURLWithPath: "assets/logo.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "assets/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote assets/AppIcon.icns and assets/logo.png" : "iconutil failed")
exit(p.terminationStatus)
