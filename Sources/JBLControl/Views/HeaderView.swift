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
                            BatteryPill(level: level, charging: speaker.isCharging)
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
    let charging: Bool

    var body: some View {
        HStack(spacing: 5) {
            BatteryGlyph(level: level, charging: charging)
            Text("\(level)%")
                .monospacedDigit()
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .help(charging ? "Battery \(level)%, charging" : "Battery \(level)%")
    }
}

/// A battery drawn to its actual level, with a bolt while charging (like the macOS menu bar).
/// SF Symbols only ships a charging battery at 100%.
struct BatteryGlyph: View {
    let level: Int
    let charging: Bool

    private var fill: Color {
        if charging { return .green }
        return level <= Notifier.lowBatteryThreshold ? .red : .primary
    }

    var body: some View {
        HStack(spacing: 1) {
            ZStack {
                RoundedRectangle(cornerRadius: 3.5)
                    .strokeBorder(.primary.opacity(0.45), lineWidth: 1)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fill)
                        .frame(width: max(2, (geo.size.width) * CGFloat(min(max(level, 0), 100)) / 100))
                }
                .padding(2)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 0.5)
                }
            }
            .frame(width: 23, height: 11.5)
            RoundedRectangle(cornerRadius: 1)
                .fill(.primary.opacity(0.45))
                .frame(width: 1.5, height: 4)
        }
        .accessibilityHidden(true)
    }
}
