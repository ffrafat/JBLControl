import AppKit
import JBLControlKit
import SwiftUI

/// The main window's content: nearby speakers, Settings and About in the sidebar; the selected page beside it.
struct MainWindowView: View {
    @Environment(MainNavigation.self) private var navigation

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            switch navigation.page {
            case .speakers: SpeakerPage()
            case .settings: SettingsPage()
            case .about: AboutPage()
            }
        }
        // Below this the sidebar and the speaker no longer fit side by side.
        .frame(minWidth: 760, minHeight: 520)
        .tint(Theme.accent)
    }
}

// MARK: - Sidebar

private enum SidebarItem: Hashable {
    case speaker(UUID)
    case settings
    case about
}

/// One sidebar row: a nearby speaker, or the connected one.
private struct SidebarSpeaker: Identifiable {
    let id: UUID
    let name: String
    let model: SpeakerModel?
    /// The speaker found nearby, to connect to; nil for the connected one when it isn't advertising.
    let discovered: DiscoveredSpeaker?
}

private struct Sidebar: View {
    @Environment(SpeakerManager.self) private var speaker
    @Environment(MainNavigation.self) private var navigation

    var body: some View {
        List(selection: selection) {
            Section("Speakers") {
                if rows.isEmpty {
                    Label(speaker.status == .bluetoothOff ? "Bluetooth is off" : "Looking for speakers…",
                          systemImage: speaker.status == .bluetoothOff ? "bolt.horizontal.circle" : "dot.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(rows) { row in
                    SpeakerRow(row: row, isActive: row.id == speaker.activeID)
                        .tag(SidebarItem.speaker(row.id))
                }
            }
            Section {
                Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
                Label("About", systemImage: "info.circle").tag(SidebarItem.about)
            }
        }
        .animation(.smooth, value: rows.map(\.id))
    }

    /// Every supported speaker nearby (SpeakerSwitcher in the panel), the active one first.
    private var rows: [SidebarSpeaker] {
        var list = speaker.switchable.map { SidebarSpeaker(id: $0.id, name: SpeakerLabel.name($0), model: $0.model, discovered: $0) }
        if let active = speaker.activeID, speaker.status == .connected, !list.contains(where: { $0.id == active }) {
            list.append(SidebarSpeaker(id: active, name: speaker.name ?? "", model: speaker.model, discovered: nil))
        }
        return list.filter { $0.id == speaker.activeID } + list.filter { $0.id != speaker.activeID }
    }

    /// Follows the page; on the speaker page, the speaker being controlled. Picking another speaker switches to it.
    private var selection: Binding<SidebarItem?> {
        Binding {
            switch navigation.page {
            case .settings: .settings
            case .about: .about
            case .speakers: speaker.activeID.map(SidebarItem.speaker)
            }
        } set: { item in
            switch item {
            case .settings: navigation.page = .settings
            case .about: navigation.page = .about
            case .speaker(let id):
                if id != speaker.activeID, let s = rows.first(where: { $0.id == id })?.discovered {
                    withAnimation(.smooth(duration: 0.3)) { speaker.choose(s) }
                }
                navigation.page = .speakers
            case nil: break
            }
        }
    }
}

private struct SpeakerRow: View {
    @Environment(SpeakerManager.self) private var speaker
    let row: SidebarSpeaker
    let isActive: Bool

    var body: some View {
        // A Label, so the icon takes the sidebar's tint and turns white on the selected row like Settings and About.
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)
                Text("\(row.model?.shortName ?? "Unknown model") · \(state)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: SpeakerLabel.symbol(row.model?.formFactor))
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .padding(.vertical, 3)
        .help(isActive ? "\(name) — \(state)" : "Connect to \(name)")
        .accessibilityElement(children: .combine)
    }

    private var name: String {
        isActive ? speaker.name ?? row.name : row.name
    }

