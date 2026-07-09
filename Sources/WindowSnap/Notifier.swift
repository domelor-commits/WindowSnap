import Foundation
import UserNotifications

/// Modern notification delivery via UserNotifications (`UNUserNotificationCenter`),
/// replacing the deprecated `NSUserNotification` which frequently fails to display
/// on current macOS — leaving the app's feedback (restore, sleep/wake, "Text
/// copied", etc.) silently invisible. Authorization is requested once at launch;
/// posts respect the user's choice thereafter.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// `UNUserNotificationCenter` requires a bundled, code-signed app; touching it
    /// from a loose executable traps. Guard on a bundle identifier so a dev run of
    /// the raw binary degrades to a no-op instead of crashing.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func setup() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                Logger.log("Notifications: auth error — \(error.localizedDescription)")
            } else if !granted {
                Logger.log("Notifications: not authorized — feedback will be silent")
            }
        }
    }

    func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // nil trigger = deliver immediately.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show the banner even while WindowSnap itself is the foreground app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }
}
