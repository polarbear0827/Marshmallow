// Renders the Marshmallow app icon into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = s / 1024

    // Squircle background: soft pink → lavender
    let inset = 100 * u
    let bgRect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: 185 * u, yRadius: 185 * u)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 24 * u
    shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
    shadow.set()
    NSColor.white.setFill(); bg.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.72, alpha: 1),
                        NSColor(calibratedRed: 0.78, green: 0.64, blue: 1.0, alpha: 1)])!
        .draw(in: bg, angle: -60)

    // Wheel ring hint
    let ring = NSBezierPath(ovalIn: bgRect.insetBy(dx: 90 * u, dy: 90 * u))
    ring.lineWidth = 26 * u
    NSColor.white.withAlphaComponent(0.28).setStroke()
    ring.stroke()

    // Marshmallow body
    let bodyW = 400 * u, bodyH = 380 * u
    let bodyRect = NSRect(x: (s - bodyW) / 2, y: 300 * u, width: bodyW, height: bodyH)
    let body = NSBezierPath(roundedRect: bodyRect, xRadius: 130 * u, yRadius: 130 * u)
    NSGraphicsContext.saveGraphicsState()
    let sh2 = NSShadow()
    sh2.shadowColor = NSColor(calibratedRed: 0.5, green: 0.2, blue: 0.4, alpha: 0.35)
    sh2.shadowBlurRadius = 40 * u
    sh2.shadowOffset = NSSize(width: 0, height: -18 * u)
    sh2.set()
    NSColor.white.setFill(); body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor.white, NSColor(calibratedRed: 1.0, green: 0.93, blue: 0.95, alpha: 1)])!
        .draw(in: body, angle: -90)

    // Top face
    let topRect = NSRect(x: bodyRect.minX + 18 * u, y: bodyRect.maxY - 150 * u, width: bodyW - 36 * u, height: 130 * u)
    let top = NSBezierPath(ovalIn: topRect)
    NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.98, alpha: 1).setFill(); top.fill()
    top.lineWidth = 5 * u
    NSColor(calibratedRed: 0.95, green: 0.82, blue: 0.87, alpha: 1).setStroke(); top.stroke()

    // Toasted spot
    let toast = NSBezierPath(ovalIn: NSRect(x: bodyRect.midX - 95 * u, y: bodyRect.minY + 70 * u, width: 190 * u, height: 110 * u))
    NSGradient(colors: [NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.45, alpha: 0.85),
                        NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.45, alpha: 0.0)])!
        .draw(in: toast, relativeCenterPosition: .zero)

    // Cute face
    NSColor(calibratedRed: 0.3, green: 0.2, blue: 0.28, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: bodyRect.midX - 80 * u, y: bodyRect.minY + 175 * u, width: 30 * u, height: 38 * u)).fill()
    NSBezierPath(ovalIn: NSRect(x: bodyRect.midX + 50 * u, y: bodyRect.minY + 175 * u, width: 30 * u, height: 38 * u)).fill()
    let smile = NSBezierPath()
    smile.move(to: NSPoint(x: bodyRect.midX - 26 * u, y: bodyRect.minY + 160 * u))
    smile.curve(to: NSPoint(x: bodyRect.midX + 26 * u, y: bodyRect.minY + 160 * u),
                controlPoint1: NSPoint(x: bodyRect.midX - 14 * u, y: bodyRect.minY + 135 * u),
                controlPoint2: NSPoint(x: bodyRect.midX + 14 * u, y: bodyRect.minY + 135 * u))
    smile.lineWidth = 10 * u
    smile.lineCapStyle = .round
    NSColor(calibratedRed: 0.3, green: 0.2, blue: 0.28, alpha: 1).setStroke()
    smile.stroke()
    NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.65, alpha: 0.55).setFill()
    NSBezierPath(ovalIn: NSRect(x: bodyRect.midX - 135 * u, y: bodyRect.minY + 140 * u, width: 56 * u, height: 32 * u)).fill()
    NSBezierPath(ovalIn: NSRect(x: bodyRect.midX + 79 * u, y: bodyRect.minY + 140 * u, width: 56 * u, height: 32 * u)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: outDir.appendingPathComponent("icon_\(name).png"))
}
