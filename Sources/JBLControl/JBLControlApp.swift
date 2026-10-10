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
            let battery = showBattery && speaker.status == .connected ? speaker.battery : nil
            Image(nsImage: MenuBarIcon.image(connected: speaker.status == .connected,
                                             battery: battery, charging: speaker.isCharging))
            if let battery {
                Text("\(battery)%")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(speaker)
        }
    }
}
