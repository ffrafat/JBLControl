import SwiftUI

@main
struct JBLControlApp: App {
    @State private var speaker: SpeakerManager

    init() {
        let speaker = SpeakerManager()
        _speaker = State(initialValue: speaker)
        SnapshotMode.runIfRequested(speaker)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(speaker)
        } label: {
            Image(systemName: speaker.status == .connected ? "hifispeaker.fill" : "hifispeaker")
        }
        .menuBarExtraStyle(.window)
    }
}
