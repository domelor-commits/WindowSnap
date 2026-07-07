import Cocoa
import Carbon.HIToolbox
import Vision

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    let hotkeys = HotkeyManager()
    let dragSnap = DragSnapManager()
    var permissionsWindow: PermissionsWindowController?
    var settingsWindow: SettingsWindowController!
    /// Periodically captures the current arrangement into Default while you work,
    /// so a good layout exists before lock/sleep hides all windows.
    private var periodicSnapshotTimer: Timer?
    private var screenIsLocked = false

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon (when no window is open) reopens the main window.
        // This Apple Event can arrive before applicationDidFinishLaunching has
        // assigned settingsWindow, so guard against nil rather than force-unwrap.
        if !flag { settingsWindow?.show() }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the Dock shows our icon even if Icon.icns wasn't bundled.
        NSApp.applicationIconImage = AppDelegate.dockIcon()
        ensureAccessibility()

        // These options were removed from the UI and are now fixed: always show
        // the menu bar icon, always snap to screen edges, never add a gap or play
        // feedback sounds.
        Settings.shared.showInMenuBar = true
        Settings.shared.snapToScreenEdges = true
        Settings.shared.gapBetweenWindows = 0
        Settings.shared.playFeedbackSound = false
        // Enable "Launch at login" by default, one time, so it's on out of the box
        // while still letting the user turn it off afterwards.
        let loginDefaultKey = "WindowSnapLaunchAtLoginDefaultV1"
        if !UserDefaults.standard.bool(forKey: loginDefaultKey) {
            if LoginItem.isAvailable { LoginItem.setEnabled(true) }
            Settings.shared.launchAtLogin = true
            UserDefaults.standard.set(true, forKey: loginDefaultKey)
        }
        Settings.shared.save()

        settingsWindow = SettingsWindowController()
        settingsWindow.onShortcutsChanged = { [weak self] in self?.registerHotkeys() }
        settingsWindow.onSnapshotIntervalChanged = { [weak self] in self?.restartPeriodicSnapshot() }
        settingsWindow.onLayoutShortcutsChanged = { [weak self] in
            self?.registerHotkeys()
            self?.refreshMenuBar()
        }
        if Settings.shared.showInMenuBar { setupMenuBar() }
        registerHotkeys()

        // Magnet-style drag-to-edge snapping: route a released drag onto the
        // chosen region/screen through the same placement path as the shortcuts.
        dragSnap.onSnap = { [weak self] window, region, screen in
            self?.applySnap(region, on: screen, to: window)
        }
        if Settings.shared.dragToSnapEnabled { dragSnap.start() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(dragToSnapToggled),
            name: .windowSnapDragToSnapToggled, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(menuBarToggled),
            name: .windowSnapMenuBarToggled, object: nil)

        // System sleep / standby: optionally overwrite a chosen layout with the
        // current arrangement so it's captured just before the Mac sleeps.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil)

        // Wake from standby: optionally restore a chosen layout.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        // Screen lock (e.g. pressing Touch ID / power button to lock): optionally
        // overwrite the Default layout. Screen lock/unlock events are posted on
        // the DISTRIBUTED notification center, not the workspace one.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenDidLock),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenDidUnlock),
            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)

        // Re-register hotkeys whenever the app becomes active. This is a
        // reliable recovery point if global hotkeys were dropped (e.g. across a
        // sleep/wake cycle or after the system reclaimed them).
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)

        // Track display reconfiguration from the start, so the unlock/wake
        // "displays have settled" checks work even if no wake restore has run
        // yet in this session (e.g. plain lock/unlock without system sleep).
        AppDelegate.installDisplayReconfigCallback()

        // Start the periodic snapshot so a recent good Default always exists
        // before lock/sleep hides the windows.
        startPeriodicSnapshot()

        // On launch, if either required permission is missing, guide the user
        // through the setup wizard; otherwise open the main window as usual.
        if PermissionsWindowController.allGranted() {
            settingsWindow.show()
        } else {
            showPermissions()
        }
    }

    /// Open (or reopen) the permissions setup wizard.
    func showPermissions() {
        if permissionsWindow == nil { permissionsWindow = PermissionsWindowController() }
        permissionsWindow?.show()
    }

    @objc func dragToSnapToggled() {
        if Settings.shared.dragToSnapEnabled { dragSnap.start() } else { dragSnap.stop() }
    }

    // MARK: - Periodic "Saved" snapshot

    /// Captures the current arrangement into a rolling "Saved <timestamp>" layout
    /// in the saved-layouts list (replacing the previous one) at a configurable
    /// interval while the screen is unlocked. Default is NOT written here — it is
    /// fed from the latest "Saved" capture only at sleep.
    private func startPeriodicSnapshot() {
        periodicSnapshotTimer?.invalidate()
        let interval = TimeInterval(max(5, Settings.shared.snapshotIntervalSeconds))
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.periodicSnapshotTick()
        }
        t.tolerance = min(30, interval * 0.1)   // coalesce for power efficiency
        RunLoop.main.add(t, forMode: .common)
        periodicSnapshotTimer = t
        Logger.log("Snapshot timer: every \(Int(interval))s")
    }

    /// Call after the interval setting changes to apply the new cadence live.
    func restartPeriodicSnapshot() {
        startPeriodicSnapshot()
    }

    private func periodicSnapshotTick() {
        guard !screenIsLocked else { return }   // windows hidden when locked
        if let saved = LayoutManager.writeRollingSavedCapture() {
            Logger.log("Snapshot: \(saved.windows.count) win")
            NotificationCenter.default.post(name: .windowSnapLayoutsChanged, object: nil)
        } else {
            Logger.log("Snapshot: 0 win — kept previous")
        }
    }

    @objc func screenDidUnlock() {
        screenIsLocked = false
        Logger.log("Screen unlocked")
        scheduleUnlockDriftFixup()
    }

    /// Unlocking re-activates displays. A monitor that was still waking during
    /// the wake-time restore gets re-enabled the moment the lock screen goes
    /// away, and macOS shuffles windows onto it AGAIN — after the wake fix-up
    /// passes have already finished (they run 5–30s after the restore, which can
    /// all happen while still locked). So re-check for drift after unlock too,
    /// and re-restore the Default layout if windows moved.
    private func scheduleUnlockDriftFixup() {
        guard Settings.shared.restoreOnWake else { return }
        guard let layout = LayoutManager.loadDefault() else { return }
        for delay in [2.0, 8.0, 20.0, 40.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard LayoutManager.displaySignature() == layout.displaySignature,
                      Date().timeIntervalSince(AppDelegate.lastReconfigTime) >= 2.0,
                      !LayoutManager.arrangementMatches(layout) else { return }
                Logger.log("Unlock: drift detected — fix-up restore")
                LayoutManager.restore(layout)
            }
        }
    }

    @objc func appDidBecomeActive() {
        registerHotkeys()
    }

    @objc func systemWillSleep() {
        let on = Settings.shared.overwriteOnStandby
        Logger.log("Sleep: \(on ? "feeding Default…" : "auto-save off")")
        LayoutManager.notify("WindowSnap: sleep detected",
                             on ? "Updating Default from latest snapshot…" : "Auto-save into Default is off")
        guard on else { return }
        feedDefaultFromLatestSavedCapture(trigger: "sleep")
    }

    @objc func screenDidLock() {
        screenIsLocked = true
        let on = Settings.shared.overwriteOnStandby
        // At lock, macOS hides all windows, so a live capture would be empty.
        // Instead, promote the most recent periodic 'Saved' capture (taken while
        // unlocked) into Default now — same as the sleep path.
        Logger.log("Lock: \(on ? "feeding Default…" : "auto-save off")")
        guard on else { return }
        // Try one last fresh capture in case windows are still accessible at the
        // instant of locking; writeRollingSavedCapture() returns nil (and changes
        // nothing) if the capture is already empty.
        if let saved = LayoutManager.writeRollingSavedCapture() {
            Logger.log("Lock: refreshed snapshot (\(saved.windows.count) win)")
            NotificationCenter.default.post(name: .windowSnapLayoutsChanged, object: nil)
        }
        feedDefaultFromLatestSavedCapture(trigger: "lock")
    }

    /// Promote the most recent rolling "Saved" capture into the Default layout.
    /// Used at sleep, when live windows are typically hidden and a fresh capture
    /// would be empty. Falls back to a live capture only if no "Saved" exists.
    private func feedDefaultFromLatestSavedCapture(trigger: String) {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Updating Default layout (\(trigger))")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        // Prefer the latest periodic "Saved" capture (taken while unlocked).
        if let latest = LayoutManager.latestRollingSavedCapture(), !latest.windows.isEmpty {
            // Only overwrite Default if every monitor has at least one app in the
            // capture; otherwise a partial snapshot would clobber a good Default.
            guard LayoutManager.windowsCoverAllDisplays(latest) else {
                Logger.log("\(trigger.capitalized): snapshot missing some monitors — kept Default")
                LayoutManager.notify("\(trigger.capitalized): Default kept",
                                     "Latest snapshot didn't have apps on every monitor.")
                return
            }
            var promoted = latest
            promoted.id = LayoutManager.defaultLayoutID
            promoted.name = LayoutManager.defaultLayoutName
            LayoutManager.saveDefault(promoted)
            let displayCount = promoted.displays.count
            LayoutManager.notify("Default updated on \(trigger)",
                                 "\(promoted.windows.count) windows across \(displayCount) display\(displayCount == 1 ? "" : "s")")
            Logger.log("\(trigger.capitalized): Default ← snapshot (\(promoted.windows.count) win, \(displayCount) disp)")
            return
        }

        // No rolling capture yet — try a live capture as a last resort, guarding
        // against an empty result so we never wipe a good Default.
        var fresh = LayoutManager.capture(named: LayoutManager.defaultLayoutName)
        fresh.id = LayoutManager.defaultLayoutID
        if fresh.windows.isEmpty {
            Logger.log("\(trigger.capitalized): empty capture — kept Default")
            LayoutManager.notify("\(trigger.capitalized): Default kept", "No snapshot available; existing Default left intact.")
            return
        }
        guard LayoutManager.windowsCoverAllDisplays(fresh) else {
            Logger.log("\(trigger.capitalized): capture missing some monitors — kept Default")
            LayoutManager.notify("\(trigger.capitalized): Default kept", "Some monitors had no apps; existing Default left intact.")
            return
        }
        LayoutManager.saveDefault(fresh)
        Logger.log("\(trigger.capitalized): Default ← live capture (\(fresh.windows.count) win)")
    }

    @objc func systemDidWake() {
        // Log at the very top, before any work, so the event is always recorded.
        Logger.log("Wake (auto-restore \(Settings.shared.restoreOnWake ? "on" : "off"))")
        // Entry diagnostic: confirms the notification reached us at all.
        LayoutManager.notify("WindowSnap: wake detected",
                             Settings.shared.restoreOnWake ? "Restoring layout…" : "Auto-restore is off")
        // macOS frequently drops global Carbon hotkeys across a sleep/wake
        // cycle without reporting an error, so the registrations go stale and
        // shortcuts silently stop firing. Re-register them on wake to restore
        // functionality. Done on the main thread after a short delay so the
        // event system has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.registerHotkeys()
        }

        guard Settings.shared.restoreOnWake else {
            Logger.log("Wake: auto-restore off")
            return
        }
        // The pinned Default layout is the wake target.
        guard let saved = LayoutManager.loadDefault() else {
            LayoutManager.notify("Wake restore skipped", "No Default layout saved yet.")
            Logger.log("Wake: no Default saved")
            return
        }
        Logger.log("Wake: restore Default when displays settle (\(saved.windows.count) win)")
        // After wake, external displays reconnect at unpredictable times. Rather
        // than guess with a fixed delay, wait until macOS reports the display
        // configuration has come back to match what the layout was saved with
        // AND has stopped changing (settled), then restore.
        waitForDisplaysThenRestore(saved)
    }

    // Tracks an in-progress wake restore so the display callback can complete it.
    private static var pendingWakeLayout: Layout?
    private static var displayCallbackInstalled = false
    private static var lastReconfigTime = Date.distantPast
    private static var wakeDeadline = Date.distantPast

    /// Begin waiting for all monitors to be awake before restoring. Uses the
    /// CoreGraphics display-reconfiguration callback as the primary signal, plus
    /// a polling fallback, and only restores once the connected displays match
    /// the saved arrangement and have been stable briefly.
    private func waitForDisplaysThenRestore(_ layout: Layout) {
        AppDelegate.pendingWakeLayout = layout
        AppDelegate.wakeDeadline = Date().addingTimeInterval(60)  // monitors can come online one by one
        AppDelegate.lastReconfigTime = Date()

        AppDelegate.installDisplayReconfigCallback()

        pollDisplaysForWakeRestore()
    }

    /// Installs the CoreGraphics display-reconfiguration callback (once) that
    /// timestamps every display change; the wake and unlock paths use it to tell
    /// when the monitor arrangement has stopped churning.
    static func installDisplayReconfigCallback() {
        guard !displayCallbackInstalled else { return }
        CGDisplayRegisterReconfigurationCallback({ _, _, _ in
            AppDelegate.lastReconfigTime = Date()
        }, nil)
        displayCallbackInstalled = true
    }

    /// Polls until the displays match the saved layout and have been stable for
    /// at least ~3s (no reconfiguration events), then restores. Monitors wake one
    /// at a time, and each reconnect shuffles windows, so restoring during that
    /// churn places windows on the wrong screen.
    private func pollDisplaysForWakeRestore() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let layout = AppDelegate.pendingWakeLayout else { return }

            let signatureMatches = LayoutManager.displaySignature() == layout.displaySignature
            let settledFor = Date().timeIntervalSince(AppDelegate.lastReconfigTime)
            let timedOut = Date() > AppDelegate.wakeDeadline

            // Restore when the arrangement matches and has been quiet for 3s,
            // confirming all monitors are awake and the layout is back.
            if (signatureMatches && settledFor >= 3.0) || timedOut {
                AppDelegate.pendingWakeLayout = nil
                LayoutManager.restore(layout)
                self?.scheduleWakeFixupPasses(layout)
                return
            }
            // Keep waiting.
            self?.pollDisplaysForWakeRestore()
        }
    }

    /// Even after the initial restore, a monitor that finishes reconnecting late
    /// makes macOS shuffle windows again, undoing the placement. Re-check a few
    /// times after the restore and re-run it if the arrangement drifted.
    private func scheduleWakeFixupPasses(_ layout: Layout) {
        for delay in [5.0, 15.0, 30.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // Skip while a display reconfig is still in flight; the next
                // pass (or the signature guard inside restore) will handle it.
                guard LayoutManager.displaySignature() == layout.displaySignature,
                      Date().timeIntervalSince(AppDelegate.lastReconfigTime) >= 2.0,
                      !LayoutManager.arrangementMatches(layout) else { return }
                Logger.log("Wake: drift detected — fix-up restore")
                LayoutManager.restore(layout)
            }
        }
    }

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
    private func promptForScreenRecording(openPane: Bool) {
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
    private func hasScreenRecordingOrPrompt() -> Bool {
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
        let currentScreen = screenContaining(axFrame: frame)

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

    private func applySnap(_ region: SnapRegion, on screen: NSScreen, to window: AXUIElement) {
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
    }

    // MARK: Edge detection (AX frame is top-left origin; convert to global)
    private func globalFrame(_ axFrame: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first!.frame.maxY
        return CGRect(x: axFrame.minX, y: primaryHeight - axFrame.minY - axFrame.height,
                      width: axFrame.width, height: axFrame.height)
    }

    private func isAtLeftEdge(_ axFrame: CGRect, of screen: NSScreen) -> Bool {
        let g = globalFrame(axFrame)
        let tol: CGFloat = 8
        return abs(g.minX - screen.visibleFrame.minX) <= tol
    }

    private func isAtRightEdge(_ axFrame: CGRect, of screen: NSScreen) -> Bool {
        let g = globalFrame(axFrame)
        let tol: CGFloat = 8
        return abs(g.maxX - screen.visibleFrame.maxX) <= tol
    }

    private enum Direction { case left, right }

    /// Screens in canonical rightward cycling order: left-to-right by X, and
    /// within a shared column the TOP monitor comes first. (NSScreen uses a
    /// bottom-left origin, so the top monitor has the larger minY.) Leftward
    /// travel reverses this, yielding bottom-first within a column.
    private func screensRightwardOrder() -> [NSScreen] {
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
    private func adjacentScreen(to screen: NSScreen, direction: Direction) -> NSScreen? {
        let rightward = screensRightwardOrder()
        let ordered = (direction == .right) ? rightward : Array(rightward.reversed())
        guard let idx = ordered.firstIndex(of: screen) else { return nil }
        return idx < ordered.count - 1 ? ordered[idx + 1] : nil
    }

    func screenContaining(axFrame: CGRect) -> NSScreen {
        let primaryHeight = NSScreen.screens.first!.frame.maxY
        let center = CGPoint(x: axFrame.midX, y: primaryHeight - axFrame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main!
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

    // MARK: Menu bar icon (drawn as a template image so it always renders)
    static func menuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size)
        img.lockFocus()
        let outer = NSRect(x: 1, y: 1, width: 16, height: 14)
        let frame = NSBezierPath(roundedRect: outer, xRadius: 2.5, yRadius: 2.5)
        frame.lineWidth = 1.4
        NSColor.black.setStroke()
        frame.stroke()
        // Left pane filled (the "snapped" window).
        let left = NSBezierPath(rect: NSRect(x: 3, y: 3, width: 5.5, height: 10))
        NSColor.black.setFill()
        left.fill()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    /// Full-color Dock icon, drawn to match Icon.svg (blue rounded square with a
    /// snapped left pane). Used as a fallback so the Dock always shows an icon
    /// even if Icon.icns wasn't generated at build time.
    static func dockIcon() -> NSImage {
        let size = NSSize(width: 256, height: 256)
        let img = NSImage(size: size)
        img.lockFocus()

        // Background rounded square with vertical blue gradient.
        let bgRect = NSRect(x: 28, y: 28, width: 200, height: 200)
        let bg = NSBezierPath(roundedRect: bgRect, xRadius: 45, yRadius: 45)
        let gradient = NSGradient(starting: NSColor(red: 0.231, green: 0.510, blue: 0.965, alpha: 1),
                                  ending:   NSColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 1))
        gradient?.draw(in: bg, angle: -90)

        bg.addClip()
        // Window container (faint).
        let container = NSBezierPath(roundedRect: NSRect(x: 62, y: 66, width: 132, height: 124),
                                     xRadius: 12, yRadius: 12)
        NSColor(white: 1, alpha: 0.16).setFill(); container.fill()
        // Snapped left pane (solid white).
        let leftPane = NSBezierPath(roundedRect: NSRect(x: 62, y: 66, width: 64, height: 124),
                                    xRadius: 10, yRadius: 10)
        NSColor.white.setFill(); leftPane.fill()
        // Title bar accent on the left pane.
        let titleBar = NSBezierPath(roundedRect: NSRect(x: 72, y: 168, width: 44, height: 9),
                                    xRadius: 4, yRadius: 4)
        NSColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 0.85).setFill(); titleBar.fill()
        // Ghosted content lines on the right.
        for (i, w) in [50, 50, 36].enumerated() {
            let y = 168 - i * 22
            let line = NSBezierPath(roundedRect: NSRect(x: 138, y: CGFloat(y), width: CGFloat(w), height: 9),
                                    xRadius: 4, yRadius: 4)
            NSColor(white: 1, alpha: i == 0 ? 0.55 : 0.40).setFill(); line.fill()
        }

        img.unlockFocus()
        return img
    }

    // MARK: Menu bar
    func setupMenuBar() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = AppDelegate.menuBarIcon()
            button.image?.isTemplate = true   // adapts to light/dark menu bar
            button.imagePosition = .imageOnly
        }
        let menu = NSMenu()
        menu.delegate = self          // rebuild on open so 'Saved' entries are current
        buildMenu(into: menu)
        statusItem?.menu = menu
    }

    /// Populate (or repopulate) the status-bar menu. Called when the menu is
    /// created and again each time it's about to open, so the saved-layouts
    /// submenu always reflects the latest rolling 'Saved' capture.
    func buildMenu(into menu: NSMenu) {
        menu.removeAllItems()
        let open = NSMenuItem(title: "Open WindowSnap…", action: #selector(openSettings), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        let perms = NSMenuItem(title: "Permissions Setup…", action: #selector(openPermissions), keyEquivalent: "")
        perms.target = self
        menu.addItem(perms)
        menu.addItem(.separator())
        let quick: [(String, SnapRegion)] = [
            ("Left Half", .leftHalf), ("Right Half", .rightHalf), ("Maximize", .maximize)
        ]
        for (label, region) in quick {
            let i = NSMenuItem(title: label, action: #selector(menuSnap(_:)), keyEquivalent: "")
            i.representedObject = region.rawValue; i.target = self
            menu.addItem(i)
        }
        menu.addItem(.separator())

        // Screen OCR — show the bound launcher shortcut when one is assigned.
        let ocrSlot = Settings.shared.functionKeyApps.first(where: { $0.value == "system:ocrArea" })?.key
        let ocrKey = ocrSlot.flatMap { Settings.shared.shortcuts["launcher:\($0)"] }?.display
        let ocrTitle = ocrKey.map { "Copy Text from Screen   \($0)" } ?? "Copy Text from Screen"
        let ocrItem = NSMenuItem(title: ocrTitle, action: #selector(ocrScreenRegion), keyEquivalent: "")
        ocrItem.target = self
        menu.addItem(ocrItem)
        menu.addItem(.separator())

        func titleWithShortcut(_ name: String, key: String) -> String {
            if let sc = Settings.shared.shortcuts[key] {
                return "\(name)   \(sc.display)"
            }
            return name
        }

        let defaultRestore = NSMenuItem(
            title: titleWithShortcut("Restore Default Layout", key: "restoreDefault"),
            action: #selector(restoreDefaultFromMenu), keyEquivalent: "")
        defaultRestore.target = self
        defaultRestore.isEnabled = (LayoutManager.loadDefault() != nil)
        menu.addItem(defaultRestore)

        let layouts = LayoutManager.loadAll()
        if layouts.isEmpty {
            let none = NSMenuItem(title: "No saved layouts", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            let restoreMenu = NSMenu()
            for (i, layout) in layouts.enumerated() {
                // Show the per-layout restore shortcut set in the Layouts tab.
                let item = NSMenuItem(
                    title: titleWithShortcut(layout.name, key: "restoreLayout:\(layout.id)"),
                    action: #selector(restoreLayoutAtIndex(_:)), keyEquivalent: "")
                item.tag = i; item.target = self
                restoreMenu.addItem(item)
            }
            let restoreParent = NSMenuItem(title: "Restore Saved Layout", action: nil, keyEquivalent: "")
            menu.addItem(restoreParent)
            menu.setSubmenu(restoreMenu, for: restoreParent)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit WindowSnap", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // NSMenuDelegate: rebuild the status menu each time it opens so the
    // saved-layouts submenu reflects the latest rolling 'Saved' capture.
    func menuNeedsUpdate(_ menu: NSMenu) {
        buildMenu(into: menu)
    }

    @objc func menuBarToggled() {
        if Settings.shared.showInMenuBar {
            setupMenuBar()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc func openSettings() { settingsWindow.show() }

    @objc func openPermissions() { showPermissions() }

    @objc func menuSnap(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let region = SnapRegion(rawValue: raw) {
            snap(region)
        }
    }

    @objc func restoreDefaultFromMenu() {
        restorePinned(LayoutManager.defaultLayoutID)
    }

    @objc func restoreLayoutAtIndex(_ sender: NSMenuItem) {
        let layouts = LayoutManager.loadAll()
        guard sender.tag >= 0, sender.tag < layouts.count else { return }
        LayoutManager.restore(layouts[sender.tag])
    }

    /// Rebuild the menu bar (call after layouts change so the submenu updates).
    func refreshMenuBar() {
        guard Settings.shared.showInMenuBar, let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        setupMenuBar()
    }

    // MARK: Hotkeys from settings
    func registerHotkeys() {
        hotkeys.unregisterAll()
        for (key, sc) in Settings.shared.shortcuts {
            if key == "overwriteDefault" {
                hotkeys.register(keyCode: sc.keyCode, modifiers: sc.modifiers) { [weak self] in
                    self?.overwriteLayoutViaShortcut(id: LayoutManager.defaultLayoutID)
                }
            } else if key == "overwritePresentation" {
                hotkeys.register(keyCode: sc.keyCode, modifiers: sc.modifiers) { [weak self] in
                    self?.overwriteLayoutViaShortcut(id: LayoutManager.presentationLayoutID)
                }
            } else if key.hasPrefix("overwriteLayout:") {
                let id = String(key.dropFirst("overwriteLayout:".count))
                hotkeys.register(keyCode: sc.keyCode, modifiers: sc.modifiers) { [weak self] in
                    self?.overwriteLayoutViaShortcut(id: id)
                }
            } else if key == "restoreDefault" {
                // Locked to the pinned "Default" layout, regardless of selection.
                hotkeys.register(keyCode: sc.keyCode, modifiers: sc.modifiers) { [weak self] in
                    self?.restorePinned(LayoutManager.defaultLayoutID)
                }
            } else if key == "restorePresentation" {
                // Locked to the pinned "Presentation" layout, regardless of selection.
                hotkeys.register(keyCode: sc.keyCode, modifiers: sc.modifiers) { [weak self] in
                    self?.restorePinned(LayoutManager.presentationLayoutID)
                }
            } else if key.hasPrefix("restoreLayout:") {
                // Per-saved-layout restore shortcut set inline in the Layouts tab.
                let id = String(key.dropFirst("restoreLayout:".count))
                hotkeys.register(keyCode: sc.keyCode, modifiers: sc.modifiers) { [weak self] in
                    self?.performRestore(layoutID: id)
                }
            } else if let region = SnapRegion(rawValue: key) {
                hotkeys.register(keyCode: sc.keyCode, modifiers: sc.modifiers) { [weak self] in
                    self?.snap(region)
                }
            }
        }

        // Configurable launcher slots: each has a user-chosen shortcut plus an
        // app / system-task / restart assignment.
        for slot in Settings.launcherSlots {
            guard let assignment = Settings.shared.functionKeyApps[slot], !assignment.isEmpty,
                  let sc = Settings.shared.shortcuts["launcher:\(slot)"] else { continue }
            hotkeys.register(keyCode: sc.keyCode, modifiers: sc.modifiers) { [weak self] in
                self?.performFunctionKeyAction(assignment)
            }
        }
    }

    /// Runs a function-key assignment: either a macOS system task
    /// ("system:<id>") or launching an application by bundle path.
    func performFunctionKeyAction(_ value: String) {
        if value.hasPrefix("system:") {
            runSystemTask(String(value.dropFirst("system:".count)))
        } else if value.hasPrefix("restart:") {
            forceQuitAndReopen(spec: String(value.dropFirst("restart:".count)))
        } else {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: value),
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                if let error = error {
                    Logger.log("Failed to launch \(value): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Force-quits a hung app, then relaunches it. Intended for unfreezing an app
    /// that has hung. Force termination is abrupt, so any unsaved work in that app
    /// is lost — that's the trade-off for recovering a hung process.
    ///
    /// `spec` is "<launchAppPath>" or "<launchAppPath>\n<killProcessName>". The
    /// kill target can differ from the launch target: e.g. thinkorswim is
    /// launched as thinkorswim.app but its hung process is "java-arm".
    private func forceQuitAndReopen(spec: String) {
        let parts = spec.components(separatedBy: "\n")
        let url = URL(fileURLWithPath: parts[0])
        let name = url.deletingPathExtension().lastPathComponent
        let killName = parts.count > 1 ? parts[1] : ""

        if killName.isEmpty {
            // Quit the app's own process, matched by bundle id (or bundle path).
            let bundleID = Bundle(url: url)?.bundleIdentifier
            let running = NSWorkspace.shared.runningApplications.filter { app in
                if let bundleID = bundleID { return app.bundleIdentifier == bundleID }
                return app.bundleURL?.standardizedFileURL == url.standardizedFileURL
            }
            if running.isEmpty {
                Logger.log("Restart \(name): not running — launching")
            } else {
                for app in running { app.forceTerminate() }
                Logger.log("Restart \(name): killed \(running.count)")
            }
        } else {
            // Quit a named process (e.g. "java-arm") that differs from the app.
            // First force-terminate any matching app-level processes (so the Dock
            // icon clears), then use `killall -9` as a backstop to reap any
            // non-app/background instances of that process name.
            let matches = NSWorkspace.shared.runningApplications.filter { app in
                app.localizedName == killName
                    || app.executableURL?.lastPathComponent == killName
                    || app.bundleIdentifier == killName
            }
            for app in matches { app.forceTerminate() }
            runProcess("/usr/bin/killall", ["-9", killName])
            Logger.log("Restart \(name): killed “\(killName)” (\(matches.count))")
        }

        // Relaunch after the killed instances have a moment to exit, so the new
        // launch isn't merged into a process that's still tearing down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                if let error = error {
                    Logger.log("Restart \(name): launch failed — \(error.localizedDescription)")
                } else {
                    Logger.log("Restart \(name): relaunched")
                }
            }
        }
    }

    /// Performs a popular macOS system task. Screenshots are written to the
    /// Desktop, matching the behaviour of the built-in screenshot shortcuts.
    private func runSystemTask(_ id: String) {
        func screenshotPath() -> String {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
            return downloads.appendingPathComponent("Screenshot \(fmt.string(from: Date())).png").path
        }
        switch id {
        // Area captures use WindowSnap's own selector (magnifier + dimensions),
        // which grabs pixels in-process and so needs Screen Recording access.
        case "screenshotAreaFile":
            guard hasScreenRecordingOrPrompt() else { return }
            captureAreaViaSelector(toFile: true)
        case "screenshotAreaClip":
            guard hasScreenRecordingOrPrompt() else { return }
            captureAreaViaSelector(toFile: false)
        // Full / window use the native tool (its own magnifier / window shadow).
        case "screenshotFullFile":
            captureThenAnnotate([], path: screenshotPath())
        case "screenshotWindowFile":
            captureThenAnnotate(["-iW"], path: screenshotPath())
        case "screenshotFullClip":
            captureToClipboardThenAnnotate([])
        case "screenshotWindowClip":
            captureToClipboardThenAnnotate(["-iW"])
        case "screenshotFullTimer5":
            captureToClipboardThenAnnotate(["-T", "5"])
        case "scrollingCapture":
            guard hasScreenRecordingOrPrompt() else { return }
            ScrollingCapture.start { [weak self] img in
                guard let img = img else { Logger.log("Scrolling capture cancelled"); return }
                self?.deliverCapture(img, filePath: nil)
            }
        case "screenshotPrevArea":
            guard hasScreenRecordingOrPrompt() else { return }
            capturePreviousArea()
        case "allInOne":
            CaptureMenu.shared.show { [weak self] taskID in
                self?.runSystemTask(taskID)
            }
        case "toggleDesktopIcons":
            toggleDesktopIcons()
        case "ocrArea":
            ocrScreenRegion()
        case "lockScreen":
            runProcess("/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession",
                       ["-suspend"])
        case "sleepDisplay":
            runProcess("/usr/bin/pmset", ["displaysleepnow"])
        case "missionControl":
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        case "launchpad":
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Launchpad.app"))
        case "screenSaver":
            runProcess("/usr/bin/open", ["-a", "ScreenSaverEngine"])
        default:
            Logger.log("Unknown system task: \(id)")
        }
    }

    private func runProcess(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run() }
        catch { Logger.log("Failed to run \(path): \(error.localizedDescription)") }
    }

    /// Runs a to-file screenshot capture, also copies it to the clipboard (memory
    /// buffer), and presents the Quick Access Overlay (CleanShot-style): click
    /// the floating thumbnail to annotate, drag it into another app, Copy /
    /// Reveal / Pin, or dismiss. Pressing Esc produces no file and does nothing.
    private func captureThenAnnotate(_ args: [String], path: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = args + [path]
            do { try p.run(); p.waitUntilExit() } catch {
                Logger.log("Screenshot failed — \(error.localizedDescription)")
                return
            }
            guard FileManager.default.fileExists(atPath: path),
                  let img = NSImage(contentsOfFile: path) else { return }   // Esc
            DispatchQueue.main.async {
                Logger.log("Screenshot → \((path as NSString).lastPathComponent) (+clipboard)")
                self.deliverCapture(img, filePath: path)
            }
        }
    }

    /// Shared post-capture delivery: copy to the clipboard (memory buffer),
    /// open the shot in the Annotate tab, and show the Quick Access Overlay
    /// (drag-out / Save / Pin / auto-close).
    func deliverCapture(_ img: NSImage, filePath: String?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])

        if let path = filePath {
            settingsWindow.showAnnotate(path: path)
        } else {
            settingsWindow.showAnnotateFromClipboard(img)
        }
        QuickAccessOverlay.present(image: img, filePath: filePath) { [weak self] in
            // Thumbnail click re-focuses the annotator.
            if let path = filePath { self?.settingsWindow.showAnnotate(path: path) }
            else { self?.settingsWindow.show() }
        }
    }

    /// Interactive area capture through WindowSnap's own region selector (which
    /// shows the magnifier + live dimensions), then deliver to Annotate.
    private func captureAreaViaSelector(toFile: Bool) {
        RegionSelector.shared.begin { [weak self] cgRect in
            guard let self = self, let rect = cgRect, let img = ScreenGrab.image(rect) else { return }
            Settings.shared.lastCaptureRect =
                "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
            Settings.shared.save()
            if toFile, let path = self.saveImageToDownloads(img) {
                Logger.log("Screenshot area → \((path as NSString).lastPathComponent)")
                self.deliverCapture(img, filePath: path)
            } else {
                Logger.log("Screenshot area → clipboard")
                self.deliverCapture(img, filePath: nil)
            }
        }
    }

    /// Writes an image to Downloads as "Screenshot <date>.png", returning its path.
    private func saveImageToDownloads(_ img: NSImage) -> String? {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let url = dir.appendingPathComponent("Screenshot \(fmt.string(from: Date())).png")
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        do { try png.write(to: url, options: .atomic); return url.path }
        catch { Logger.log("Area save failed — \(error.localizedDescription)"); return nil }
    }

    /// Re-captures the last user-selected region ("Capture Previous Area").
    /// With no stored region yet, asks for one first.
    private func capturePreviousArea() {
        let parts = Settings.shared.lastCaptureRect.components(separatedBy: ",").compactMap { Int($0) }
        if parts.count == 4 {
            let rect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            guard let img = ScreenGrab.image(rect) else { NSSound.beep(); return }
            Logger.log("Screenshot previous area → clipboard")
            deliverCapture(img, filePath: nil)
            return
        }
        RegionSelector.shared.begin { [weak self] cgRect in
            guard let rect = cgRect else { return }
            Settings.shared.lastCaptureRect =
                "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
            Settings.shared.save()
            guard let img = ScreenGrab.image(rect) else { NSSound.beep(); return }
            Logger.log("Screenshot area → clipboard")
            self?.deliverCapture(img, filePath: nil)
        }
    }

    /// Captures directly to the clipboard (memory buffer) — no file written —
    /// and presents the Quick Access Overlay. Detects Esc via the pasteboard
    /// change count so a cancelled capture doesn't show a stale image.
    private func captureToClipboardThenAnnotate(_ args: [String]) {
        let before = NSPasteboard.general.changeCount
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = args + ["-c"]
            do { try p.run(); p.waitUntilExit() } catch {
                Logger.log("Screenshot failed — \(error.localizedDescription)")
                return
            }
            DispatchQueue.main.async {
                // Unchanged clipboard means the user pressed Esc.
                guard NSPasteboard.general.changeCount != before,
                      let img = NSImage(pasteboard: .general) else { return }
                Logger.log("Screenshot → clipboard")
                self.deliverCapture(img, filePath: nil)
            }
        }
    }

    /// CleanShot-style "Hide Desktop Icons": toggles Finder's desktop drawing.
    private func toggleDesktopIcons() {
        let finderDefaults = UserDefaults(suiteName: "com.apple.finder")
        let visible = finderDefaults?.object(forKey: "CreateDesktop") as? Bool ?? true
        runProcess("/usr/bin/defaults",
                   ["write", "com.apple.finder", "CreateDesktop", "-bool", visible ? "false" : "true"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.runProcess("/usr/bin/killall", ["Finder"])
        }
        Logger.log("Desktop icons \(visible ? "hidden" : "shown")")
    }

    // MARK: - Screen OCR (copy text from anything on screen)

    /// Interactive region OCR: the native crosshair selection (screencapture -i)
    /// grabs a region to a temp file, Vision recognizes the text, and the result
    /// lands on the clipboard. Pressing Esc during selection cancels silently.
    @objc func ocrScreenRegion() {
        let path = NSTemporaryDirectory() + "windowsnap-ocr-\(UUID().uuidString).png"
        DispatchQueue.global(qos: .userInitiated).async {
            // -i: interactive selection, -x: no camera sound. Blocks until the
            // user finishes or cancels, so this runs off the main thread.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", path]
            do { try p.run(); p.waitUntilExit() } catch {
                Logger.log("OCR: capture failed — \(error.localizedDescription)")
                return
            }
            defer { try? FileManager.default.removeItem(atPath: path) }

            // No file means the user pressed Esc — not an error.
            guard let img = NSImage(contentsOfFile: path),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request]) } catch {
                Logger.log("OCR: recognition failed — \(error.localizedDescription)")
                return
            }
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")

            DispatchQueue.main.async {
                guard !text.isEmpty else {
                    LayoutManager.notify("No text found", "The selected area had no readable text.")
                    Logger.log("OCR: no text found")
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                LayoutManager.notify("Text copied", "\(text.count) characters on the clipboard")
                Logger.log("OCR: copied \(text.count) chars")
            }
        }
    }

    /// Single restore entry point shared by the hotkey and (indirectly) the UI.
    /// Resolves the layout fresh and restores on the main thread. Handles pinned
    /// layouts (separate stores) as well as saved layouts.
    func performRestore(layoutID: String) {
        DispatchQueue.main.async {
            let match: Layout?
            if LayoutManager.isPinned(layoutID) {
                match = LayoutManager.loadPinned(layoutID)
            } else {
                match = LayoutManager.loadAll().first(where: { $0.id == layoutID })
            }
            guard let layout = match else { return }
            LayoutManager.restore(layout)
        }
    }

    /// Restore a pinned layout by id, with a helpful notice if it's empty.
    func restorePinned(_ id: String) {
        DispatchQueue.main.async {
            if let layout = LayoutManager.loadPinned(id) {
                LayoutManager.restore(layout)
            } else {
                let name = LayoutManager.pinnedName(for: id)
                LayoutManager.notify("No \(name) layout",
                                     "Select \(name) in the Layouts tab and Save New to capture it.")
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)   // show in Dock and app switcher
app.run()
