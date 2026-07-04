import Cocoa
import ApplicationServices
import CAXBridge

/// Wraps the Accessibility API to read and move the frontmost window.
enum WindowController {

    /// Returns the AXUIElement for the focused window of the frontmost app.
    static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var windowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard result == .success, let window = windowRef else { return nil }
        return (window as! AXUIElement)
    }

    static func setFrame(_ frame: CGRect, for window: AXUIElement) {
        var pos = frame.origin
        var size = frame.size

        // macOS clamps moves/resizes against the window's CURRENT screen. If a
        // window is moving onto another display (or near an edge), setting
        // position-then-size once leaves it slightly off — it lands too wide and
        // a second restore is needed to settle. The reliable fix is a
        // size → position → size sequence: pre-size so the frame can fit, move
        // it to the target screen, then re-apply the size to override any
        // clamping that happened during the move. This makes the first restore
        // land exactly.
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        if let posValue = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    /// True if a window is a real, user-facing window worth saving/restoring.
    /// Filters out Finder's desktop window (always present even with no visible
    /// Finder window), pop-overs, sheets, and tiny utility windows.
    ///
    /// `bundleID` is the owning app so Finder's desktop can be special-cased.
    static func isRealWindow(_ window: AXUIElement, bundleID: String?) -> Bool {
        // Subrole: keep only standard titled windows when a subrole is reported.
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef)
        if let subrole = subroleRef as? String, subrole != (kAXStandardWindowSubrole as String) {
            return false
        }

        guard let frame = getFrame(of: window) else { return false }
        if frame.width < 80 || frame.height < 60 { return false }

        // Finder's desktop window spans the entire combined desktop and has no
        // close/zoom buttons. Detect it by: it's Finder, AND its frame covers
        // (within tolerance) the union of all screen frames. Such a window is the
        // desktop, never a user window.
        if bundleID == "com.apple.finder" {
            let union = combinedScreenBoundsAX()
            let tol: CGFloat = 4
            let spansEverything =
                abs(frame.minX - union.minX) <= tol &&
                abs(frame.minY - union.minY) <= tol &&
                abs(frame.width  - union.width)  <= tol &&
                abs(frame.height - union.height) <= tol
            if spansEverything { return false }
            // Also drop a Finder window that has no title (the desktop has none).
            if getTitle(of: window).isEmpty { return false }
        }
        return true
    }

    /// The union of all screen frames expressed in AX (top-left origin) coords.
    static func combinedScreenBoundsAX() -> CGRect {
        guard let primary = NSScreen.screens.first else { return .zero }
        let primaryTop = primary.frame.maxY
        var union = CGRect.null
        for screen in NSScreen.screens {
            let f = screen.frame
            // Convert each screen's bottom-left frame into AX top-left space.
            let axRect = CGRect(x: f.minX, y: primaryTop - f.maxY, width: f.width, height: f.height)
            union = union.union(axRect)
        }
        return union
    }

    static func getFrame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    static func getTitle(of window: AXUIElement) -> String {
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        return (titleRef as? String) ?? ""
    }

    /// The CoreGraphics window number — a per-session-stable integer that does
    /// NOT change when a Chrome tab closes and the title updates. This is the
    /// best within-session identifier for telling many Chrome windows apart.
    /// (It changes when the app relaunches, so it isn't stable across reboots.)
    static func windowNumber(of window: AXUIElement) -> Int? {
        // _AXUIElementGetWindow is a private but long-stable API used widely to
        // bridge an AXUIElement to its CGWindowID. Declared in Bridging.h.
        var winID: CGWindowID = 0
        if _AXUIElementGetWindow(window, &winID) == .success, winID != 0 {
            return Int(winID)
        }
        return nil
    }

    /// AXIdentifier if the app sets one (rarely set by Chrome, but free to try).
    static func axIdentifier(of window: AXUIElement) -> String {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(window, "AXIdentifier" as CFString, &ref)
        return (ref as? String) ?? ""
    }

    /// The window's index within its app's window list — a positional fallback
    /// that's stable as long as windows aren't reordered or closed.
    static func windows(of pid: pid_t) -> [AXUIElement] {
        let appEl = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return [] }
        return arr
    }

    /// Accessibility coordinates are top-left origin; NSScreen is bottom-left.
    /// This converts an NSScreen visibleFrame region into AX coordinates.
    /// Converts a rect expressed in TOP-LEFT logical coordinates *relative to a
    /// screen's visible area* into the global AX coordinate space (top-left
    /// origin on the primary display, y growing downward).
    ///
    /// `localTopLeft.origin` is measured from the top-left corner of the
    /// screen's visibleFrame, with y growing downward.
    static func axFrame(localTopLeft: CGRect, on screen: NSScreen) -> CGRect {
        guard let primary = NSScreen.screens.first else { return localTopLeft }
        let primaryTop = primary.frame.maxY                 // global top edge (bottom-left space)
        let v = screen.visibleFrame                          // bottom-left origin

        // The screen's visible-area TOP edge, expressed as an AX y (distance
        // from the primary's top edge, growing downward).
        let screenTopAX = primaryTop - v.maxY

        // The screen's left edge in x is the same in both conventions.
        let globalX = v.minX + localTopLeft.origin.x
        let globalYAX = screenTopAX + localTopLeft.origin.y

        return CGRect(x: globalX, y: globalYAX,
                      width: localTopLeft.width, height: localTopLeft.height)
    }
}
