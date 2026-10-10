import AppKit

/// The status-item image: the speaker symbol (orange while Keep Awake is on), plus — when the
/// battery is shown — a macOS-style battery with the percentage printed inside, filled to the level:
/// green with a bolt while charging, red when low.
enum MenuBarIcon {
    static func image(connected: Bool, battery: Int?, charging: Bool, keepingAwake: Bool = false) -> NSImage {
        let symbol = NSImage(systemSymbolName: connected ? "hifispeaker.fill" : "hifispeaker",
                             accessibilityDescription: "JBLControl")!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))!

        let awakeSymbol = NSImage(systemSymbolName: "hifispeaker", accessibilityDescription: "Keeping speaker awake")!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .bold))!

        // Plain case: a template image, tinted by the menu bar like every other icon.
        guard battery != nil || keepingAwake else { return symbol }

        let batterySize = NSSize(width: 28, height: 13)
        let gap: CGFloat = 4
        let speakerWidth = max(symbol.size.width, awakeSymbol.size.width)
        let width = speakerWidth + (battery != nil ? gap + batterySize.width + 2 : 0)
        let size = NSSize(width: width, height: max(symbol.size.height, batterySize.height))

        // Drawn lazily, so `labelColor` resolves to the menu bar's light or dark appearance.
        let image = NSImage(size: size, flipped: false) { _ in
            // Keep Awake: a bold outline speaker in orange; its thick strokes stay readable
            // where the filled symbol's thin cut-outs disappear.
            let speaker = keepingAwake ? tinted(awakeSymbol, .systemOrange) : tinted(symbol, .labelColor)
            speaker.draw(in: NSRect(x: 0, y: (size.height - speaker.size.height) / 2,
                                    width: speaker.size.width, height: speaker.size.height))
            if let battery {
                drawBattery(in: NSRect(x: speakerWidth + gap, y: (size.height - batterySize.height) / 2,
                                       width: batterySize.width, height: batterySize.height),
                            level: battery, charging: charging)
            }
            return true
        }
        image.isTemplate = false
        var description = keepingAwake ? "Keeping speaker awake" : "JBLControl"
        if let battery { description += ", battery \(battery)%\(charging ? ", charging" : "")" }
        image.accessibilityDescription = description
        return image
    }

    /// The symbol used as a mask and filled with `color`, keeping its cut-outs transparent.
    private static func tinted(_ symbol: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private static func drawBattery(in rect: NSRect, level: Int, charging: Bool) {
        let nub: CGFloat = 1.5
        let body = NSRect(x: rect.minX, y: rect.minY, width: rect.width - nub - 1, height: rect.height)

        NSColor.labelColor.withAlphaComponent(0.4).setStroke()
        let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
        outline.lineWidth = 1
        outline.stroke()
        NSColor.labelColor.withAlphaComponent(0.4).setFill()
        NSBezierPath(roundedRect: NSRect(x: body.maxX + 1, y: body.midY - 2.5, width: nub, height: 5),
                     xRadius: 0.75, yRadius: 0.75).fill()

        let inner = body.insetBy(dx: 1.5, dy: 1.5)
        let fill: NSColor = charging ? .systemGreen
            : level <= Notifier.lowBatteryThreshold ? .systemRed
            : .labelColor.withAlphaComponent(0.28)
        fill.setFill()
        let width = max(1.5, inner.width * CGFloat(min(max(level, 0), 100)) / 100)
        NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: width, height: inner.height),
                     xRadius: 2, yRadius: 2).fill()

        // The percentage inside, with a small bolt before it while charging.
        let font = NSFont.systemFont(ofSize: level >= 100 ? 7.5 : 8.5, weight: .bold)
        let text = NSMutableAttributedString()
        if charging, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 6.5, weight: .black)) {
            let attachment = NSTextAttachment()
            attachment.image = bolt.withSymbolConfiguration(.init(paletteColors: [.labelColor])) ?? bolt
            attachment.bounds = NSRect(x: 0, y: -0.5, width: bolt.size.width, height: bolt.size.height)
            text.append(NSAttributedString(attachment: attachment))
        }
        text.append(NSAttributedString(string: "\(level)", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        let textSize = text.size()
        text.draw(at: CGPoint(x: body.midX - textSize.width / 2, y: body.midY - textSize.height / 2))
    }
}
