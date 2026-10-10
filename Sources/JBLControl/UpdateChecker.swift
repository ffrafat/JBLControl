import AppKit
import Observation

/// Checks GitHub Releases for a newer version (the app isn't on the App Store).
@MainActor @Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle, checking, upToDate, available(version: String, url: URL), failed
    }

    private(set) var state: State = .idle
    private static let lastCheckKey = "lastUpdateCheck"
    private let api = URL(string: "https://api.github.com/repos/ffrafat/JBLControl/releases/latest")!

    /// Once a day at most, when enabled in Settings.
    func checkAutomaticallyIfDue() {
        let d = UserDefaults.standard
        guard d.bool(forKey: Pref.autoCheckUpdates) else { return }
        if let last = d.object(forKey: Self.lastCheckKey) as? Date, Date.now.timeIntervalSince(last) < 86_400 { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        state = .checking
        UserDefaults.standard.set(Date.now, forKey: Self.lastCheckKey)
        do {
            var request = URLRequest(url: api)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            struct Release: Decodable { let tag_name: String; let html_url: URL }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if Self.isNewer(latest, than: AppInfo.version) {
                state = .available(version: latest, url: release.html_url)
                offer(version: latest, url: release.html_url)
            } else {
                state = .upToDate
                if userInitiated { alert("You're up to date", "\(AppInfo.name) \(AppInfo.version) is the latest version.") }
            }
        } catch {
            state = .failed
            if userInitiated { alert("Couldn't check for updates", error.localizedDescription) }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func offer(version: String, url: URL) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "\(AppInfo.name) \(version) is available"
        alert.informativeText = "You have \(AppInfo.version). Download the new version from GitHub and replace the app in Applications."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
