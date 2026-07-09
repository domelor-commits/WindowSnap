import Cocoa
import IOKit.pwr_mgt

/// Menu-bar "caffeine" toggle: holds an IOKit power assertion so the display
/// (and therefore the system) won't idle-sleep. Supports an indefinite hold or a
/// timed one that auto-releases. Never persisted and off at launch, so a crash
/// can't leave the Mac permanently awake.
final class KeepAwake {
    static let shared = KeepAwake()

    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?
    private(set) var isActive = false
    private(set) var expiry: Date?          // nil = indefinite (or inactive)

    /// Turn on. `duration` nil = indefinite; otherwise auto-release after it.
    func activate(duration: TimeInterval?) {
        deactivate()   // release any prior assertion/timer first
        let reason = "WindowSnap Keep Awake" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertionID)
        guard result == kIOReturnSuccess else {
            Logger.log("Keep Awake: failed to create power assertion")
            return
        }
        isActive = true
        if let d = duration {
            expiry = Date().addingTimeInterval(d)
            timer = Timer.scheduledTimer(withTimeInterval: d, repeats: false) { [weak self] _ in
                self?.deactivate()
                LayoutManager.notify("Keep Awake ended", "Your Mac can sleep normally again.")
            }
            Logger.log("Keep Awake: on for \(Int(d / 60)) min")
        } else {
            expiry = nil
            Logger.log("Keep Awake: on (indefinite)")
        }
        NotificationCenter.default.post(name: .windowSnapKeepAwakeChanged, object: nil)
    }

    func deactivate() {
        timer?.invalidate(); timer = nil
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
        expiry = nil
        Logger.log("Keep Awake: off")
        NotificationCenter.default.post(name: .windowSnapKeepAwakeChanged, object: nil)
    }

    func toggle() { isActive ? deactivate() : activate(duration: nil) }

    /// Short status for menu display, e.g. "1h 23m left" or "on".
    var statusDescription: String {
        guard isActive else { return "" }
        guard let e = expiry else { return "on" }
        let secs = max(0, Int(e.timeIntervalSinceNow))
        let h = secs / 3600, m = (secs % 3600) / 60
        return h > 0 ? "\(h)h \(m)m left" : "\(m)m left"
    }
}
