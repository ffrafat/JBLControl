// Draws the DMG window background (640×480 pt, plus @2x; taller than the window so no title-bar height clips it) into Resources/DMG/.
// Usage: swift scripts/make-dmg-background.swift   (then build-app.sh --dmg uses it)
// Icon positions here must match scripts/dmg-settings.py.
import AppKit

let size = NSSize(width: 640, height: 480)
let appCenter = CGPoint(x: 170, y: 190)     // from the top-left, like Finder
let appsCenter = CGPoint(x: 470, y: 190)
let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Resources/DMG").standardized

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    // Flip so y runs top-down, matching Finder's icon coordinates.
    ctx.cgContext.translateBy(x: 0, y: size.height)
    ctx.cgContext.scaleBy(x: 1, y: -1)

    // Pale sunset wash.
    NSGradient(colors: [NSColor(srgbRed: 1.00, green: 0.95, blue: 0.90, alpha: 1),
                        NSColor(srgbRed: 1.00, green: 0.88, blue: 0.84, alpha: 1)])!
        .draw(in: NSRect(origin: .zero, size: size), angle: 90)

    let ink = NSColor(srgbRed: 0.22, green: 0.12, blue: 0.08, alpha: 1)
    let accent = NSColor(srgbRed: 0.96, green: 0.36, blue: 0.13, alpha: 1)

    func text(_ s: String, _ font: NSFont, _ color: NSColor, centerY: CGFloat) {
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
        let h = attr.size().height
        // Text draws upright in the flipped context only when the context is flipped for it.
        NSGraphicsContext.saveGraphicsState()
        let flipped = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
        NSGraphicsContext.current = flipped
        attr.draw(in: NSRect(x: 0, y: centerY - h / 2, width: size.width, height: h))
        NSGraphicsContext.restoreGraphicsState()
    }

    text("Drag JBLControl to your Applications folder", .systemFont(ofSize: 17, weight: .semibold), ink, centerY: 52)

    // Arrow from the app to Applications.
    let arrow = NSBezierPath()
    let y = appCenter.y - 8
    arrow.move(to: CGPoint(x: appCenter.x + 82, y: y))
    arrow.line(to: CGPoint(x: appsCenter.x - 92, y: y))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    accent.setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: appsCenter.x - 80, y: y))
    head.line(to: CGPoint(x: appsCenter.x - 100, y: y - 13))
    head.line(to: CGPoint(x: appsCenter.x - 100, y: y + 13))
    head.close()
    accent.setFill()
    head.fill()

    // First-launch help, right where beginners will look.
    let card = NSBezierPath(roundedRect: NSRect(x: 40, y: 300, width: 560, height: 78), xRadius: 14, yRadius: 14)
    NSColor.white.withAlphaComponent(0.7).setFill()
    card.fill()
    text("Blocked the first time you open it?", .systemFont(ofSize: 13, weight: .semibold), ink, centerY: 322)
    text("System Settings  →  Privacy & Security  →  Open Anyway", .systemFont(ofSize: 13, weight: .medium), accent, centerY: 342)
    text("That's expected: JBLControl is free and open source, just not notarized by Apple yet.",
         .systemFont(ofSize: 11, weight: .regular), ink.withAlphaComponent(0.7), centerY: 362)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    try render(scale: scale).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
print("wrote \(out.path)/background.png and @2x")