    private var state: String {
        guard isActive else { return "Nearby" }
        guard speaker.status == .connected else { return "Connecting…" }
        guard let battery = speaker.battery else { return "Connected" }
        return "Connected · \(battery)%\(speaker.isCharging ? ", charging" : "")"
    }
}

// MARK: - Speaker

/// The connected speaker in full: what the panel shows, larger, plus its details and actions.
private struct SpeakerPage: View {
    @Environment(SpeakerManager.self) private var speaker

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SpeakerControls(showsSwitcher: false, artworkSize: 150)
                if speaker.status == .connected {
                    DetailsSection()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.smooth(duration: 0.3), value: speaker.status == .connected)
        }
        .background(alignment: .top) { ambientGlow }
        .navigationTitle(speaker.status == .connected ? speaker.name ?? AppInfo.name : AppInfo.name)
    }

    /// The panel's sunset wash, so the glass has something to refract here too.
    private var ambientGlow: some View {
        LinearGradient(colors: [Theme.start.opacity(0.22), Theme.end.opacity(0.08), .clear],
                       startPoint: .topLeading, endPoint: .bottom)
            .frame(height: 360)
            .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
            .blur(radius: 40)
            .ignoresSafeArea()
    }
}

/// Everything the speaker reports, plus the actions the panel keeps in its ••• menu.
private struct DetailsSection: View {
    @Environment(SpeakerManager.self) private var speaker
    @Environment(KeepAwake.self) private var keepAwake
    @State private var copied = false

