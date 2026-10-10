import AppKit
import JBLControlKit

/// Builds a Markdown report that's safe to paste into a public GitHub issue.
@MainActor
enum Diagnostics {
    static func copyReport(_ speaker: SpeakerManager) async {
        await speaker.runDiagnosticProbe()
        let report = build(speaker)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    static func build(_ speaker: SpeakerManager) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var lines = ["## JBLControl diagnostics", "", "- App: \(version)", "- macOS: \(os)"]

        if let model = speaker.model {
            lines.append("- Model: \(model.name) (PID `\(String(format: "%04X", model.productID))`), "
                + "family `\(model.family.rawValue)`, support `\(model.support.label)`")
        } else if let pid = speaker.productID {
            lines.append("- Model: unknown PID `\(String(format: "%04X", pid))`")
        }
        lines.append("- Status: \(speaker.status)")
        if let firmware = speaker.firmware { lines.append("- Firmware: \(firmware)") }
        if let battery = speaker.battery { lines.append("- Battery: \(battery)%\(speaker.isCharging ? " (charging)" : "")") }
        if let eq = speaker.eq {
            lines.append("- EQ: active `\(String(format: "%02X", eq.activeCategory))`, custom \(speaker.customGains)")
        }

        lines += ["", "### Nearby JBL advertisements", "```"]
        for s in speaker.discovered {
            lines.append("\(s.model?.name ?? "unknown") pid=\(s.productID.map { String(format: "%04X", $0) } ?? "?") "
                + s.advertisement.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        lines += ["```", "", "### GATT", "```"] + speaker.gattSummary + ["```", "", "### Traffic (most recent last)", "```"]

        let start = speaker.traffic.first?.date ?? .now
        for entry in speaker.traffic.suffix(80) {
            let t = String(format: "%7.2f", entry.date.timeIntervalSince(start))
            let arrow = entry.direction == .sent ? "→" : "←"
            lines.append("\(t) \(arrow) \(redacted(entry.data).hex)")
        }
        lines.append("```")
        return lines.joined(separator: "\n")
    }

    /// Masks the MAC address (info token 0x48) and serial number (0xC2).
    static func redacted(_ data: Data) -> Data {
        var b = [UInt8](data)
        guard b.count > 5, b[0] == 0xAA, b[1] == 0x12 else { return data }
        if b[4] == 0x48 || b[4] == 0xC2 {
            for i in 5..<b.count { b[i] = 0x00 }
        }
        return Data(b)
    }
}
