import AppKit
import JBLControlKit
import SwiftUI

struct HeaderView: View {
    @Environment(SpeakerManager.self) private var speaker
    var artworkSize: CGFloat = 104

    var body: some View {
        HStack(spacing: 14) {
            SpeakerArtwork(model: speaker.model, colorCode: speaker.colorCode)
                .frame(width: artworkSize, height: artworkSize)
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
                AdaptiveGlassContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        StatusPill()
                        // One pill for battery and Keep Awake, so the row never wraps.
                        BatteryPill(level: speaker.status == .connected ? speaker.battery : nil,
                                    charging: speaker.isCharging)
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
        .adaptiveGlass(.regular, in: .capsule)
    }
}

/// Battery (percentage inside the glyph, like macOS) and, while Keep Awake is on, a cup that
/// turns it off when clicked. Hidden when there's nothing to show.
struct BatteryPill: View {
    @Environment(KeepAwake.self) private var keepAwake
    let level: Int?
    let charging: Bool

    var body: some View {
        if level != nil || keepAwake.state != .off {
            HStack(spacing: 6) {
                if let level {
                    BatteryGlyph(level: level, charging: charging)
                }
                if keepAwake.state != .off {
                    let active = keepAwake.state == .active
                    Button {
                        withAnimation(.smooth) { keepAwake.isEnabled = false }
                    } label: {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(active ? Theme.accent : .secondary)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help(active
                          ? "Keeping the speaker awake. Click to turn off."
                          : "Keep Awake is on, but this speaker isn't your Mac's sound output, so it can't be kept "
                            + "awake. Choose it in Control Center → Sound. Click to turn off.")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .adaptiveGlass(.regular, in: .capsule)
            .help(level.map { charging ? "Battery \($0)%, charging" : "Battery \($0)%" } ?? "")
        }
    }
}

/// A battery with the percentage printed inside, filled to the level: green with a bolt while
/// charging, red when low (like the macOS battery icon).
struct BatteryGlyph: View {
    let level: Int
    let charging: Bool

    private var fill: Color {
        if charging { return .green }
        return level <= Notifier.lowBatteryThreshold ? .red : .primary.opacity(0.22)
    }

    var body: some View {
        HStack(spacing: 1) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.primary.opacity(0.4), lineWidth: 1)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(fill)
                        .frame(width: max(2, geo.size.width * CGFloat(min(max(level, 0), 100)) / 100))
                }
                .padding(1.5)
                HStack(spacing: 1) {
                    if charging {
                        Image(systemName: "bolt.fill").font(.system(size: 7, weight: .black))
                    }
                    Text("\(level)")
                        .font(.system(size: level >= 100 ? 8.5 : 9.5, weight: .bold))
                        .monospacedDigit()
                }
                .foregroundStyle(.primary)
            }
            .frame(width: 32, height: 15)
            RoundedRectangle(cornerRadius: 1)
                .fill(.primary.opacity(0.4))
                .frame(width: 1.5, height: 5)
        }
        .accessibilityElement()
        .accessibilityLabel(charging ? "Battery \(level)%, charging" : "Battery \(level)%")
    }
}
