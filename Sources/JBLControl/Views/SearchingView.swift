import AppKit
import JBLControlKit
import SwiftUI

/// The compact panel shown while no speaker is connected: what's happening, what to do, and any
/// JBL speakers nearby to pick. No details from a previous speaker — a different one may connect.
struct SearchingView: View {
    @Environment(SpeakerManager.self) private var speaker
    /// Chips for the speakers nearby; the main window lists them in its sidebar instead.
    var showsNearby = true

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.variableColor.iterative, isActive: isLooking)
                .frame(height: 36)

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let action {
                Button(action.title) { NSWorkspace.shared.open(action.url) }
                    .adaptiveGlassButtonStyle()
                    .controlSize(.small)
            }

            if showsNearby, isLooking, !speaker.switchable.isEmpty {
                VStack(spacing: 6) {
                    Text("Nearby")
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    SpeakerSwitcher()
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 14)
        .adaptiveGlass(.regular, in: .rect(cornerRadius: 22))
    }

    private var isLooking: Bool { speaker.status == .searching || speaker.status == .connecting }

    private var symbol: String {
        switch speaker.status {
        case .bluetoothOff: "bolt.horizontal.circle"
        case .unauthorized: "lock.circle"
        default: "dot.radiowaves.left.and.right"
        }
    }

    private var title: String {
        switch speaker.status {
        case .bluetoothOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth access needed"
        // Without a recent sighting (it was pruned), the speaker is probably off: keep looking.
        case .connecting: speaker.connectingName.map { "Connecting to \($0)…" } ?? "Looking for JBL speakers…"
        default: "Looking for JBL speakers…"
        }
    }

    private var detail: String {
        switch speaker.status {
        case .bluetoothOff:
            "Turn Bluetooth on to connect to your speaker."
        case .unauthorized:
            "Allow JBLControl to use Bluetooth in System Settings."
        default:
            "Turn your speaker on nearby. If JBL Portable is open on your phone, close it — the speaker takes one control connection at a time."
        }
    }

    private var action: (title: String, url: URL)? {
        switch speaker.status {
        case .bluetoothOff:
            ("Open Bluetooth Settings", URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
        case .unauthorized:
            ("Open Privacy Settings", URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
        default:
            nil
        }
    }
}
