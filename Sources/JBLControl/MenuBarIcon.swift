import AppKit

/// The status-item image: the speaker symbol, plus a battery drawn to its level (with a bolt
/// while charging) when the battery is shown. A template image, so it follows the menu bar's
/// light/dark appearance like the system battery does.
enum MenuBarIcon {
    static func image(connected: Bool, battery: Int?, charging: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let speaker = NSImage(systemSymbolName: connected ? "hifispeaker.fill" : "hifispeaker",
                              accessibilityDescription: "JBLControl")!.withSymbolConfiguration(config)!
        guard let battery else { return speaker }

        let batterySize = NSSize(width: 25, height: 12)
        let gap: CGFloat = 5
        let size = NSSize(width: speaker.size.width + gap + batterySize.width,
                          height: max(speaker.size.height, batterySize.height))
        let image = NSImage(size: size, flipped: false) { _ in
            speaker.draw(in: NSRect(x: 0, y: (size.height - speaker.size.height) / 2,
                                    width: speaker.size.width, height: speaker.size.height))
            drawBattery(in: NSRect(x: speaker.size.width + gap, y: (size.height - batterySize.height) / 2,
                                   width: batterySize.width, height: batterySize.height),
                        level: battery, charging: charging)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = charging ? "Battery \(battery)%, charging" : "Battery \(battery)%"
        return image
    }

    private static func drawBattery(in rect: NSRect, level: Int, charging: Bool) {
        let nubWidth: CGFloat = 2
        let body = NSRect(x: rect.minX, y: rect.minY, width: rect.width - nubWidth - 1, height: rect.height)
        NSColor.black.withAlphaComponent(0.45).setStroke()
        let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
        outline.lineWidth = 1
        outline.stroke()
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: body.maxX + 1, y: body.midY - 2.5, width: nubWidth, height: 5),
                     xRadius: 1, yRadius: 1).fill()

        let inner = body.insetBy(dx: 2, dy: 2)
        let width = max(1.5, inner.width * CGFloat(min(max(level, 0), 100)) / 100)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: width, height: inner.height),
                     xRadius: 1.5, yRadius: 1.5).fill()

        guard charging, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .black)) else { return }
        let boltRect = NSRect(x: body.midX - bolt.size.width / 2, y: body.midY - bolt.size.height / 2,
                              width: bolt.size.width, height: bolt.size.height)
        // Cut a halo first so the bolt reads over both the filled and the empty part.
        bolt.draw(in: boltRect.insetBy(dx: -1.2, dy: -0.6), from: .zero, operation: .destinationOut, fraction: 1)
        bolt.draw(in: boltRect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
