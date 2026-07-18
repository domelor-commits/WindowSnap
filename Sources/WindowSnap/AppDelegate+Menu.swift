import Cocoa

extension AppDelegate {
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

    // MARK: Main menu (standard macOS app menu bar)
    /// Builds the top-of-screen menu bar shown when a WindowSnap window is
    /// focused. Without this, a `.regular` app has no Edit menu — so no
    /// Cut/Copy/Paste/Undo/Select-All in the annotator or text fields — and no
    /// standard About / Settings / Hide / Quit shortcuts.
    func setupMainMenu() {
        let appName = "WindowSnap"
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let perms = appMenu.addItem(withTitle: "Permissions Setup…", action: #selector(openPermissions), keyEquivalent: "")
        perms.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu — enables standard text editing in fields and the annotator.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")

        // Window menu
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
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
        updateKeepAwakeStatusDisplay()   // restore countdown/badge if already active
    }

    // MARK: Keep Awake menu-bar countdown

    /// Start/stop the once-a-second title refresh when Keep Awake turns on/off.
    @objc func keepAwakeChanged() {
        updateKeepAwakeStatusDisplay()
        let timed = KeepAwake.shared.isActive && KeepAwake.shared.expiry != nil
        if timed, keepAwakeDisplayTimer == nil {
            let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.updateKeepAwakeStatusDisplay()
            }
            RunLoop.main.add(t, forMode: .common)
            keepAwakeDisplayTimer = t
        } else if !timed {
            keepAwakeDisplayTimer?.invalidate(); keepAwakeDisplayTimer = nil
        }
    }

