import Cocoa
import Carbon.HIToolbox
import Vision

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    let hotkeys = HotkeyManager()
    let dragSnap = DragSnapManager()
    var permissionsWindow: PermissionsWindowController?
    var settingsWindow: SettingsWindowController!
    /// The most recent non-WindowSnap app to be frontmost, so the Command Palette
    /// tab can hand focus back before running a window action (e.g. a snap).
    var lastActiveOtherApp: NSRunningApplication?
    /// Periodically captures the current arrangement into Default while you work,
    /// so a good layout exists before lock/sleep hides all windows.
    var periodicSnapshotTimer: Timer?
    var screenIsLocked = false
    /// Drives the once-a-second Keep Awake countdown in the menu-bar title.
    var keepAwakeDisplayTimer: Timer?

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
        setupMainMenu()
        Notifier.shared.setup()
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
        settingsWindow.paletteActionsProvider = { [weak self] in self?.buildPaletteActions() ?? [] }
        settingsWindow.runPaletteAction = { [weak self] in self?.runPaletteActionRestoringFocus($0) }
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

        // Clipboard history monitor (menu-bar "caffeine" Keep Awake is off until
        // the user turns it on, so nothing to start there).
        if Settings.shared.clipboardHistoryEnabled { ClipboardHistory.shared.start() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(keepAwakeChanged),
            name: .windowSnapKeepAwakeChanged, object: nil)

        // Track the last non-self app to be frontmost (for palette focus hand-off).
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(otherAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

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

        // Auto-update (dormant until an appcast feed + key are configured), and
        // show the release notes once after a version bump.
        UpdaterManager.shared.startIfConfigured()
        WhatsNewWindowController.shared.showIfNeeded()

        // Calendar access for the optional "next meeting" menu item.
        MeetingBar.shared.requestAccessIfEnabled()

        // Restore the keystroke visualizer if it was left on.
        if Settings.shared.keystrokeVizEnabled { KeystrokeVisualizer.shared.start() }

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

}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)   // show in Dock and app switcher
app.run()
