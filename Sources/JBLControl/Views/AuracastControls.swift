import JBLControlKit
import SwiftUI

/// Compact Auracast + stereo-half controls for the menu bar panel.
///
/// The full explanation lives in the main window's card; the panel keeps it to
/// two rows so the preset picker stays the focus.
struct AuracastControls: View {
    @Environment(SpeakerManager.self) private var speaker

    private var channel: Binding<AudioChannel> {
        Binding(get: { speaker.stereoChannel ?? .mono }, set: { speaker.setChannel($0) })
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                Text("Auracast")
                    .font(.caption.weight(.semibold))
                if let badge = speaker.stereoChannel?.badge, speaker.isAuracastOn {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.18), in: .capsule)
                }
                Spacer(minLength: 8)
                Toggle("Auracast", isOn: Binding(get: { speaker.isAuracastOn },
                                                 set: { speaker.setAuracast($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(!speaker.canWrite)
            }

            if speaker.model?.stereoIsAutomatic == true {
                Text("Bump the two speakers together; AirTouch picks left and right.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if speaker.canSetChannel {
                Picker("Stereo channel", selection: channel) {
                    ForEach(AudioChannel.allCases, id: \.self) { channel in
                        Text(channel.label).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .disabled(!speaker.canWrite)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .adaptiveGlass(.regular, in: .rect(cornerRadius: 16))
    }
}
