import SwiftUI

/// Volume slider and mute button for the speaker, while it's one of this Mac's sound outputs.
struct VolumeRow: View {
    @Environment(SpeakerManager.self) private var speaker
    @State private var volume = SpeakerVolume()
    @State private var editing = false

    var body: some View {
        Group {
            if volume.device != nil {
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
                           in: 0...1) { editing = $0 }
                        .controlSize(.small)
                        .accessibilityLabel("Volume")

                    Text("\(Int((volume.isMuted ? 0 : volume.level) * 100))%")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .adaptiveGlass(.regular, in: .capsule)
                .transition(.opacity)
            }
        }
        // Volume also changes from the keyboard and Control Center, so keep it current while shown.
        .task(id: speaker.name) {
            while !Task.isCancelled {
                if !editing { volume.refresh(speakerName: speaker.name) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .animation(.smooth, value: volume.device != nil)
    }

    private var symbol: String {
        if volume.isMuted || volume.level == 0 { return "speaker.slash.fill" }
        return volume.level < 0.34 ? "speaker.wave.1.fill" : volume.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}
