import AppKit
import JBLControlKit
import SwiftUI

struct HeaderView: View {
    @Environment(SpeakerManager.self) private var speaker

    var body: some View {
        HStack(spacing: 14) {
            SpeakerArtwork(model: speaker.model, colorCode: speaker.colorCode)
                .frame(width: 104, height: 104)
                .opacity(speaker.status == .connected ? 1 : 0.55)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let model = speaker.model, model.support != .verified {
                        SupportBadge(level: model.support)
                    }
                }
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        StatusPill()
                        if speaker.status == .connected, let level = speaker.battery {
                            BatteryPill(level: level)
                        }
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        speaker.name ?? speaker.model?.name ?? "JBL Speaker"
    }

    private var subtitle: String {
        guard let model = speaker.model else {
            return speaker.productID.map { String(format: "Unknown model %04X", $0) } ?? "Looking for speakers…"
        }
        guard let code = speaker.colorCode else { return model.shortName }
        return "\(model.shortName) · \(model.color(code).name)"
    }
}

struct SupportBadge: View {
    let level: SupportLevel

    var body: some View {
        Text(level.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: .capsule)
            .help(help)
    }

    private var tint: Color {
        switch level {
        case .verified: .green
        case .beta: .orange
        case .experimental: .purple
        case .unsupported: .secondary
        }
    }

    private var help: String {
        switch level {
        case .verified: "Confirmed on real hardware."
        case .beta: "Protocol taken from JBL's app. Reading works; EQ changes are untested on this model."
        case .experimental: "Newer protocol nobody has tested from a Mac yet. Please send a diagnostics report."
        case .unsupported: "This model can't be controlled over Bluetooth LE from a Mac."
        }
    }
}

struct StatusPill: View {
    @Environment(SpeakerManager.self) private var speaker

    var body: some View {
        HStack(spacing: 5) {
            switch speaker.status {
            case .connected:
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("Connected")
            case .connecting, .searching:
                ProgressView().controlSize(.mini)
                Text(speaker.status == .searching ? "Searching…" : "Connecting…")
            case .bluetoothOff:
                Image(systemName: "bolt.horizontal.circle")
                Text("Bluetooth off")
            case .unauthorized:
                Image(systemName: "lock.fill")
                Button("Allow Bluetooth") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }
}

struct BatteryPill: View {
    let level: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(level <= 20 ? .red : .primary)
            Text("\(level)%")
                .monospacedDigit()
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .help("Battery \(level)%")
    }

    private var symbol: String {
        switch level {
        case 88...: "battery.100percent"
        case 63..<88: "battery.75percent"
        case 38..<63: "battery.50percent"
        case 13..<38: "battery.25percent"
        default: "battery.0percent"
        }
    }
}
