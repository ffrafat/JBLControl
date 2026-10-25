import AppKit
import Observation
import SwiftUI

/// The main window: every nearby speaker in the sidebar, the connected one in full, Settings and
/// About. Closing it leaves the app in the menu bar. While it's open JBLControl is a regular app
/// (Dock icon, menus, ⌘-Tab); otherwise it stays menu bar only. (MainWindow on Windows.)
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    enum Page: Hashable { case speakers, settings, about }

    private let speaker: SpeakerManager
    private let keepAwake: KeepAwake
    private let navigation = MainNavigation()
    private var window: NSWindow?
    private var shown = false

    init(speaker: SpeakerManager, keepAwake: KeepAwake) {
        self.speaker = speaker
        self.keepAwake = keepAwake
        super.init()
    }

    /// Opens (or brings forward) the window on the given page.
    func show(_ page: Page = .speakers) {
        navigation.page = page
        let window = self.window ?? makeWindow()
        self.window = window
        if !shown {
            shown = true
            speaker.panelOpened()  // keep scanning so the list stays current
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: MainWindowView()
            .environment(speaker).environment(keepAwake).environment(navigation))
        // The sidebar toggle and page title go into the window's toolbar.
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.title = AppInfo.name
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 1000, height: 720))
        window.center()
        window.setFrameAutosaveName("MainWindow")
        return window
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard shown else { return }
        shown = false
        speaker.panelClosed()
        // Back to menu bar only: no Dock icon while the window is closed.
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Which page the main window shows; the sidebar's selection follows it.
@MainActor @Observable
final class MainNavigation {
    var page: MainWindowController.Page = .speakers
}

/// The app's menus, shown while the main window makes JBLControl a regular app.
@MainActor
enum MainMenu {
    static func make(open: @escaping (MainWindowController.Page) -> Void) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: AppInfo.name)
        app.addItem(item("About \(AppInfo.name)") { AppInfo.showAboutPanel() })
        app.addItem(.separator())
        app.addItem(item("Settings…", key: ",") { open(.settings) })
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(AppInfo.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main)

        // Copy and Select All work on the speaker details, which are selectable text.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(window, to: main)
        NSApp.windowsMenu = window

        return main
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }

    private static func item(_ title: String, key: String = "", handler: @escaping () -> Void) -> NSMenuItem {
        MoreMenu.ActionItem(title, symbol: nil, key: key, handler: handler)
    }
}
