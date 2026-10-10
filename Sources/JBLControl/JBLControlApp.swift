import SwiftUI

@main
struct JBLControlApp: App {
    @State private var speaker: SpeakerManager
    @AppStorage(Pref.showBatteryInMenuBar) private var showBattery = false

    init() {
        Pref.registerDefaults()
        let speaker = SpeakerManager()
        _speaker = State(initialValue: speaker)
        SnapshotMode.runIfRequested(speaker)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            UpdateChecker.shared.checkAutomaticallyIfDue()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(speaker)
        } label: {
            Image(systemName: speaker.status == .connected ? "hifispeaker.fill" : "hifispeaker")
            if showBattery, speaker.status == .connected, let level = speaker.battery {
                Text("\(level)%")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(speaker)
        }
    }
}
