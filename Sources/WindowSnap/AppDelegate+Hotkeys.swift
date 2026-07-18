import Cocoa
import Carbon.HIToolbox

extension AppDelegate {
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
    func forceQuitAndReopen(spec: String) {
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
    func runSystemTask(_ id: String) {
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
        case "dictate":
            if #available(macOS 14.0, *) { Dictation.shared.toggle() }
        case "windowSwitcher":
            WindowSwitcher.shared.toggle()
        case "keystrokeViz":
            KeystrokeVisualizer.shared.toggle()
        case "clipboardHistory":
            ClipboardHistoryPanel.shared.show()
        case "keepAwakeToggle":
            KeepAwake.shared.toggle()
        case "forceQuit":
            ForceQuitPanel.shared.show()
        case "commandPalette":
            openCommandPalette()
        case "cheatSheet":
            CheatSheetOverlay.shared.toggle()
        case "shelf":
            ShelfController.shared.toggle()
        case "pasteAsPlainText":
            pasteAsPlainText()
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

    func runProcess(_ path: String, _ args: [String]) {
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
}
