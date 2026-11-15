import AppKit
import JBLControlKit

/// Builds a Markdown report that's safe to paste into a public GitHub issue.
@MainActor
enum Diagnostics {
    /// Three backticks, spelled without the character so the file stays easy to quote.
    private static let fence = "\u{60}\u{60}\u{60}"

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
            lines.append("- Model: \(model.name) (PID \(hex(model.productID))), "
                + "family \(model.family.rawValue), support \(model.support.label)")
        } else if let pid = speaker.productID {
            lines.append("- Model: unknown PID \(hex(pid))")
        }
        lines.append("- Status: \(speaker.status)")
        if let firmware = speaker.firmware { lines.append("- Firmware: \(firmware)") }
        if let battery = speaker.battery { lines.append("- Battery: \(battery)%\(speaker.isCharging ? " (charging)" : "")") }
        if let eq = speaker.eq {
            lines.append("- EQ: active \(String(format: "%02X", eq.activeCategory)), custom \(speaker.customGains)")
        }
        if let linkMode = speaker.linkMode { lines.append("- Link mode: \(linkMode.label)") }
        if let channel = speaker.stereoChannel { lines.append("- Stereo channel: \(channel.label)") }
        if let role = speaker.role { lines.append("- Link role: \(role.label)") }
        if let locked = speaker.stereoLock { lines.append("- Stereo lock: \(locked ? "on" : "off")") }
        if let group = speaker.auracastGroup {
            var groupLine = "- Group: \(group.type?.label ?? "?") \(group.channel?.label ?? "?")"
            if let id = group.groupIDHex { groupLine += " \(id)" }
            if let name = group.name { groupLine += " \(name)" }
            if let action = group.action { groupLine += ", action \(action)" }
            lines.append(groupLine)
        }

        lines += ["", "### Nearby JBL advertisements", fence]
        for s in speaker.discovered {
            lines.append("\(s.model?.name ?? "unknown") pid=\(s.productID.map(hex) ?? "?") "
                + s.advertisement.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        lines.append(fence)
        if !speaker.infoTokens.isEmpty {
            lines += ["", "### Device info tokens", fence]
            for (token, value) in speaker.infoTokens.sorted(by: { $0.key < $1.key }) {
                lines.append(String(format: "%02X ", token) + Data(value).hex)
            }
            lines.append(fence)
        }
        lines += ["", "### GATT", fence] + speaker.gattSummary + [fence, "", "### Traffic (most recent last)", fence]

        let start = speaker.traffic.first?.date ?? .now
        for entry in speaker.traffic.suffix(80) {
            let t = String(format: "%7.2f", entry.date.timeIntervalSince(start))
            let arrow = entry.direction == .sent ? "→" : "←"
            lines.append("\(t) \(arrow) \(redacted(entry.data).hex)")
        }
        lines.append(fence)
        return lines.joined(separator: "\n")
    }

    private static func hex(_ value: UInt16) -> String { String(format: "%04X", value) }

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
