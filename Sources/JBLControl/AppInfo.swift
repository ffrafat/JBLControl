import AppKit
import SwiftUI

enum AppInfo {
    static let name = "JBLControl"
    static let tagline = "JBL speaker control, right in your menu bar."
    static let repositoryURL = URL(string: "https://github.com/ffrafat/JBLControl")!
    static let issuesURL = URL(string: "https://github.com/ffrafat/JBLControl/issues/new?template=device-report.yml")!

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    @MainActor
    static func showAboutPanel() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: center,
        ]
        let credits = NSMutableAttributedString(string: "\(tagline)\n\n", attributes: body)
        var link = body
        link[.link] = repositoryURL
        link[.foregroundColor] = NSColor.linkColor
        credits.append(NSAttributedString(string: "github.com/ffrafat/JBLControl", attributes: link))
        credits.append(NSAttributedString(
            string: "\n\nBuilt on protocol research by openjbl and jbl-charge5.\n"
                + "Unofficial. Not affiliated with or endorsed by JBL or Harman International.",
            attributes: body))

        // A menu bar app has no frontmost window; bring the panel forward.
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: name,
            .applicationVersion: version,
            .version: "Build \(build)",
            .credits: credits,
        ])
    }
}

/// Sunset orange, the same gradient as the app icon.
enum Theme {
    static let start = Color(.displayP3, red: 1.00, green: 0.58, blue: 0.16)
    static let end = Color(.displayP3, red: 0.90, green: 0.18, blue: 0.20)
    static let accent = Color(.displayP3, red: 0.98, green: 0.38, blue: 0.16)

    static var gradient: LinearGradient {
        LinearGradient(colors: [start, end], startPoint: .top, endPoint: .bottom)
    }
}
