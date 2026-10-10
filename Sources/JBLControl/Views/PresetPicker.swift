import JBLControlKit
import SwiftUI

struct PresetPicker: View {
    @Environment(SpeakerManager.self) private var speaker
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(speaker.model?.pickerPresets ?? []) { preset in
                    let selected = speaker.activePreset == preset
                    Button {
                        withAnimation(.smooth(duration: 0.3)) { speaker.select(preset) }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: preset.symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(height: 18)
                            Text(preset.name)
                                .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(selected ? .white : .primary)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .contentShape(.rect(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        selected ? .regular.tint(Theme.accent).interactive() : .regular.interactive(),
                        in: .rect(cornerRadius: 16)
                    )
                    .glassEffectID(preset.id, in: glass)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}
