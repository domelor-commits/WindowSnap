import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import UniformTypeIdentifiers

extension SettingsWindowController {
    func buildFunctionKeyMenu(for fk: String, popup: NSPopUpButton) {
        let menu = NSMenu()

        let none = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
        none.representedObject = "none"
        menu.addItem(none)
        menu.addItem(.separator())

        for task in Settings.systemTasks {
            let it = NSMenuItem(title: task.title, action: nil, keyEquivalent: "")
            it.representedObject = "system:\(task.id)"
            menu.addItem(it)
        }
        menu.addItem(.separator())

        // If an app (launch or force-quit-and-reopen) is currently assigned, show
        // it as a selectable item so the popup can display it as the selection.
        let current = Settings.shared.functionKeyApps[fk]
        if let path = current, path.hasPrefix("restart:") {
            // Spec is "<launchAppPath>" or "<launchAppPath>\n<killProcessName>".
            let spec = String(path.dropFirst("restart:".count))
            let parts = spec.components(separatedBy: "\n")
            let name = URL(fileURLWithPath: parts[0]).deletingPathExtension().lastPathComponent
            let killSuffix = (parts.count > 1 && !parts[1].isEmpty) ? " (quit “\(parts[1])”)" : ""
            let it = NSMenuItem(title: "Force Quit & Reopen: \(name)\(killSuffix)", action: nil, keyEquivalent: "")
            it.representedObject = path
            menu.addItem(it)
        } else if let path = current, !path.hasPrefix("system:") {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let it = NSMenuItem(title: "Application: \(name)", action: nil, keyEquivalent: "")
            it.representedObject = path
            menu.addItem(it)
        }
        let choose = NSMenuItem(title: "Choose Application…", action: nil, keyEquivalent: "")
        choose.representedObject = "choose"
        menu.addItem(choose)
        let chooseRestart = NSMenuItem(title: "Force Quit & Reopen Application…", action: nil, keyEquivalent: "")
        chooseRestart.representedObject = "chooseRestart"
        menu.addItem(chooseRestart)

        popup.menu = menu

        // Select the item matching the stored value, defaulting to "None".
        if let cur = current,
           let idx = menu.items.firstIndex(where: { ($0.representedObject as? String) == cur }) {
            popup.selectItem(at: idx)
        } else {
            popup.selectItem(at: 0)
        }
    }

    @objc func functionKeyPopupChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("fkPopup:") else { return }
        let fk = String(raw.dropFirst("fkPopup:".count))
        let rep = sender.selectedItem?.representedObject as? String

        switch rep {
        case "none", nil:
            Settings.shared.functionKeyApps.removeValue(forKey: fk)
        case "choose":
            if let url = chooseApplication(for: fk) {
                Settings.shared.functionKeyApps[fk] = url.path
            }
            // Rebuild so the chosen app appears (or selection reverts on cancel).
            buildFunctionKeyMenu(for: fk, popup: sender)
        case "chooseRestart":
            if let url = chooseApplication(for: fk),
               let killName = promptForKillProcessName(appURL: url) {
                // Empty kill name → quit the app's own process; otherwise store
                // the separate process name to force quit (e.g. "java-arm").
                if killName.isEmpty {
                    Settings.shared.functionKeyApps[fk] = "restart:" + url.path
                } else {
                    Settings.shared.functionKeyApps[fk] = "restart:" + url.path + "\n" + killName
                }
            }
            buildFunctionKeyMenu(for: fk, popup: sender)
        default:
            // A system task, or an existing app/restart assignment.
            Settings.shared.functionKeyApps[fk] = rep
        }

