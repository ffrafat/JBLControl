import SwiftUI

@main
struct JBLControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar item, panel and Settings window are AppKit-managed (see AppDelegate);
        // SwiftUI needs at least one scene.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let speaker: SpeakerManager
    private var keepAwake: KeepAwake?
    private var statusBar: StatusBarController?

    override init() {
        Pref.registerDefaults()
        speaker = SpeakerManager()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let keepAwake = KeepAwake(speaker: speaker)
        self.keepAwake = keepAwake
        SnapshotMode.runIfRequested(speaker, keepAwake: keepAwake)
        statusBar = StatusBarController(speaker: speaker, keepAwake: keepAwake)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            UpdateChecker.shared.checkAutomaticallyIfDue()
        }
    }
}
