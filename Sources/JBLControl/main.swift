import AppKit

// A plain AppKit app: the menu bar item, panel (SwiftUI in a popover) and Settings window are all
// AppKit-managed. Using SwiftUI's App lifecycle instead would require a placeholder scene, which
// macOS could open as an empty window (window restoration, or relaunching the app).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon (also LSUIElement)
    app.run()
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

    /// Opening the app again (Launchpad, Spotlight, Finder) while it's running shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBar?.showPanel()
        return false
    }

    /// Nothing to restore: the app has no document windows.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