        Settings.shared.save()
        onShortcutsChanged?()
    }

    /// Presents an app picker for a function key. Returns the chosen .app URL,
    /// or nil if cancelled.
    func chooseApplication(for fk: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Application for \(fk)"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks which process name to force quit for a "Force Quit & Reopen"
    /// assignment. Some apps run under a different process than their bundle
    /// (e.g. thinkorswim runs as "java-arm"). Returns the entered name (possibly
    /// empty = quit the app itself), or nil if the user cancelled.
    func promptForKillProcessName(appURL: URL) -> String? {
        let appName = appURL.deletingPathExtension().lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Force-quit target for \(appName)"
        alert.informativeText = "Enter the process name to force quit when the key is pressed. "
            + "Some apps run under a different process than their name — for thinkorswim it is its "
            + "Java runtime, “java-arm”. Leave blank to force quit \(appName) itself."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "e.g. java-arm (blank = the app itself)"
        // Pre-fill thinkorswim's known process name for convenience.
        if appName.lowercased().contains("thinkorswim") { field.stringValue = "java-arm" }
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc func grantAccessibility() {
        // macOS won't let an app grant itself this permission; we can only
        // prompt and open the pane. Pressing this always opens the Accessibility
        // settings so you can grant or just check the current state. If access
        // isn't yet trusted, also fire the system prompt.
        if !AXIsProcessTrusted() {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        // Re-check shortly after, in case the user toggles it right away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshAccessibilityStatus() }
    }

    func refreshAccessibilityStatus() {
        guard let label = accessibilityStatusLabel else { return }
        if AXIsProcessTrusted() {
            label.stringValue = "✓ Granted"
            label.textColor = .systemGreen
        } else {
            label.stringValue = "Not granted yet"
            label.textColor = .systemRed
        }
    }

    /// Draws a small glyph showing which portion of a monitor a snap region
    /// fills: a rounded screen outline with the target area shaded. Original
    /// artwork generated from the same SnapRegion geometry the app uses.
    static func regionIcon(for key: String) -> NSImage {
        let size = NSSize(width: 26, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()

        let outer = NSRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2)
        // Screen outline.
        let frame = NSBezierPath(roundedRect: outer, xRadius: 2.5, yRadius: 2.5)
        NSColor.secondaryLabelColor.setStroke()
        frame.lineWidth = 1
        frame.stroke()

        // Compute the filled sub-rect using the region geometry, in a TOP-LEFT
        // logical box, then flip to this view's bottom-left coords for drawing.
        if let region = SnapRegion(rawValue: key) {
            let box = CGRect(x: 0, y: 0, width: outer.width, height: outer.height)
            var f = region.frame(in: box)            // top-left origin
            // Flip vertically into AppKit's bottom-left space.
            f.origin.y = outer.height - f.origin.y - f.height
            f = f.insetBy(dx: 1, dy: 1)
            f.origin.x += outer.minX
            f.origin.y += outer.minY
            if f.width > 0, f.height > 0 {
                let fill = NSBezierPath(roundedRect: f, xRadius: 1.5, yRadius: 1.5)
                NSColor.white.setFill()
                fill.fill()
                // Outline so the white fill stays visible on light backgrounds.
                NSColor.secondaryLabelColor.setStroke()
                fill.lineWidth = 0.75
                fill.stroke()
            }
        }

        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    // MARK: - Tab 4: Log
    /// Builds a restore row for a pinned layout: a Restore button, a shortcut
    /// recorder, and a Clear button. Tracked so widths can be set after layout.
    func makePinnedRestoreRow(id: String, name: String) -> NSView {
        let restoreBtn = NSButton(title: "Restore \(name)", target: self,
                                  action: #selector(restorePinnedButton(_:)))
        restoreBtn.bezelStyle = .rounded
        restoreBtn.identifier = NSUserInterfaceItemIdentifier("pinnedRestore:\(id)")
        restoreBtn.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let shortcutKey = (id == LayoutManager.defaultLayoutID) ? "restoreDefault" : "restorePresentation"
        let recorder = ShortcutRecorder(
            regionKey: shortcutKey,
            current: Settings.shared.shortcuts[shortcutKey]
        ) { [weak self] newShortcut in
            Settings.shared.setShortcut(shortcutKey, newShortcut)
            self?.onShortcutsChanged?()
        }
        recorder.onClear = { [weak self] in
            Settings.shared.clearShortcut(shortcutKey)
            self?.onShortcutsChanged?()
        }
        recorder.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pinnedRestoreRecorders[id] = recorder

        let clearBtn = NSButton(title: "Clear", target: self, action: #selector(clearPinnedShortcut(_:)))
        clearBtn.bezelStyle = .rounded
        clearBtn.identifier = NSUserInterfaceItemIdentifier("pinnedClear:\(shortcutKey)")
        clearBtn.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [restoreBtn, recorder, clearBtn])
        row.orientation = .horizontal
        row.spacing = 8
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        pinnedRestoreRows.append(row)
        return row
    }

    @objc func restorePinnedButton(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("pinnedRestore:") else { return }
        let id = String(raw.dropFirst("pinnedRestore:".count))
        if let layout = LayoutManager.loadPinned(id) {
            LayoutManager.restore(layout)
        } else {
            NSSound.beep()
            LayoutManager.notify("No \(LayoutManager.pinnedName(for: id)) layout",
                                 "Select it in the list and Save New to capture it.")
        }
    }

    @objc func clearPinnedShortcut(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("pinnedClear:") else { return }
        let key = String(raw.dropFirst("pinnedClear:".count))
        Settings.shared.clearShortcut(key)
        // Reset the recorder title for whichever pinned id maps to this key.
        let id = (key == "restoreDefault") ? LayoutManager.defaultLayoutID : LayoutManager.presentationLayoutID
        pinnedRestoreRecorders[id]?.title = "Click to set"
        onShortcutsChanged?()
    }

    /// Builds the activity-log section (used at the bottom of the Layouts tab).
    func makeLogSection() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.textColor = .labelColor
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        logTextView = textView

        let clearButton = NSButton(title: "Clear Log", target: self, action: #selector(clearLog))
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "Activity log (newest at the top):")
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        heading.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(heading)
        container.addSubview(clearButton)
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: container.topAnchor),
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor),

            clearButton.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 110),
        ])

        refreshLog()
        refreshAccessibilityStatus()
        // Live-refresh when new entries are logged.
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshLog),
            name: Logger.didLogNotification, object: nil)
        return container
    }

    func refreshLogTextValue() {
        guard let tv = logTextView else { return }
        tv.string = Logger.formattedLines().joined(separator: "\n")
        // Newest is now the first line — keep the view scrolled to the top.
        tv.scrollToBeginningOfDocument(nil)
    }

    @objc func refreshLog() {
        DispatchQueue.main.async { [weak self] in self?.refreshLogTextValue() }
    }

    @objc func clearLog() {
        Logger.clear()
        refreshLogTextValue()
    }

}
