import AppKit
import JBLControlKit
import SwiftUI

struct PanelView: View {
    @Environment(SpeakerManager.self) private var speaker
    @State private var toast: String?

    private var ready: Bool { speaker.status == .connected && speaker.eq != nil }
    /// Several speakers nearby, or none connected (e.g. auto-connect is off): offer the choice.
    private var showSwitcher: Bool {
        speaker.switchable.count > 1 || (speaker.activeID == nil && !speaker.switchable.isEmpty)
    }

    var body: some View {
        VStack(spacing: 14) {
            if showSwitcher {
                SpeakerSwitcher()
                    .transition(.opacity)
            }
            HeaderView()
            if let model = speaker.model, model.hasEQ {
                if model.pickerPresets.count > 1 {
                    PresetPicker().disabled(!ready || !speaker.canWrite)
                }
                // Presets are fixed tunings; the equalizer only appears for Custom, so the panel
                // stays compact otherwise. Models without presets always show it.
                if speaker.isCustomActive || model.pickerPresets.count <= 1 {
                    EqualizerView()
                        .disabled(!ready)
                        .transition(.opacity)
                }
            } else if speaker.status == .connected {
                NoEQNotice()
            }
            FooterView(toast: $toast)
        }
        .padding(16)
        .frame(width: 360)
        // A fixed (ideal) height lets the menu bar window shrink back when the equalizer
        // hides; without it the window keeps its larger size and shows blank space.
        .fixedSize(horizontal: false, vertical: true)
        .background(alignment: .top) { ambientGlow }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .adaptiveGlass(.regular, in: .capsule)
                    .padding(.bottom, 56)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.smooth, value: toast)
        .animation(.smooth, value: showSwitcher)
        .animation(.smooth(duration: 0.3), value: speaker.isCustomActive)
        .tint(Theme.accent)

    }

    /// Soft sunset wash behind the glass, so the glass has something to refract.
    private var ambientGlow: some View {
        LinearGradient(
            colors: [Theme.start.opacity(0.38), Theme.end.opacity(0.16), .clear],
            startPoint: .topLeading, endPoint: .bottom
        )
        .blur(radius: 30)
        .ignoresSafeArea()
    }
}

struct NoEQNotice: View {
    @Environment(SpeakerManager.self) private var speaker

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "questionmark.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(speaker.model == nil ? "This speaker isn't in the catalog yet." : "JBL's app has no EQ for this model.")
                .font(.callout.weight(.medium))
            Text("Copy Diagnostics from the ••• menu and open an issue to help add support.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .adaptiveGlass(.regular, in: .rect(cornerRadius: 22))
    }
}

struct FooterView: View {
    @Environment(SpeakerManager.self) private var speaker
    @Binding var toast: String?

    var body: some View {
        HStack(spacing: 8) {
            if let firmware = speaker.firmware {
                Label("Firmware \(firmware)", systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // A SwiftUI Menu under a glass effect doesn't open inside a MenuBarExtra panel,
            // so this pops a plain NSMenu at the pointer instead.
            Button {
                MoreMenu.show(speaker, openSettings: {
                    SettingsWindowController.shared.show(speaker)
                }) { message in
                    toast = message
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        toast = nil
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .adaptiveGlass(.interactive, in: .circle)
            // It's the first focusable control; without this, macOS 14–15 draws a focus ring around it.
            .focusEffectDisabled()
            .help("More")
        }
    }
}

@MainActor
enum MoreMenu {
    static func show(_ speaker: SpeakerManager, openSettings: @escaping () -> Void, toast: @escaping (String) -> Void) {
        let menu = NSMenu()
        menu.addItem(ActionItem("Settings…", symbol: "gearshape", key: ",") { openSettings() })

        menu.addItem(.separator())
        menu.addItem(ActionItem("Copy Diagnostics", symbol: "stethoscope") {
            Task {
                await Diagnostics.copyReport(speaker)
                toast("Diagnostics copied")
            }
        })
        menu.addItem(ActionItem("Report an Issue…", symbol: "exclamationmark.bubble") {
            NSWorkspace.shared.open(AppInfo.issuesURL)
        })

        menu.addItem(.separator())
        menu.addItem(ActionItem("About \(AppInfo.name)", symbol: "info.circle") { AppInfo.showAboutPanel() })
        menu.addItem(ActionItem("Quit \(AppInfo.name)", symbol: "power", key: "q") { NSApp.terminate(nil) })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// NSMenuItem that runs a closure.
    final class ActionItem: NSMenuItem {
        private let handler: () -> Void

        init(_ title: String, symbol: String, key: String = "", handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(run), keyEquivalent: key)
            target = self
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }

        required init(coder: NSCoder) { fatalError("not used") }

        @objc private func run() { handler() }
    }
}
