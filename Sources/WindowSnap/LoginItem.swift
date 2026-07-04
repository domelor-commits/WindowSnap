import Cocoa
import ServiceManagement

/// Launch-at-login using SMAppService (macOS 13+). On macOS 12 this degrades
/// gracefully to a no-op with a note in the UI.
enum LoginItem {
    static var isAvailable: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    static func setEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("LoginItem error: \(error.localizedDescription)")
        }
    }

    static func isEnabled() -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }
}
