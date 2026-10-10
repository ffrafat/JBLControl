import Foundation
import UserNotifications

/// UserDefaults keys for the Settings window.
enum Pref {
    static let autoConnect = "autoConnect"
    static let showBatteryInMenuBar = "showBatteryInMenuBar"
    static let lowBatteryAlert = "lowBatteryAlert"
    static let autoCheckUpdates = "autoCheckUpdates"
    static let allowExperimentalWrites = "allowExperimentalWrites"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoConnect: true,
            showBatteryInMenuBar: false,
            lowBatteryAlert: true,
            autoCheckUpdates: true,
            allowExperimentalWrites: false,
        ])
    }
}

enum Notifier {
    static let lowBatteryThreshold = 20

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func lowBattery(speaker: String, level: Int) {
        Task {
            guard await requestAuthorization() else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(speaker) battery low"
            content.body = "\(level)% left. Time to plug it in."
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "lowBattery", content: content, trigger: nil))
        }
    }
}
