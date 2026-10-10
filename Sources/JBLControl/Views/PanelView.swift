import AppKit
import JBLControlKit
import SwiftUI

struct PanelView: View {
    @Environment(SpeakerManager.self) private var speaker
    @State private var toast: String?

    private var ready: Bool { speaker.status == .connected && speaker.eq != nil }

    var body: some View {
        VStack(spacing: 14) {
            if speaker.switchable.count > 1 {
                SpeakerSwitcher()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HeaderView()
            if let model = speaker.model, model.hasEQ {
                if model.pickerPresets.count > 1 {
                    PresetPicker().disabled(!ready || !speaker.canWrite)
                }
                EqualizerView().disabled(!ready)
            } else if speaker.status == .connected {
                NoEQNotice()
            }
            FooterView(toast: $toast)
        }
        .padding(16)
        .frame(width: 360)
        .background(alignment: .top) { ambientGlow }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 56)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.smooth, value: toast)
        .animation(.smooth, value: speaker.switchable.count > 1)
        .tint(Theme.accent)
        .onAppear { speaker.panelOpened() }
        .onDisappear { speaker.panelClosed() }
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
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
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
                MoreMenu.show(speaker) { message in
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
            .glassEffect(.regular.interactive(), in: .circle)
            .help("More")
        }
    }
}

@MainActor
enum MoreMenu {
    static func show(_ speaker: SpeakerManager, toast: @escaping (String) -> Void) {
        let menu = NSMenu()
        menu.addItem(ActionItem("Refresh", symbol: "arrow.clockwise") { speaker.refresh() })

        let speakers = NSMenu()
        for s in speaker.discovered.sorted(by: { $0.rssi > $1.rssi }) {
            let label = s.model.map { "\(s.name) — \($0.shortName)" } ?? "\(s.name) — unknown model"
            let item = ActionItem(label, symbol: "hifispeaker") { speaker.choose(s) }
            item.state = s.id == speaker.connectedID ? .on : .off
            item.isEnabled = s.model?.support != .unsupported
            speakers.addItem(item)
        }
        if speakers.items.isEmpty {
            speakers.addItem(NSMenuItem(title: "No JBL speakers found", action: nil, keyEquivalent: ""))
        }
        speakers.addItem(.separator())
        speakers.addItem(ActionItem("Forget Speaker", symbol: "xmark.circle") { speaker.forgetSpeaker() })
        let speakersItem = NSMenuItem(title: "Speakers", action: nil, keyEquivalent: "")
        speakersItem.image = NSImage(systemSymbolName: "hifispeaker.2", accessibilityDescription: nil)
        speakersItem.submenu = speakers
        menu.addItem(speakersItem)

        menu.addItem(.separator())
        let experimental = ActionItem("Allow Experimental EQ", symbol: "flask") {
            speaker.allowExperimentalWrites.toggle()
        }
        experimental.state = speaker.allowExperimentalWrites ? .on : .off
        experimental.toolTip = "Let EQ changes through on models that haven't been confirmed on hardware."
        menu.addItem(experimental)
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
        menu.addItem(ActionItem("View on GitHub", symbol: "safari") { NSWorkspace.shared.open(AppInfo.repositoryURL) })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit JBLControl", symbol: "power", key: "q") { NSApp.terminate(nil) })
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
