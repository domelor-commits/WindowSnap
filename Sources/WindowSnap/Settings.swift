import Cocoa
import Carbon.HIToolbox

/// A configurable keyboard shortcut: a key code plus Carbon modifier flags.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon flags: cmdKey, optionKey, controlKey, shiftKey

    /// Human-readable like "⌃⌥←"
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += KeyNames.string(for: keyCode)
        return s
    }
}

/// All app preferences, persisted to UserDefaults as JSON.
final class Settings {
    static let shared = Settings()

    private let defaultsKey = "WindowSnapSettings"

    // Preferences (Magnet/Moom-style toggles)
    var launchAtLogin: Bool = true
    var showInMenuBar: Bool = true
    var gapBetweenWindows: Int = 0          // px gutter when snapping
    var snapshotIntervalSeconds: Int = 300  // periodic "Saved" capture interval (seconds)
    var snapToScreenEdges: Bool = true
    var dragToSnapEnabled: Bool = true      // Magnet-style drag-to-edge snapping
    var snapFlashEnabled: Bool = true       // flash the target region on keyboard snap
    var clipboardHistoryEnabled: Bool = true
    var clipboardAutoPaste: Bool = true     // paste the chosen clip into the frontmost app
    // Persist clipboard text to disk (survives relaunches). Off = keep history in
    // memory for the session only, so nothing sensitive is written to disk.
    var clipboardPersistToDisk: Bool = true
    var playFeedbackSound: Bool = false
    var restoreLayoutMatchByTitle: Bool = true   // else match purely by order
    var overwriteOnStandby: Bool = true          // auto-overwrite Default at sleep (on by default)
    var overwriteOnLock: Bool = false            // auto-overwrite Default on screen lock
    var standbyLayoutID: String = ""             // which layout to overwrite at sleep
    var restoreOnWake: Bool = true               // auto-restore Default on wake (on by default)
    var wakeLayoutID: String = ""                // which layout to restore on wake

    // Translation: use the full Whisper large-v3 model (more accurate, slower)
    // instead of the distilled large-v3 "turbo" (faster, lower accuracy). Off by
    // default so live transcription stays responsive; turn on for hard languages
    // (Thai, Lao, Khmer, Burmese) when the extra latency is acceptable.
    var translationHighAccuracy: Bool = false
    // Last-used translation choices, restored on next launch.
    var translationSourceCode: String = ""       // Whisper code; "" = Automatic (detect)
    var translationTargetCode: String = "en"     // target language code
    var translationAudioSource: String = "system"  // "system" or "mic" (per-app isn't persisted)
    // Dictate Anywhere: Whisper language code for dictation ("" = auto-detect).
    var dictationLanguage: String = ""
    // Show the next calendar meeting (with a Join link) in the menu-bar menu.
    var meetingBarEnabled: Bool = true
    // Where "＋ Calendar Event" writes, remembered from the last choice in the New
    // Event dialog: 0 = Apple Calendar (default), 1 = installed Outlook app (via
    // AppleScript; classic Outlook only), 2 = Outlook on the web (deep link, works
    // with New Outlook too).
    var eventTarget: Int = 0
    // Keystroke visualizer overlay (KeyCastr-style) on/off, restored on launch.
    var keystrokeVizEnabled: Bool = false
    // Conversion tab: currencies pinned to the top (in order) and ones hidden.
    var currencyFavorites: [String] = []
    var currencyHidden: [String] = []
    var currencyDecimals: Int = 4                // decimal places shown for currency values
    /// World Clock column zone ids ("" = None). Empty array = never customized;
    /// `effectiveWorldClockZones` then supplies the defaults. Shared by the
    /// Convert tab's grid and the menu-bar world-clock glance.
    var worldClockZones: [String] = []
    static let defaultWorldClockZones = ["", "Asia/Bangkok", "Asia/Jakarta",
                                         "Asia/Ho_Chi_Minh", "Asia/Kolkata"]
    var effectiveWorldClockZones: [String] {
        worldClockZones.isEmpty ? Settings.defaultWorldClockZones : worldClockZones
    }

