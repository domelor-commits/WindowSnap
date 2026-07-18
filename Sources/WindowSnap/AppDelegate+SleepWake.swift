import Cocoa

extension AppDelegate {
    // MARK: - Periodic "Saved" snapshot

    /// Captures the current arrangement into a rolling "Saved <timestamp>" layout
    /// in the saved-layouts list (replacing the previous one) at a configurable
    /// interval while the screen is unlocked. Default is NOT written here — it is
    /// fed from the latest "Saved" capture only at sleep.
    func startPeriodicSnapshot() {
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

    func periodicSnapshotTick() {
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
    func scheduleUnlockDriftFixup() {
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
    func feedDefaultFromLatestSavedCapture(trigger: String) {
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
    static var pendingWakeLayout: Layout?
    static var displayCallbackInstalled = false
    static var lastReconfigTime = Date.distantPast
    static var wakeDeadline = Date.distantPast

    /// Begin waiting for all monitors to be awake before restoring. Uses the
    /// CoreGraphics display-reconfiguration callback as the primary signal, plus
    /// a polling fallback, and only restores once the connected displays match
    /// the saved arrangement and have been stable briefly.
    func waitForDisplaysThenRestore(_ layout: Layout) {
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
    func pollDisplaysForWakeRestore() {
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
    func scheduleWakeFixupPasses(_ layout: Layout) {
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

}
