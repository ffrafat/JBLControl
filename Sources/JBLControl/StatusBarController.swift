import AppKit
import Observation
import SwiftUI

/// The menu bar item and its popover. A popover (unlike SwiftUI's MenuBarExtra window) resizes
/// with its content in both directions, which the panel needs when the equalizer shows and hides.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let speaker: SpeakerManager
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    init(speaker: SpeakerManager) {
        self.speaker = speaker
        super.init()

        let host = NSHostingController(rootView: PanelView().environment(speaker))
        // The popover follows the panel's size as the equalizer appears and disappears.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        render()
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: NSPopoverDelegate

    func popoverWillShow(_ notification: Notification) { speaker.panelOpened() }
    func popoverDidClose(_ notification: Notification) { speaker.panelClosed() }

    // MARK: Menu bar icon

    @objc private func defaultsChanged() { render() }

    /// Redraws the icon, and re-arms itself whenever a speaker property it read changes.
    private func render() {
        withObservationTracking {
            let connected = speaker.status == .connected
            let showBattery = UserDefaults.standard.bool(forKey: Pref.showBatteryInMenuBar)
            let battery = showBattery && connected ? speaker.battery : nil
            item.button?.image = MenuBarIcon.image(connected: connected, battery: battery, charging: speaker.isCharging)
            item.button?.title = battery.map { " \($0)%" } ?? ""
            item.button?.toolTip = speaker.name ?? AppInfo.name
        } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
    }
}