    var body: some View {
        @Bindable var keepAwake = keepAwake
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                ForEach(facts, id: \.label) { fact in
                    GridRow {
                        Text(fact.label)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        Text(fact.value)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .adaptiveGlass(.regular, in: .rect(cornerRadius: 18))

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep speaker awake")
                    Text(awakeDetail)
                        .font(.caption)
                        .foregroundStyle(keepAwake.state == .waitingForOutput ? .orange : .secondary)
                }
                Spacer()
                Toggle("Keep speaker awake", isOn: $keepAwake.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(16)
            .adaptiveGlass(.regular, in: .rect(cornerRadius: 18))

            if speaker.supportsAuracast {
                AuracastCard()
            }

            HStack(spacing: 8) {
                Button("Refresh", systemImage: "arrow.clockwise") { speaker.refresh() }
                Button(copied ? "Copied" : "Copy Diagnostics", systemImage: copied ? "checkmark" : "stethoscope") {
                    Task {
                        await Diagnostics.copyReport(speaker)
                        copied = true
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                Button("Report an Issue", systemImage: "exclamationmark.bubble") {
                    NSWorkspace.shared.open(AppInfo.issuesURL)
                }
            }
            .adaptiveGlassButtonStyle()
            .tint(nil)
            .padding(.top, 2)
        }
    }

    private var facts: [(label: String, value: String)] {
        let model = speaker.model
        let rows: [(String, String?)] = [
            ("Name", speaker.name),
            ("Model", model?.name ?? speaker.productID.map { String(format: "Unknown (%04X)", $0) }),
            ("Color", model.flatMap { m in speaker.colorCode.map { m.color($0).name } }),
            ("Battery", speaker.battery.map { "\($0)%\(speaker.isCharging ? ", charging" : "")" }),
            ("Firmware", speaker.firmware),
            ("Product ID", speaker.productID.map { String(format: "%04X", $0) }),
            // Only worth a line when there's a caveat.
            ("Support", {
                switch model?.support {
                case .beta: "Beta: reading works; EQ changes untested"
                case .experimental: "Experimental: please send a diagnostics report"
                case .unsupported: "Unsupported over Bluetooth LE"
                default: nil
                }
            }()),
        ]
        return rows.compactMap { label, value in value.map { (label, $0) } }
    }

    private var awakeDetail: String {
        switch keepAwake.state {
        case .active: "Keeping the speaker awake."
        case .waitingForOutput: "Waiting: choose this speaker as your Mac's sound output (Control Center → Sound)."
        case .off: "Stops the speaker's auto power-off while it's your Mac's sound output."
        }
    }
}

/// The Auracast card: the link mode plus this unit's half of the stereo pair.
///
/// It drives the same two commands JBL's app uses: `AA 6A` for the broadcast mode and
/// `AA 15 03 00 46 <0|1|2>` for left/right. It cannot create the pair by itself: two Go 4s
/// join on the speakers (press Auracast on both), then each unit is assigned its half here.
private struct AuracastCard: View {
    @Environment(SpeakerManager.self) private var speaker

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(Theme.accent)
                Text("Auracast")
                    .font(.headline)
                Spacer()
                if speaker.isAuracastOn, let role = speaker.role {
                    Text(role.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Toggle("Auracast", isOn: Binding(get: { speaker.isAuracastOn },
                                                 set: { speaker.setAuracast($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!speaker.canWrite)
            }

            if speaker.model?.stereoIsAutomatic == true {
                Text("Left and right are set by AirTouch: bump the two speakers together. "
                    + "This unit reports \(speaker.stereoChannel?.label.lowercased() ?? "no channel").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if speaker.canSetChannel {
                Picker("Channel", selection: Binding(get: { speaker.stereoChannel ?? .mono },
                                                     set: { speaker.setChannel($0) })) {
                    ForEach(AudioChannel.allCases, id: \.self) { channel in
                        Text(channel.label).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!speaker.canWrite)

                HStack(spacing: 8) {
                    Text(channelDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let other = speaker.otherUnit {
                        Button("Connect to the other " + (speaker.model?.shortName ?? "speaker")) {
                            speaker.choose(other)
                        }
                        .font(.caption.weight(.semibold))
                        .adaptiveGlassButtonStyle()
                        .controlSize(.small)
                    }
                    Button("Swap") { speaker.swapChannel() }
                        .font(.caption.weight(.semibold))
                        .adaptiveGlassButtonStyle()
                        .controlSize(.small)
                        .disabled((speaker.stereoChannel ?? .mono) == .mono || !speaker.canWrite)
                }
            } else {
                Text("This speaker doesn't expose a stereo channel control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .adaptiveGlass(.regular, in: .rect(cornerRadius: 18))
    }

    private var channelDetail: String {
        switch speaker.stereoChannel {
        case .left, .right:
            return "This unit plays the \(speaker.stereoChannel?.label.lowercased() ?? "") channel. Set the other unit to the opposite one."
        default:
            return "Mono: both units play the same mix. Set one unit to Left and the other to Right for stereo."
        }
    }

    private var hint: String {
        if !speaker.canWrite {
            return "Auracast changes are off for this model until someone confirms them on the speaker. Enable experimental controls in Settings."
        }
        if !speaker.isAuracastOn {
            return "Turn Auracast on for both speakers. The unit connected to this Mac broadcasts; press Auracast on the other so it receives."
        }
        if speaker.auracastGroup?.isStereo == true {
            let id = speaker.auracastGroup?.groupIDHex.map { " (\($0))" } ?? ""
            return "Stereo group\(id) is active. Left and right are split across the two units."
        }
        return "Pairing happens on the speakers: press Auracast on the second unit and wait for it to join, then choose this unit's channel."
    }
}

// MARK: - Settings and About

/// The Settings window's sections, on one page.
private struct SettingsPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                section("General") { GeneralSettings() }
                section("Speaker") { SpeakerSettings() }
                section("Updates") { UpdateSettings() }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Settings")
    }

    private func section<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 12)
            content()
                // One continuous page rather than a band of background behind each form.
                .scrollContentBackground(.hidden)
        }
    }
}

private struct AboutPage: View {
    var body: some View {
        ScrollView {
            AboutSettings()
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        }
        .navigationTitle("About")
    }
}
