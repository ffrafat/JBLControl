import SwiftUI

/// Volume slider and mute button for the speaker, while it's one of this Mac's sound outputs.
/// `SpeakerControls` keeps `volume` current and only shows this when there's a device.
struct VolumeRow: View {
    let volume: SpeakerVolume

    var body: some View {
        HStack(spacing: 10) {
            Button {
                volume.setMuted(!volume.isMuted)
            } label: {
                Image(systemName: symbol)
                    .font(.body.weight(.medium))
                    .frame(width: 22)
                    .contentTransition(.symbolEffect(.replace))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(volume.isMuted ? "Unmute" : "Mute")

            Slider(value: Binding(get: { Double(volume.isMuted ? 0 : volume.level) },
                                  set: { volume.setLevel(Float($0)) }),
                   in: 0...1) { volume.isEditing = $0 }
                .controlSize(.small)
                .accessibilityLabel("Volume")

            Text("\(Int(((volume.isMuted ? 0 : volume.level) * 100).rounded()))%")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .adaptiveGlass(.regular, in: .capsule)
    }

    private var symbol: String {
        if volume.isMuted || volume.level == 0 { return "speaker.slash.fill" }
        return volume.level < 0.34 ? "speaker.wave.1.fill" : volume.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}
