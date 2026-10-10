import JBLControlKit
import SwiftUI

/// One chip per nearby JBL speaker; shown when there's more than one to choose from.
struct SpeakerSwitcher: View {
    @Environment(SpeakerManager.self) private var speaker
    @Namespace private var glass

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(speaker.switchable) { s in
                        let active = s.id == speaker.activeID
                        Button {
                            withAnimation(.smooth(duration: 0.3)) { speaker.choose(s) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: symbol(s.model?.formFactor))
                                    .font(.system(size: 11, weight: .semibold))
                                Text(label(s))
                                    .font(.caption.weight(active ? .semibold : .medium))
                                    .lineLimit(1)
                                if active && speaker.status != .connected {
                                    ProgressView().controlSize(.mini)
                                }
                            }
                            .foregroundStyle(active ? .white : .primary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(active ? .regular.tint(Theme.accent).interactive() : .regular.interactive(), in: .capsule)
                        .glassEffectID(s.id, in: glass)
                        .help(s.model.map { "\(s.name) — \($0.name)" } ?? s.name)
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .scrollClipDisabled()
    }

    /// Advertised names are truncated ("FFR JBL Fli"); fall back to the model name when that reads better.
    private func label(_ s: DiscoveredSpeaker) -> String {
        guard let model = s.model else { return s.name }
        let name = s.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty || model.name.hasPrefix(name) ? model.shortName : name
    }

    private func symbol(_ form: FormFactor?) -> String {
        switch form {
        case .compact: "speaker.fill"
        case .boombox: "hifispeaker.2.fill"
        default: "hifispeaker.fill"
        }
    }
}
