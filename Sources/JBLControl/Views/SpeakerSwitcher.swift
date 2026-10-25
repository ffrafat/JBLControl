import JBLControlKit
import SwiftUI

/// One chip per nearby JBL speaker; shown when there's more than one to choose from.
struct SpeakerSwitcher: View {
    @Environment(SpeakerManager.self) private var speaker
    @Namespace private var glass

    var body: some View {
        // Centered when the chips fit; scrolls sideways when there are many.
        ViewThatFits(in: .horizontal) {
            chips
            ScrollView(.horizontal, showsIndicators: false) { chips }
                .scrollClipDisabled()
        }
    }

    private var chips: some View {
            AdaptiveGlassContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(speaker.switchable) { s in
                        let active = s.id == speaker.activeID
                        Button {
                            withAnimation(.smooth(duration: 0.3)) { speaker.choose(s) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: SpeakerLabel.symbol(s.model?.formFactor))
                                    .font(.system(size: 11, weight: .semibold))
                                Text(SpeakerLabel.name(s))
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
                        .adaptiveGlass(active ? .tinted(Theme.accent) : .interactive, in: .capsule)
                        .adaptiveGlassID(s.id, in: glass)
                        .help(s.model.map { "\(s.name) — \($0.name)" } ?? s.name)
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
    }

}

/// How a nearby speaker is named and drawn in the switcher chips and the main window's sidebar.
enum SpeakerLabel {
    /// Advertised names are truncated ("FFR JBL Fli"); fall back to the model name when that reads better.
    static func name(_ s: DiscoveredSpeaker) -> String {
        guard let model = s.model else { return s.name }
        let name = s.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty || model.name.hasPrefix(name) ? model.shortName : name
    }

    static func symbol(_ form: FormFactor?) -> String {
        switch form {
        case .compact: "speaker.fill"
        case .boombox: "hifispeaker.2.fill"
        default: "hifispeaker.fill"
        }
    }
}
