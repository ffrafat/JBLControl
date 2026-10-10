import AppKit
import JBLControlKit
import SwiftUI

struct SettingsView: View {
    enum Tab: Hashable { case general, speaker, updates, about }
    @State private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            SpeakerSettings()
                .tabItem { Label("Speaker", systemImage: "hifispeaker") }
                .tag(Tab.speaker)
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                .tag(Tab.updates)
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .tint(Theme.accent)
        .frame(width: 480)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @State private var loginItem = LoginItem()
    @AppStorage(Pref.showBatteryInMenuBar) private var showBattery = false
    @AppStorage(Pref.lowBatteryAlert) private var lowBatteryAlert = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) })) {
                    Text("Launch at login")
                    Text("Start JBLControl when you log in to your Mac.")
                }
                if loginItem.needsApproval {
                    LabeledContent("Waiting for your approval in Login Items.") {
                        Button("Open Login Items") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        }
                    }
                    .font(.caption)
                }
                if let error = loginItem.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Menu bar") {
                Toggle(isOn: $showBattery) {
                    Text("Show battery percentage")
                    Text("Next to the speaker icon while connected.")
                }
            }
            Section("Notifications") {
                Toggle(isOn: $lowBatteryAlert) {
                    Text("Low battery alert")
                    Text("Notify when the speaker drops to \(Notifier.lowBatteryThreshold)%.")
                }
                .onChange(of: lowBatteryAlert) { _, on in
                    if on { Task { _ = await Notifier.requestAuthorization() } }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loginItem.refresh() }
    }
}

// MARK: - Speaker

private struct SpeakerSettings: View {
    @Environment(SpeakerManager.self) private var speaker
    @AppStorage(Pref.autoConnect) private var autoConnect = true
    @State private var confirmForget = false

    var body: some View {
        @Bindable var speaker = speaker
        Form {
            Section {
                SpeakerCard()
            }
            Section("Connection") {
                Toggle(isOn: $autoConnect) {
                    Text("Connect automatically")
                    Text(autoConnect
                         ? "Reconnects to your speaker whenever it's nearby."
                         : "Pick a speaker in the panel to connect.")
                }
                LabeledContent {
                    Button("Forget…", role: .destructive) { confirmForget = true }
                        .disabled(speaker.activeID == nil)
                } label: {
                    Text("Forget this speaker")
                    Text("Disconnect and stop reconnecting to it.")
                }
            }
            Section {
                Toggle(isOn: $speaker.allowExperimentalWrites) {
                    Text("Allow experimental EQ")
                    Text("Lets EQ changes through on models not yet confirmed on real hardware.")
                }
            } header: {
                Text("Equalizer")
            } footer: {
                if let model = speaker.model, model.support != .verified {
                    Text("\(model.name) is \(model.support.label.lowercased()). A device report helps get it verified.")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Forget \(speaker.name ?? "this speaker")?", isPresented: $confirmForget) {
            Button("Forget Speaker", role: .destructive) { speaker.forgetSpeaker() }
        } message: {
            Text("JBLControl will disconnect and won't reconnect to it automatically.")
        }
    }
}

private struct SpeakerCard: View {
    @Environment(SpeakerManager.self) private var speaker

    var body: some View {
        HStack(spacing: 14) {
            SpeakerArtwork(model: speaker.model, colorCode: speaker.colorCode)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(speaker.name ?? speaker.model?.name ?? "No speaker connected")
                        .font(.headline)
                    if let model = speaker.model {
                        SupportBadge(level: model.support)
                    }
                }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var details: String {
        guard speaker.status == .connected else {
            return speaker.activeID == nil ? "Turn a JBL speaker on nearby." : "Connecting…"
        }
        var parts = [speaker.model?.name ?? "Unknown model"]
        if let battery = speaker.battery { parts.append("\(battery)% battery") }
        if let firmware = speaker.firmware { parts.append("Firmware \(firmware)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Updates

private struct UpdateSettings: View {
    @State private var updates = UpdateChecker.shared
    @AppStorage(Pref.autoCheckUpdates) private var autoCheck = true

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Check Now") { Task { await updates.check(userInitiated: true) } }
                        .disabled(updates.state == .checking)
                } label: {
                    Text("\(AppInfo.name) \(AppInfo.version)")
                    Text(status)
                }
                if case .available(_, let url) = updates.state {
                    Link("Download from GitHub", destination: url)
                }
            }
            Section {
                Toggle(isOn: $autoCheck) {
                    Text("Check for updates automatically")
                    Text("Once a day, from GitHub Releases.")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var status: String {
        switch updates.state {
        case .idle: "Updates are published on GitHub."
        case .checking: "Checking…"
        case .upToDate: "You're on the latest version."
        case .available(let version, _): "Version \(version) is available."
        case .failed: "Couldn't reach GitHub."
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    @Environment(SpeakerManager.self) private var speaker
    @State private var copied = false

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text(AppInfo.name)
                    .font(.title2.weight(.semibold))
                Text("Version \(AppInfo.version) (\(AppInfo.build))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(AppInfo.tagline)
                    .font(.callout)
            }

            HStack(spacing: 10) {
                Link(destination: AppInfo.repositoryURL) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: AppInfo.issuesURL) {
                    Label("Report an Issue", systemImage: "exclamationmark.bubble")
                }
                Button {
                    Task {
                        await Diagnostics.copyReport(speaker)
                        copied = true
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy Diagnostics", systemImage: copied ? "checkmark" : "stethoscope")
                }
            }
            .buttonStyle(.glass)
            .tint(nil)
            .controlSize(.regular)

            VStack(spacing: 4) {
                Text("Built on protocol research by [openjbl](https://github.com/NiceDayZc/openjbl) and [jbl-charge5](https://github.com/hudsonbrendon/jbl-charge5).")
                Text("Unofficial. Not affiliated with or endorsed by JBL or Harman International.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}