    // Configurable shortcuts keyed by SnapRegion.rawValue plus "overwriteLayout"
    var shortcuts: [String: Shortcut] = Settings.defaults()

    // Keys the user has explicitly cleared. Needed because some keys (snap
    // regions, restoreDefault, restorePresentation) ship with a built-in default,
    // so merely removing them on save would let the default reappear on the next
    // launch. Recording the clear here keeps it cleared until reassigned.
    var clearedShortcuts: Set<String> = []

    // F13–F19 launcher: maps key name ("F13"…"F19") to an assignment.
    // A value is either an application bundle path (e.g. "/Applications/Safari.app")
    // or a system task encoded as "system:<taskID>" (see Settings.systemTasks).
    var functionKeyApps: [String: String] = [:]

    // Show the zoom magnifier loupe during an interactive region capture.
    var overlayShowMagnifier: Bool = true
    // Quick Access Overlay: seconds of inactivity before the capture popup
    // auto-closes (hovering it pauses the countdown).
    var overlayAutoCloseSeconds: Int = 10
    // Last user-selected capture region, "x,y,w,h" in global CG coordinates,
    // for the "Screenshot Previous Area" task.
    var lastCaptureRect: String = ""

    /// Configurable launcher slots. Each slot has a user-chosen shortcut stored
    /// in `shortcuts["launcher:slotN"]` plus an assignment in `functionKeyApps`.
    static let launcherSlotCount = 8
    static var launcherSlots: [String] { (1...launcherSlotCount).map { "slot\($0)" } }

    /// Popular macOS system tasks that can be bound to a function key.
    struct SystemTask { let id: String; let title: String }
    static let systemTasks: [SystemTask] = [
        SystemTask(id: "screenshotAreaFile",   title: "Screenshot Selection → Downloads"),
        SystemTask(id: "screenshotAreaClip",   title: "Screenshot Selection → Clipboard"),
        SystemTask(id: "screenshotFullFile",   title: "Screenshot Full Screen → Downloads"),
        SystemTask(id: "screenshotFullClip",   title: "Screenshot Full Screen → Clipboard"),
        SystemTask(id: "screenshotWindowFile", title: "Screenshot Window → Downloads"),
        SystemTask(id: "screenshotWindowClip", title: "Screenshot Window → Clipboard"),
        SystemTask(id: "screenshotFullTimer5", title: "Screenshot Full Screen (5s timer)"),
        SystemTask(id: "scrollingCapture",     title: "Scrolling Capture"),
        SystemTask(id: "screenshotPrevArea",   title: "Screenshot Previous Area"),
        SystemTask(id: "allInOne",             title: "All-in-One Capture Menu"),
        SystemTask(id: "toggleDesktopIcons",   title: "Show/Hide Desktop Icons"),
        SystemTask(id: "ocrArea",              title: "Copy Text from Screen (OCR)"),
        SystemTask(id: "dictate",              title: "Dictate Anywhere (voice to text)"),
        SystemTask(id: "windowSwitcher",       title: "Window Switcher"),
        SystemTask(id: "keystrokeViz",         title: "Keystroke Visualizer (toggle)"),
        SystemTask(id: "clipboardHistory",     title: "Clipboard History"),
        SystemTask(id: "keepAwakeToggle",      title: "Keep Awake (toggle)"),
        SystemTask(id: "forceQuit",            title: "Force Quit App…"),
        SystemTask(id: "commandPalette",       title: "Command Palette"),
        SystemTask(id: "cheatSheet",           title: "Keyboard Shortcuts Cheat Sheet"),
        SystemTask(id: "shelf",                title: "Drag & Drop Shelf"),
        SystemTask(id: "pasteAsPlainText",      title: "Paste as Plain Text"),
        SystemTask(id: "lockScreen",           title: "Lock Screen"),
        SystemTask(id: "sleepDisplay",         title: "Sleep Display"),
        SystemTask(id: "missionControl",       title: "Mission Control"),
        SystemTask(id: "launchpad",            title: "Launchpad"),
        SystemTask(id: "screenSaver",          title: "Start Screen Saver"),
    ]