    /// Show a live countdown (timed) or an ∞ badge (indefinite) beside the menu
    /// bar icon while Keep Awake is on; icon only when off.
    func updateKeepAwakeStatusDisplay() {
        guard let button = statusItem?.button else { return }
        let ka = KeepAwake.shared
        if ka.isActive, let e = ka.expiry {
            let secs = max(0, Int(e.timeIntervalSinceNow))
            button.title = " " + AppDelegate.compactCountdown(secs)
            button.imagePosition = .imageLeading
            if secs == 0 { keepAwakeDisplayTimer?.invalidate(); keepAwakeDisplayTimer = nil }
        } else if ka.isActive {
            button.title = " ∞"
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    /// Compact "M:SS" (under an hour) or "H:MM:SS" countdown.
    static func compactCountdown(_ secs: Int) -> String {
        let s = max(0, secs)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Populate (or repopulate) the status-bar menu. Called when the menu is
    /// created and again each time it's about to open, so the saved-layouts
    /// submenu always reflects the latest rolling 'Saved' capture.
    func buildMenu(into menu: NSMenu) {
        menu.removeAllItems()

        func titleWithShortcut(_ name: String, key: String) -> String {
            if let sc = Settings.shared.shortcuts[key] { return "\(name)   \(sc.display)" }
            return name
        }
        func add(_ title: String, _ action: Selector, to m: NSMenu, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self; m.addItem(i); return i
        }

        // Next meeting(s) (opt-in) at the very top, with a one-click Join. When
        // several invites overlap the same slot, list them all so you can choose.
        if Settings.shared.meetingBarEnabled {
            func whenLabel(_ start: Date) -> String {
                let mins = Int(start.timeIntervalSinceNow / 60)
                if mins <= 0 { return "now" }
                if mins < 60 { return "in \(mins) min" }
                let f = DateFormatter(); f.timeStyle = .short
                return "at \(f.string(from: start))"
            }
            let meetings = MeetingBar.shared.overlappingMeetings()
            if meetings.count == 1, let m = meetings.first {
                let mi = NSMenuItem(title: "📅  \(m.title) — \(whenLabel(m.start))",
                                    action: nil, keyEquivalent: "")
                mi.isEnabled = false
                menu.addItem(mi)
                if let url = m.joinURL {
                    let join = add("      Join Meeting", #selector(joinMeeting(_:)), to: menu)
                    join.representedObject = url.absoluteString
                }
                menu.addItem(.separator())
            } else if meetings.count > 1 {
                // Header, then one clickable "Join" row per overlapping meeting.
                let header = NSMenuItem(title: "📅  Overlapping meetings — choose one to join",
                                        action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for m in meetings {
                    let title = "      \(m.title) — \(whenLabel(m.start))"
                    if let url = m.joinURL {
                        let item = add(title, #selector(joinMeeting(_:)), to: menu)
                        item.representedObject = url.absoluteString
                    } else {
                        // No recognizable video link — show it but grey it out.
                        let item = NSMenuItem(title: "\(title)  (no link)", action: nil, keyEquivalent: "")
                        item.isEnabled = false
                        menu.addItem(item)
                    }
                }
                menu.addItem(.separator())
            }
        }

        // World clock glance: current time in the zones picked in the Convert
        // tab's World Time grid (column 0 is "home" — that's the menu-bar clock
        // already, so it's skipped). Rebuilt on every open via menuNeedsUpdate,
        // so the times are always current.
        let zones = Settings.shared.effectiveWorldClockZones.dropFirst().filter { !$0.isEmpty }
        if !zones.isEmpty {
            let fmt = DateFormatter()
            fmt.dateFormat = "EEE HH:mm"
            let labels = Dictionary(uniqueKeysWithValues:
                UnitCatalog.zoneGroups.flatMap { $0.zones }.map { ($0.id, $0.label) })
            for id in zones {
                guard let tz = TimeZone(identifier: id) else { continue }
                fmt.timeZone = tz
                // "Bangkok, Thailand" → "Bangkok"; fall back to the raw id's city part.
                let city = labels[id]?.components(separatedBy: ",").first
                    ?? id.components(separatedBy: "/").last?.replacingOccurrences(of: "_", with: " ")
                    ?? id
                let item = NSMenuItem(title: "🕓  \(city)  \(fmt.string(from: Date()))",
                                      action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        _ = add("Open WindowSnap…", #selector(openSettings), to: menu, key: ",")
        _ = add("Permissions Setup…", #selector(openPermissions), to: menu)
        menu.addItem(.separator())

        // Snap ▸ — all window-placement actions in one tidy submenu.
        let snapParent = NSMenuItem(title: "Snap", action: nil, keyEquivalent: "")
        let snapMenu = NSMenu()
        let snaps: [(String, SnapRegion)] = [
            ("Left Half", .leftHalf), ("Right Half", .rightHalf),
            ("Top Half", .topHalf), ("Bottom Half", .bottomHalf),
            ("Top Left", .topLeft), ("Top Right", .topRight),
            ("Bottom Left", .bottomLeft), ("Bottom Right", .bottomRight),
            ("Left Third", .leftThird), ("Center Third", .centerThird), ("Right Third", .rightThird),
            ("Maximize", .maximize), ("Center", .center),
        ]
        for (label, region) in snaps {
            let i = add(titleWithShortcut(label, key: region.rawValue), #selector(menuSnap(_:)), to: snapMenu)
            i.representedObject = region.rawValue
        }
        menu.addItem(snapParent); menu.setSubmenu(snapMenu, for: snapParent)

        // Layouts: Default restore + a submenu of saved layouts.
        let defaultRestore = add(titleWithShortcut("Restore Default Layout", key: "restoreDefault"),
                                 #selector(restoreDefaultFromMenu), to: menu)
        defaultRestore.isEnabled = (LayoutManager.loadDefault() != nil)
        let layouts = LayoutManager.loadAll()
        if layouts.isEmpty {
            let none = NSMenuItem(title: "No saved layouts", action: nil, keyEquivalent: "")
            none.isEnabled = false; menu.addItem(none)
        } else {
            let restoreMenu = NSMenu()
            for (i, layout) in layouts.enumerated() {
                let item = add(titleWithShortcut(layout.name, key: "restoreLayout:\(layout.id)"),
                               #selector(restoreLayoutAtIndex(_:)), to: restoreMenu)
                item.tag = i
            }
            let restoreParent = NSMenuItem(title: "Restore Saved Layout", action: nil, keyEquivalent: "")
            menu.addItem(restoreParent); menu.setSubmenu(restoreMenu, for: restoreParent)
        }
        menu.addItem(.separator())

        // Tools ▸ — capture, clipboard, palette, shelf, force quit.
        let toolsParent = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        let toolsMenu = NSMenu()
        let ocrSlot = Settings.shared.functionKeyApps.first(where: { $0.value == "system:ocrArea" })?.key
        let ocrKey = ocrSlot.flatMap { Settings.shared.shortcuts["launcher:\($0)"] }?.display
        _ = add(ocrKey.map { "Copy Text from Screen   \($0)" } ?? "Copy Text from Screen",
                #selector(ocrScreenRegion), to: toolsMenu)
        _ = add("Dictate Anywhere", #selector(startDictation), to: toolsMenu)
        _ = add("Window Switcher", #selector(openWindowSwitcher), to: toolsMenu)
        let kv = add("Keystroke Visualizer", #selector(toggleKeystrokeViz), to: toolsMenu)
        kv.state = KeystrokeVisualizer.shared.isActive ? .on : .off
        _ = add("Clipboard History…", #selector(openClipboardHistory), to: toolsMenu)
        _ = add("Command Palette…", #selector(openCommandPalette), to: toolsMenu)
        _ = add("Drag & Drop Shelf", #selector(toggleShelf), to: toolsMenu)
        _ = add("Force Quit App…", #selector(openForceQuit), to: toolsMenu)
        menu.addItem(toolsParent); menu.setSubmenu(toolsMenu, for: toolsParent)

        // Keep Awake ("caffeine") submenu: off / indefinite / timed.
        let ka = KeepAwake.shared
        let kaParent = NSMenuItem(title: ka.isActive ? "Keep Awake — \(ka.statusDescription)" : "Keep Awake",
                                  action: nil, keyEquivalent: "")
        let kaSub = NSMenu()
        for (label, tag) in [("Off", "off"), ("Indefinitely", "inf"),
                             ("For 30 Minutes", "30"), ("For 1 Hour", "60"), ("For 2 Hours", "120")] {
            let it = add(label, #selector(keepAwakeSelected(_:)), to: kaSub)
            it.representedObject = tag
            if (!ka.isActive && tag == "off") || (ka.isActive && ka.expiry == nil && tag == "inf") { it.state = .on }
        }
        kaParent.submenu = kaSub
        menu.addItem(kaParent)

        _ = add("Keyboard Shortcuts…", #selector(showCheatSheet), to: menu)
        menu.addItem(.separator())

        _ = add("What’s New…", #selector(showWhatsNew), to: menu)
        if UpdaterManager.shared.isConfigured {
            _ = add("Check for Updates…", #selector(checkForUpdates), to: menu)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WindowSnap", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func joinMeeting(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }
    @objc func startDictation() { if #available(macOS 14.0, *) { Dictation.shared.toggle() } }
    @objc func openWindowSwitcher() { WindowSwitcher.shared.toggle() }
    @objc func toggleKeystrokeViz() { KeystrokeVisualizer.shared.toggle() }
    @objc func showCheatSheet() { CheatSheetOverlay.shared.toggle() }
    @objc func showWhatsNew() { WhatsNewWindowController.shared.show() }
    @objc func checkForUpdates() { UpdaterManager.shared.checkForUpdates() }

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

    @objc func openClipboardHistory() { ClipboardHistoryPanel.shared.show() }

    @objc func openForceQuit() { ForceQuitPanel.shared.show() }

    @objc func toggleShelf() { ShelfController.shared.toggle() }

    /// Strips formatting from the clipboard and pastes the plain text into the
    /// frontmost app (like "Paste and Match Style", but works everywhere).
    func pasteAsPlainText() {
        let pb = NSPasteboard.general
        guard let s = pb.string(forType: .string) else { NSSound.beep(); return }
        pb.clearContents()
        pb.setString(s, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { AppDelegate.synthesizeCmdV() }
    }

    /// Posts a synthetic ⌘V to the frontmost app (needs Accessibility).
    static func synthesizeCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9   // 'v'
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    @objc func openCommandPalette() { CommandPalette.shared.show(actions: buildPaletteActions()) }

    @objc func otherAppActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.processIdentifier != ProcessInfo.processInfo.processIdentifier { lastActiveOtherApp = app }
    }

    /// Runs a palette action from the in-window tab, first handing focus back to
    /// the previously-active app so window actions (snaps) target it.
    func runPaletteActionRestoringFocus(_ action: PaletteAction) {
        lastActiveOtherApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { action.run() }
    }

    /// Assembles every runnable command for the palette. Built fresh each open so
    /// the current saved layouts and launcher assignments are included.
    func buildPaletteActions() -> [PaletteAction] {
        var a: [PaletteAction] = []

        let snaps: [(String, SnapRegion)] = [
            ("Left Half", .leftHalf), ("Right Half", .rightHalf), ("Top Half", .topHalf),
            ("Bottom Half", .bottomHalf), ("Top Left", .topLeft), ("Top Right", .topRight),
            ("Bottom Left", .bottomLeft), ("Bottom Right", .bottomRight), ("Left Third", .leftThird),
            ("Center Third", .centerThird), ("Right Third", .rightThird), ("Maximize", .maximize),
            ("Center", .center),
        ]
        for (label, region) in snaps {
            a.append(PaletteAction(title: "Snap: \(label)", subtitle: "Window") { [weak self] in self?.snap(region) })
        }

        a.append(PaletteAction(title: "Restore Default Layout", subtitle: "Layout") { [weak self] in
            self?.restorePinned(LayoutManager.defaultLayoutID) })
        a.append(PaletteAction(title: "Restore Presentation Layout", subtitle: "Layout") { [weak self] in
            self?.restorePinned(LayoutManager.presentationLayoutID) })
        for layout in LayoutManager.loadAll() {
            let id = layout.id
            a.append(PaletteAction(title: "Restore Layout: \(layout.name)", subtitle: "Layout") { [weak self] in
                self?.performRestore(layoutID: id) })
        }
        a.append(PaletteAction(title: "Overwrite Default Layout", subtitle: "Layout") { [weak self] in
            self?.overwriteLayoutViaShortcut(id: LayoutManager.defaultLayoutID) })
        a.append(PaletteAction(title: "Overwrite Presentation Layout", subtitle: "Layout") { [weak self] in
            self?.overwriteLayoutViaShortcut(id: LayoutManager.presentationLayoutID) })

        for task in Settings.systemTasks {
            let id = task.id
            a.append(PaletteAction(title: task.title, subtitle: "Action") { [weak self] in self?.runSystemTask(id) })
        }

        for slot in Settings.launcherSlots {
            guard let assignment = Settings.shared.functionKeyApps[slot], !assignment.isEmpty else { continue }
            let title = Settings.functionKeyAssignmentTitle(assignment)
            a.append(PaletteAction(title: "Launch: \(title)", subtitle: "Launcher") { [weak self] in
                self?.performFunctionKeyAction(assignment) })
        }

        a.append(PaletteAction(title: "Open WindowSnap Settings", subtitle: "App") { [weak self] in self?.settingsWindow.show() })
        a.append(PaletteAction(title: "Permissions Setup", subtitle: "App") { [weak self] in self?.showPermissions() })
        return a
    }

    @objc func keepAwakeSelected(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        switch tag {
        case "off": KeepAwake.shared.deactivate()
        case "inf": KeepAwake.shared.activate(duration: nil)
        default:    if let m = Int(tag) { KeepAwake.shared.activate(duration: TimeInterval(m * 60)) }
        }
    }

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

}
