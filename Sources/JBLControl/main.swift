import AppKit

// A plain AppKit app: the menu bar item, panel (SwiftUI in a popover) and main window are all
// AppKit-managed. Using SwiftUI's App lifecycle instead would require a placeholder scene, which
// macOS could open as an empty window (window restoration, or relaunching the app).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu bar only, no Dock icon (also LSUIElement); the main window makes it a regular app while it's open.
    app.setActivationPolicy(.accessory)
    app.run()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let speaker: SpeakerManager
    private var keepAwake: KeepAwake?
    private var statusBar: StatusBarController?
    private var mainWindow: MainWindowController?

    override init() {
        Pref.registerDefaults()
        speaker = SpeakerManager()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let keepAwake = KeepAwake(speaker: speaker)
        self.keepAwake = keepAwake
        let mainWindow = MainWindowController(speaker: speaker, keepAwake: keepAwake)
        self.mainWindow = mainWindow
        SnapshotMode.runIfRequested(speaker, keepAwake: keepAwake)
        statusBar = StatusBarController(speaker: speaker, keepAwake: keepAwake, mainWindow: mainWindow)
        NSApp.mainMenu = MainMenu.make { mainWindow.show($0) }
        // Started at login: straight to the menu bar, like the Windows app's --background.
        if !launchedAsLoginItem, !SnapshotMode.isRequested { mainWindow.show() }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            UpdateChecker.shared.checkAutomaticallyIfDue()
        }
    }

    /// Opening the app again (Dock, Launchpad, Spotlight, Finder) while it's running shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow?.show()
        return false
    }

    /// Whether the system opened the app as a login item (Launch at login), from the launch's "open app" event.
    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Nothing to restore: the app has no document windows.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
