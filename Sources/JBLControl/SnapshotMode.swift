import AppKit
import JBLControlKit
import SwiftUI

/// Development aid: `JBLControl --snapshot out.png [--select <category hex>] [--appearance dark|light]`
/// connects, optionally selects a preset, renders the panel to a PNG and quits.
@MainActor
enum SnapshotMode {
    static func runIfRequested(_ speaker: SpeakerManager) {
        let args = CommandLine.arguments
        guard let path = value(after: "--snapshot", in: args) else { return }
        let select = value(after: "--select", in: args).flatMap { UInt8($0, radix: 16) }
        let appearance = value(after: "--appearance", in: args)

        Task { @MainActor in
            for _ in 0..<40 where speaker.eq == nil { try? await Task.sleep(for: .milliseconds(250)) }
            if let select, let preset = speaker.model?.pickerPresets.first(where: { $0.category == select }) {
                speaker.select(preset)
                try? await Task.sleep(for: .seconds(1.5))
            }
            let host = NSHostingView(rootView: PanelView().environment(speaker))
            if let wait = value(after: "--wait", in: args).flatMap(Double.init) {
                speaker.panelOpened()
                try? await Task.sleep(for: .seconds(wait))
                print("discovered=\(speaker.discovered.map { "\($0.name)@\($0.id.uuidString.prefix(8))" }) "
                    + "switchable=\(speaker.switchable.count) active=\(speaker.activeID?.uuidString.prefix(8) ?? "-")")
            }
            if let appearance { host.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua) }
            let size = host.fittingSize
            let window = NSPanel(contentRect: NSRect(origin: CGPoint(x: 40, y: 40), size: size),
                                 styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            let background = NSVisualEffectView()
            background.material = .popover
            background.state = .active
            background.addSubview(host)
            host.frame = NSRect(origin: .zero, size: size)
            window.contentView = background
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(1))

            let view = window.contentView!
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            print("status=\(speaker.status) model=\(speaker.model?.name ?? "-") battery=\(speaker.battery ?? -1) "
                + "preset=\(speaker.activePreset?.name ?? "-") custom=\(speaker.customGains) firmware=\(speaker.firmware ?? "-")")
            if CommandLine.arguments.contains("--diagnostics") {
                await speaker.runDiagnosticProbe()
                print(Diagnostics.build(speaker))
            }
            exit(0)
        }
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
}