    /// Human-readable description of a function-key assignment for display.
    static func functionKeyAssignmentTitle(_ value: String?) -> String {
        guard let value = value else { return "None" }
        if value.hasPrefix("system:") {
            let id = String(value.dropFirst("system:".count))
            return systemTasks.first { $0.id == id }?.title ?? "System task"
        }
        return URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
    }

    private init() { load() }

    static func defaults() -> [String: Shortcut] {
        let m = UInt32(controlKey | optionKey)
        return [
            SnapRegion.leftHalf.rawValue:    Shortcut(keyCode: UInt32(kVK_LeftArrow),  modifiers: m),
            SnapRegion.rightHalf.rawValue:   Shortcut(keyCode: UInt32(kVK_RightArrow), modifiers: m),
            SnapRegion.topHalf.rawValue:     Shortcut(keyCode: UInt32(kVK_UpArrow),    modifiers: m),
            SnapRegion.bottomHalf.rawValue:  Shortcut(keyCode: UInt32(kVK_DownArrow),  modifiers: m),
            SnapRegion.topLeft.rawValue:     Shortcut(keyCode: UInt32(kVK_ANSI_U),     modifiers: m),
            SnapRegion.topRight.rawValue:    Shortcut(keyCode: UInt32(kVK_ANSI_I),     modifiers: m),
            SnapRegion.bottomLeft.rawValue:  Shortcut(keyCode: UInt32(kVK_ANSI_J),     modifiers: m),
            SnapRegion.bottomRight.rawValue: Shortcut(keyCode: UInt32(kVK_ANSI_K),     modifiers: m),
            SnapRegion.leftThird.rawValue:   Shortcut(keyCode: UInt32(kVK_ANSI_D),     modifiers: m),
            SnapRegion.centerThird.rawValue: Shortcut(keyCode: UInt32(kVK_ANSI_F),     modifiers: m),
            SnapRegion.rightThird.rawValue:  Shortcut(keyCode: UInt32(kVK_ANSI_G),     modifiers: m),
            SnapRegion.maximize.rawValue:    Shortcut(keyCode: UInt32(kVK_Return),     modifiers: m),
            SnapRegion.center.rawValue:      Shortcut(keyCode: UInt32(kVK_ANSI_C),     modifiers: m),
            "restoreDefault":                Shortcut(keyCode: UInt32(kVK_ANSI_D),     modifiers: UInt32(controlKey | optionKey | shiftKey)),
            "restorePresentation":           Shortcut(keyCode: UInt32(kVK_ANSI_P),     modifiers: UInt32(controlKey | optionKey | shiftKey)),
        ]
    }

    // Codable snapshot
    private struct Snapshot: Codable {
        var launchAtLogin: Bool
        var showInMenuBar: Bool
        var gapBetweenWindows: Int
        var snapshotIntervalSeconds: Int?    // optional for backward compatibility
        var snapToScreenEdges: Bool
        var dragToSnapEnabled: Bool?       // optional for backward compatibility
        var snapFlashEnabled: Bool?
        var clipboardHistoryEnabled: Bool?
        var clipboardAutoPaste: Bool?
        var clipboardPersistToDisk: Bool?
        var playFeedbackSound: Bool
        var restoreLayoutMatchByTitle: Bool
        var overwriteOnStandby: Bool?      // optional for backward compatibility
        var overwriteOnLock: Bool?
        var standbyLayoutID: String?
        var restoreOnWake: Bool?
        var wakeLayoutID: String?
        var translationHighAccuracy: Bool?   // optional for backward compatibility
        var translationSourceCode: String?
        var translationTargetCode: String?
        var translationAudioSource: String?
        var dictationLanguage: String?
        var meetingBarEnabled: Bool?
        var eventTarget: Int?
        var keystrokeVizEnabled: Bool?
        var currencyFavorites: [String]?
        var currencyHidden: [String]?
        var currencyDecimals: Int?
        var worldClockZones: [String]?
        var shortcuts: [String: Shortcut]
        var functionKeyApps: [String: String]?
        var overlayShowMagnifier: Bool?
        var overlayAutoCloseSeconds: Int?
        var lastCaptureRect: String?
        var clearedShortcuts: [String]?   // optional for backward compatibility
    }

