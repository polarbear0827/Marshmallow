// Renders the DMG window background (1x and 2x).
// Usage: swift scripts/make-dmg-background.swift <out-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 660, height: 420)

func render(scale: CGFloat) -> Data {
    let px = NSSize(width: size.width * scale, height: size.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let r = NSRect(origin: .zero, size: size)

    // Soft marshmallow gradient
    NSGradient(colors: [NSColor(srgbRed: 1.0, green: 0.93, blue: 0.95, alpha: 1),
                        NSColor(srgbRed: 0.95, green: 0.92, blue: 1.0, alpha: 1)])!.draw(in: r, angle: -90)

    let para = NSMutableParagraphStyle(); para.alignment = .center
    ("把棉花糖拖進「應用程式」就安裝好了" as NSString).draw(
        in: NSRect(x: 0, y: size.height - 78, width: size.width, height: 34),
        withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .bold),
                         .foregroundColor: NSColor(srgbRed: 0.35, green: 0.22, blue: 0.32, alpha: 1),
                         .paragraphStyle: para])
    ("Drag Marshmallow to Applications to install" as NSString).draw(
        in: NSRect(x: 0, y: size.height - 104, width: size.width, height: 22),
        withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                         .foregroundColor: NSColor(srgbRed: 0.55, green: 0.42, blue: 0.52, alpha: 1),
                         .paragraphStyle: para])

    // Arrow between the two icons (icons are centred at x=170 and x=490, y=200 from the top)
    let y = size.height - 205
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: y))
    arrow.curve(to: NSPoint(x: 392, y: y), controlPoint1: NSPoint(x: 300, y: y + 26), controlPoint2: NSPoint(x: 354, y: y + 26))
    arrow.lineWidth = 7
    arrow.lineCapStyle = .round
    let pink = NSColor(srgbRed: 1.0, green: 0.45, blue: 0.62, alpha: 1)
    pink.setStroke()
    let dash: [CGFloat] = [2, 14]
    arrow.setLineDash(dash, count: 2, phase: 0)
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 408, y: y - 2))
    head.line(to: NSPoint(x: 386, y: y + 14))
    head.line(to: NSPoint(x: 388, y: y - 14))
    head.close()
    pink.setFill()
    head.fill()

    ("第一次打開時，如果出現「無法確認開發者」：\n系統設定 → 隱私權與安全性 → 最下面按「仍要打開」" as NSString).draw(
        in: NSRect(x: 40, y: 22, width: size.width - 80, height: 44),
        withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .regular),
                         .foregroundColor: NSColor(srgbRed: 0.5, green: 0.42, blue: 0.5, alpha: 1),
                         .paragraphStyle: para])
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try! render(scale: 1).write(to: out.appendingPathComponent("background.png"))
try! render(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
