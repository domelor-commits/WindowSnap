import Cocoa

extension AppDelegate {
    // MARK: Accessibility
    func ensureAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: Screen Recording
    /// The area selector's magnifier and the in-process pixel grabs
    /// (`CGWindowListCreateImage`) need Screen Recording permission — separate
    /// from Accessibility. macOS forbids an app from granting itself this; the
    /// setup wizard (shown at launch when a permission is missing) makes the
    /// one-time approval easy, and this guard covers a capture attempted before
    /// the grant is in place. Because the app is signed with a STABLE identity,
    /// the grant persists across future rebuilds once enabled.

    /// Requests Screen Recording access, optionally opening the settings pane, and
    /// posts a guiding notification.
    func promptForScreenRecording(openPane: Bool) {
        guard #available(macOS 10.15, *) else { return }
        CGRequestScreenCaptureAccess()
        if openPane, let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        LayoutManager.notify("Enable Screen Recording for WindowSnap",
            "Turn WindowSnap on in the list that opened — you only need to do this once; it carries over to future updates.")
        Logger.log("Screen Recording not granted — prompted + opened settings pane")
    }

    /// Guards a capture that reads pixels in-process. Returns true if Screen
    /// Recording is granted; otherwise prompts + opens the settings pane and
    /// returns false so the caller bails cleanly rather than grabbing a black image.
    func hasScreenRecordingOrPrompt() -> Bool {
        if #available(macOS 10.15, *), !CGPreflightScreenCaptureAccess() {
            promptForScreenRecording(openPane: true)
            return false
        }
        return true
    }

    // MARK: Snapping (honors gap + multi-monitor cycling)
    func snap(_ region: SnapRegion) {
        guard let window = WindowController.focusedWindow(),
              let frame = WindowController.getFrame(of: window) else { return }
        guard let currentScreen = screenContaining(axFrame: frame) else { return }

        // Cross-monitor cycling: if a left/right snap is pressed while the window
        // is already at that edge of the current screen, move it to the adjacent
        // monitor and snap it to the *opposite* edge there (so it sits adjacent).
        if region == .leftHalf, isAtLeftEdge(frame, of: currentScreen),
           let leftScreen = adjacentScreen(to: currentScreen, direction: .left) {
            applySnap(.rightHalf, on: leftScreen, to: window)
            return
        }
        if region == .rightHalf, isAtRightEdge(frame, of: currentScreen),
           let rightScreen = adjacentScreen(to: currentScreen, direction: .right) {
            applySnap(.leftHalf, on: rightScreen, to: window)
            return
        }

        applySnap(region, on: currentScreen, to: window)
    }

    func applySnap(_ region: SnapRegion, on screen: NSScreen, to window: AXUIElement) {
        // Work entirely in the screen's visibleFrame, but treat it as a
        // TOP-LEFT logical box: region.frame returns a rect whose y grows
        // downward from the top of the visible area. axFrame then converts that
        // single, consistent representation into global AX coordinates.
        let v = screen.visibleFrame
        // Logical box: same width/height, origin at (0,0) = top-left of visible area.
        var target = region.frame(in: CGRect(x: 0, y: 0, width: v.width, height: v.height))
        let gap = CGFloat(Settings.shared.gapBetweenWindows)
        if gap > 0 { target = target.insetBy(dx: gap / 2, dy: gap / 2) }
        WindowController.setFrame(WindowController.axFrame(localTopLeft: target, on: screen), for: window)
        if Settings.shared.playFeedbackSound { NSSound.beep() }
        if Settings.shared.snapFlashEnabled { SnapHUD.shared.flash(region: region, on: screen) }
    }

    // MARK: Edge detection (AX frame is top-left origin; convert to global)
    func globalFrame(_ axFrame: CGRect) -> CGRect {
        // No screens (all displays asleep / disconnected): nothing to convert
        // against, so return the frame unchanged rather than crash.
        guard let primaryHeight = NSScreen.screens.first?.frame.maxY else { return axFrame }
        return CGRect(x: axFrame.minX, y: primaryHeight - axFrame.minY - axFrame.height,
                      width: axFrame.width, height: axFrame.height)
    }

    func isAtLeftEdge(_ axFrame: CGRect, of screen: NSScreen) -> Bool {
        let g = globalFrame(axFrame)
        let tol: CGFloat = 8
        return abs(g.minX - screen.visibleFrame.minX) <= tol
    }

    func isAtRightEdge(_ axFrame: CGRect, of screen: NSScreen) -> Bool {
        let g = globalFrame(axFrame)
        let tol: CGFloat = 8
        return abs(g.maxX - screen.visibleFrame.maxX) <= tol
    }

    enum Direction { case left, right }

    /// Screens in canonical rightward cycling order: left-to-right by X, and
    /// within a shared column the TOP monitor comes first. (NSScreen uses a
    /// bottom-left origin, so the top monitor has the larger minY.) Leftward
    /// travel reverses this, yielding bottom-first within a column.
    func screensRightwardOrder() -> [NSScreen] {
        NSScreen.screens.sorted { a, b in
            a.frame.minX != b.frame.minX
                ? a.frame.minX < b.frame.minX
                : a.frame.minY > b.frame.minY   // top (larger Y) first
        }
    }

    /// The next screen in cycling order in the given direction. Cycles through
    /// EVERY monitor regardless of row. Returns nil at the ends so a window stays
    /// put at the outermost edge rather than wrapping around.
    ///
    /// The canonical sequence is the rightward order (left-to-right by X,
    /// bottom-first within a shared column). Leftward travel is the exact reverse
    /// of that sequence — which automatically yields top-first within a column,
    /// satisfying both rules with one ordering.
    func adjacentScreen(to screen: NSScreen, direction: Direction) -> NSScreen? {
        let rightward = screensRightwardOrder()
        let ordered = (direction == .right) ? rightward : Array(rightward.reversed())
        guard let idx = ordered.firstIndex(of: screen) else { return nil }
        return idx < ordered.count - 1 ? ordered[idx + 1] : nil
    }

    /// The screen whose frame contains the center of an AX-origin frame, or nil
    /// when there are no screens (all displays asleep/disconnected).
    func screenContaining(axFrame: CGRect) -> NSScreen? {
        guard let primaryHeight = NSScreen.screens.first?.frame.maxY else { return nil }
        let center = CGPoint(x: axFrame.midX, y: primaryHeight - axFrame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
    }

    /// Overwrite a specific layout (by id) with the current windows. Used by the
    /// per-row overwrite shortcuts. Handles pinned (Default) and saved layouts.
    func overwriteLayoutViaShortcut(id: String) {
        DispatchQueue.main.async { [weak self] in
            if LayoutManager.isPinned(id) {
                var fresh = LayoutManager.capture(named: LayoutManager.pinnedName(for: id))
                fresh.id = id
                LayoutManager.savePinned(fresh, id: id)
                LayoutManager.notify("\(LayoutManager.pinnedName(for: id)) layout overwritten",
                                     "\(fresh.windows.count) windows")
                Logger.log("Overwrote \(LayoutManager.pinnedName(for: id)) (\(fresh.windows.count) win)")
            } else {
                var all = LayoutManager.loadAll()
                guard let idx = all.firstIndex(where: { $0.id == id }) else {
                    NSSound.beep(); return
                }
                let old = all[idx]
                var fresh = LayoutManager.capture(named: old.name)
                fresh.id = old.id
                all[idx] = fresh
                LayoutManager.save(all)
                LayoutManager.notify("Layout overwritten", old.name)
                Logger.log("Overwrote “\(old.name)” (\(fresh.windows.count) win)")
            }
            self?.settingsWindow.reloadLayouts()
        }
    }

}