    func save() {
        let snap = Snapshot(launchAtLogin: launchAtLogin, showInMenuBar: showInMenuBar,
                            gapBetweenWindows: gapBetweenWindows,
                            snapshotIntervalSeconds: snapshotIntervalSeconds,
                            snapToScreenEdges: snapToScreenEdges,
                            dragToSnapEnabled: dragToSnapEnabled,
                            snapFlashEnabled: snapFlashEnabled,
                            clipboardHistoryEnabled: clipboardHistoryEnabled,
                            clipboardAutoPaste: clipboardAutoPaste,
                            clipboardPersistToDisk: clipboardPersistToDisk,
                            playFeedbackSound: playFeedbackSound,
                            restoreLayoutMatchByTitle: restoreLayoutMatchByTitle,
                            overwriteOnStandby: overwriteOnStandby,
                            overwriteOnLock: overwriteOnLock,
                            standbyLayoutID: standbyLayoutID,
                            restoreOnWake: restoreOnWake,
                            wakeLayoutID: wakeLayoutID,
                            translationHighAccuracy: translationHighAccuracy,
                            translationSourceCode: translationSourceCode,
                            translationTargetCode: translationTargetCode,
                            translationAudioSource: translationAudioSource,
                            dictationLanguage: dictationLanguage,
                            meetingBarEnabled: meetingBarEnabled,
                            eventTarget: eventTarget,
                            keystrokeVizEnabled: keystrokeVizEnabled,
                            currencyFavorites: currencyFavorites,
                            currencyHidden: currencyHidden,
                            currencyDecimals: currencyDecimals,
                            worldClockZones: worldClockZones, shortcuts: shortcuts,
                            functionKeyApps: functionKeyApps,
                            overlayShowMagnifier: overlayShowMagnifier,
                            overlayAutoCloseSeconds: overlayAutoCloseSeconds,
                            lastCaptureRect: lastCaptureRect,
                            clearedShortcuts: Array(clearedShortcuts))
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    // MARK: Backup (export/import — used by the Settings tab and machine moves)

    /// The current preferences as the same JSON blob `save()` persists.
    func exportData() -> Data? {
        save()
        return UserDefaults.standard.data(forKey: defaultsKey)
    }

    /// Replace all preferences with a previously exported blob. Returns false —
    /// changing nothing — if the data isn't a valid settings snapshot.
    @discardableResult
    func importData(_ data: Data) -> Bool {
        guard (try? JSONDecoder().decode(Snapshot.self, from: data)) != nil else { return false }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        load()
        return true
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        launchAtLogin = snap.launchAtLogin
        showInMenuBar = snap.showInMenuBar
        gapBetweenWindows = snap.gapBetweenWindows
        // Enforce a small floor so a tiny/zero interval can't spin the CPU.
        snapshotIntervalSeconds = max(5, snap.snapshotIntervalSeconds ?? 300)
        snapToScreenEdges = snap.snapToScreenEdges
        dragToSnapEnabled = snap.dragToSnapEnabled ?? true
        snapFlashEnabled = snap.snapFlashEnabled ?? true
        clipboardHistoryEnabled = snap.clipboardHistoryEnabled ?? true
        clipboardAutoPaste = snap.clipboardAutoPaste ?? true
        clipboardPersistToDisk = snap.clipboardPersistToDisk ?? true
        playFeedbackSound = snap.playFeedbackSound
        restoreLayoutMatchByTitle = snap.restoreLayoutMatchByTitle
        overwriteOnStandby = snap.overwriteOnStandby ?? true
        overwriteOnLock = snap.overwriteOnLock ?? false
        standbyLayoutID = snap.standbyLayoutID ?? ""
        restoreOnWake = snap.restoreOnWake ?? true
        wakeLayoutID = snap.wakeLayoutID ?? ""
        translationHighAccuracy = snap.translationHighAccuracy ?? false
        translationSourceCode = snap.translationSourceCode ?? ""
        translationTargetCode = snap.translationTargetCode ?? "en"
        translationAudioSource = snap.translationAudioSource ?? "system"
        dictationLanguage = snap.dictationLanguage ?? ""
        meetingBarEnabled = snap.meetingBarEnabled ?? true
        eventTarget = snap.eventTarget ?? 0
        keystrokeVizEnabled = snap.keystrokeVizEnabled ?? false
        currencyFavorites = snap.currencyFavorites ?? []
        currencyHidden = snap.currencyHidden ?? []
        currencyDecimals = snap.currencyDecimals ?? 4
        worldClockZones = snap.worldClockZones ?? []
        // Merge so new regions added in updates still get defaults
        var merged = Settings.defaults()
        for (k, v) in snap.shortcuts { merged[k] = v }
        // Prune orphaned shortcut keys left by older builds (e.g. bare
        // "restoreLayout", "overwriteLayout", "saveLayout"). These match no action
        // in the current app, so they register no hotkey yet still reserve their
        // key combo — blocking that combo from being assigned to anything else.
        // Keep only keys the app can actually act on.
        let validRegions = Set(SnapRegion.allCases.map { $0.rawValue })
        let validFixed: Set<String> = ["restoreDefault", "restorePresentation",
                                       "overwriteDefault", "overwritePresentation"]
        merged = merged.filter { key, _ in
            validRegions.contains(key) || validFixed.contains(key)
                || key.hasPrefix("restoreLayout:") || key.hasPrefix("overwriteLayout:")
                || key.hasPrefix("launcher:")
        }
        // Re-apply explicit clears. A defaulted key the user cleared would other-
        // wise be re-seeded from Settings.defaults() above; drop it again unless
        // the user has since reassigned it (in which case it's in the stored set).
        clearedShortcuts = Set(snap.clearedShortcuts ?? [])
        for k in clearedShortcuts where snap.shortcuts[k] == nil {
            merged.removeValue(forKey: k)
        }
        shortcuts = merged
        functionKeyApps = snap.functionKeyApps ?? [:]
        overlayShowMagnifier = snap.overlayShowMagnifier ?? true
        overlayAutoCloseSeconds = max(1, snap.overlayAutoCloseSeconds ?? 10)
        lastCaptureRect = snap.lastCaptureRect ?? ""

        // One-time migration: older builds keyed launchers by fixed keys
        // (F16…F19). Move each to slot1…slot4 and bind that slot's shortcut to
        // the same key so existing launchers keep working.
        let fkMigration: [(String, Int)] = [("F16", kVK_F16), ("F17", kVK_F17),
                                            ("F18", kVK_F18), ("F19", kVK_F19)]
        var migratedLaunchers = false
        for (idx, (fk, code)) in fkMigration.enumerated() {
            guard let assignment = functionKeyApps[fk] else { continue }
            let slot = "slot\(idx + 1)"
            if functionKeyApps[slot] == nil { functionKeyApps[slot] = assignment }
            if shortcuts["launcher:\(slot)"] == nil {
                shortcuts["launcher:\(slot)"] = Shortcut(keyCode: UInt32(code), modifiers: 0)
            }
            functionKeyApps[fk] = nil
            migratedLaunchers = true
        }
        if migratedLaunchers { save() }

        // One-time migration: older installs had auto-save-on-sleep and
        // auto-restore-on-wake defaulting OFF. The app now ships them ON so the
        // Default layout is kept current and restored on wake. Force them on
        // once; after that the user's own toggle choices are respected.
        let migrationKey = "WindowSnapSleepWakeDefaultsMigratedV1"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            overwriteOnStandby = true
            restoreOnWake = true
            UserDefaults.standard.set(true, forKey: migrationKey)
            save()
        }
    }

    func resetShortcuts() {
        shortcuts = Settings.defaults()
        clearedShortcuts.removeAll()
        save()
    }

    /// Assign a shortcut to a key. Cancels any prior explicit clear of that key.
    func setShortcut(_ key: String, _ shortcut: Shortcut) {
        shortcuts[key] = shortcut
        clearedShortcuts.remove(key)
        save()
    }

    /// Clear a key's shortcut so it stays cleared across launches (even for keys
    /// that have a built-in default, which would otherwise reappear).
    func clearShortcut(_ key: String) {
        shortcuts[key] = nil
        clearedShortcuts.insert(key)
        save()
    }
}
