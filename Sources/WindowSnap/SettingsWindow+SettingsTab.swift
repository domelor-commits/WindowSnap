import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import UniformTypeIdentifiers

extension SettingsWindowController {
    // MARK: - Tab: Settings
    func makeSettingsTab() -> NSTabViewItem {
        let doc = NSStackView()
        doc.addArrangedSubview(sectionHeader("Settings"))
        let s = Settings.shared

        // Reflect the persisted preference (default on) OR an actual registered
        // login item — whichever is true — so the box shows checked by default.
        let launch = checkbox("Launch WindowSnap at login",
                              state: LoginItem.isEnabled() || Settings.shared.launchAtLogin,
                              action: #selector(toggleLaunchAtLogin(_:)))
        if !LoginItem.isAvailable {
            launch.isEnabled = false
            launch.toolTip = "Requires macOS 13 or later."
        }
        doc.addArrangedSubview(launch)
        doc.addArrangedSubview(checkbox("Snap windows when dragged to a screen edge or corner",
            state: s.dragToSnapEnabled, action: #selector(toggleDragToSnap(_:))))
        doc.addArrangedSubview(checkbox("Flash the target area when snapping with the keyboard",
            state: s.snapFlashEnabled, action: #selector(toggleSnapFlash(_:))))
        doc.addArrangedSubview(checkbox("Keep a clipboard history",
            state: s.clipboardHistoryEnabled, action: #selector(toggleClipboardHistory(_:))))
        doc.addArrangedSubview(checkbox("Paste the chosen clip into the frontmost app automatically",
            state: s.clipboardAutoPaste, action: #selector(toggleClipboardAutoPaste(_:))))
        doc.addArrangedSubview(checkbox("Save clipboard history to disk (off keeps it in memory for this session only)",
            state: s.clipboardPersistToDisk, action: #selector(toggleClipboardPersist(_:))))
        doc.addArrangedSubview(checkbox("When my Mac goes on standby or is locked, overwrite the Default layout with the current windows",
            state: s.overwriteOnStandby || s.overwriteOnLock, action: #selector(toggleOverwriteOnStandbyOrLock(_:))))
        doc.addArrangedSubview(checkbox("When my Mac wakes from standby, restore windows to the Default layout",
            state: s.restoreOnWake, action: #selector(toggleRestoreOnWake(_:))))
        doc.addArrangedSubview(checkbox("Show magnifier while selecting a screen capture",
            state: s.overlayShowMagnifier, action: #selector(toggleShowMagnifier(_:))))
        doc.addArrangedSubview(checkbox("Show my next meeting in the menu (requires Calendar access)",
            state: s.meetingBarEnabled, action: #selector(toggleMeetingBar(_:))))
        doc.addArrangedSubview(checkbox("Show pressed keys on screen (keystroke visualizer, for demos & recordings)",
            state: s.keystrokeVizEnabled, action: #selector(toggleKeystrokeVizSetting(_:))))

        // Dictation language picker (used by "Dictate Anywhere").
        let dictRow = NSStackView()
        dictRow.orientation = .horizontal; dictRow.spacing = 8
        dictRow.addArrangedSubview(NSTextField(labelWithString: "Dictation language:"))
        let dictPopup = NSPopUpButton()
        dictPopup.addItem(withTitle: "Automatic (detect)")
        dictPopup.lastItem?.representedObject = ""
        let dictLangs: [(String, String)] = [
            ("English", "en"), ("Chinese", "zh"), ("Cantonese", "yue"), ("Thai", "th"),
            ("Malay", "ms"), ("Indonesian", "id"), ("Vietnamese", "vi"), ("Tagalog", "tl"),
            ("Japanese", "ja"), ("Korean", "ko"), ("Spanish", "es"), ("French", "fr"),
            ("German", "de"), ("Hindi", "hi"), ("Arabic", "ar"),
        ]
        for (n, c) in dictLangs {
            dictPopup.addItem(withTitle: n); dictPopup.lastItem?.representedObject = c
        }
        for item in dictPopup.itemArray where (item.representedObject as? String) == s.dictationLanguage {
            dictPopup.select(item)
        }
        dictPopup.target = self; dictPopup.action = #selector(dictationLanguageChanged(_:))
        dictRow.addArrangedSubview(dictPopup)
        doc.addArrangedSubview(dictRow)

        // Accessibility access row (moved here from the Layouts tab).
        let grantRow = NSStackView()
        grantRow.orientation = .horizontal
        grantRow.spacing = 10
        let grantButton = NSButton(title: "Grant Accessibility Access…",
                                   target: self, action: #selector(grantAccessibility))
        grantButton.bezelStyle = .rounded
        accessibilityStatusLabel = NSTextField(labelWithString: "")
        accessibilityStatusLabel.font = .systemFont(ofSize: 11)
        grantRow.addArrangedSubview(grantButton)
        grantRow.addArrangedSubview(accessibilityStatusLabel)
        doc.addArrangedSubview(grantRow)
        refreshAccessibilityStatus()

        // Periodic snapshot interval (seconds). Controls how often the rolling
        // "Saved <timestamp>" capture is written to the saved-layouts list. That
        // latest capture is what feeds the Default layout at sleep.
        let snapRow = NSStackView()
        snapRow.orientation = .horizontal
        snapRow.spacing = 8
        let snapLabel = NSTextField(labelWithString: "Periodic snapshot to “Saved” every (seconds):")
        let snapField = NSTextField(string: "\(s.snapshotIntervalSeconds)")
        snapField.translatesAutoresizingMaskIntoConstraints = false
        snapField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        snapField.target = self
        snapField.action = #selector(snapshotIntervalChanged(_:))
        let snapStepper = NSStepper()
        snapStepper.minValue = 5; snapStepper.maxValue = 3600; snapStepper.increment = 5
        snapStepper.integerValue = s.snapshotIntervalSeconds
        snapStepper.target = self; snapStepper.action = #selector(snapshotIntervalStepped(_:))
        self.snapshotIntervalField = snapField
        self.snapshotIntervalStepper = snapStepper
        snapRow.addArrangedSubview(snapLabel)
        snapRow.addArrangedSubview(snapField)
        snapRow.addArrangedSubview(snapStepper)
        doc.addArrangedSubview(snapRow)

        // Quick Access Overlay auto-close (seconds). Hovering pauses the timer.
        let ovRow = NSStackView()
        ovRow.orientation = .horizontal
        ovRow.spacing = 8
        let ovLabel = NSTextField(labelWithString: "Auto-close capture popup after (seconds):")
        let ovField = NSTextField(string: "\(s.overlayAutoCloseSeconds)")
        ovField.translatesAutoresizingMaskIntoConstraints = false
        ovField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        ovField.target = self
        ovField.action = #selector(overlayCloseChanged(_:))
        let ovStepper = NSStepper()
        ovStepper.minValue = 1; ovStepper.maxValue = 120; ovStepper.increment = 1
        ovStepper.integerValue = s.overlayAutoCloseSeconds
        ovStepper.target = self; ovStepper.action = #selector(overlayCloseStepped(_:))
        self.overlayCloseField = ovField
        self.overlayCloseStepper = ovStepper
        ovRow.addArrangedSubview(ovLabel)
        ovRow.addArrangedSubview(ovField)
        ovRow.addArrangedSubview(ovStepper)
        doc.addArrangedSubview(ovRow)

        // Backup: move every preference + saved layout to another Mac as one file.
        doc.addArrangedSubview(sectionHeader("Backup"))
        let backupRow = NSStackView()
        backupRow.orientation = .horizontal
        backupRow.spacing = 10
        let exportButton = NSButton(title: "Export Settings…",
                                    target: self, action: #selector(exportSettings))
        exportButton.bezelStyle = .rounded
        let importButton = NSButton(title: "Import Settings…",
                                    target: self, action: #selector(importSettings))
        importButton.bezelStyle = .rounded
        let backupHint = NSTextField(labelWithString: "Shortcuts, preferences, and saved layouts in one JSON file.")
        backupHint.font = .systemFont(ofSize: 11)
        backupHint.textColor = .secondaryLabelColor
        backupRow.addArrangedSubview(exportButton)
        backupRow.addArrangedSubview(importButton)
        backupRow.addArrangedSubview(backupHint)
        doc.addArrangedSubview(backupRow)

        return wrapInScroll(doc, identifier: "settings", label: "Settings")
    }

    // MARK: Backup actions

    /// One JSON file containing the preferences snapshot plus layouts.json, so a
    /// second Mac (or a reinstall) can pick up exactly where this one left off.
    @objc func exportSettings() {
        guard let settingsData = Settings.shared.exportData(),
              let settingsObj = try? JSONSerialization.jsonObject(with: settingsData) else {
            LayoutManager.notify("Export failed", "Couldn’t read current settings."); return
        }
        var envelope: [String: Any] = ["windowSnapExport": 1, "settings": settingsObj]
        if let layoutData = try? Data(contentsOf: LayoutManager.storeURL),
           let layoutObj = try? JSONSerialization.jsonObject(with: layoutData) {
            envelope["layouts"] = layoutObj
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "WindowSnap Settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: envelope,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            LayoutManager.notify("Settings exported", url.lastPathComponent)
        } catch {
            LayoutManager.notify("Export failed", error.localizedDescription)
        }
    }

    @objc func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["windowSnapExport"] != nil,
              let settingsObj = envelope["settings"],
              let settingsData = try? JSONSerialization.data(withJSONObject: settingsObj),
              Settings.shared.importData(settingsData) else {
            LayoutManager.notify("Import failed", "Not a WindowSnap settings export.")
            return
        }
        if let layoutObj = envelope["layouts"],
           let layoutData = try? JSONSerialization.data(withJSONObject: layoutObj) {
            try? layoutData.write(to: LayoutManager.storeURL, options: .atomic)
            NotificationCenter.default.post(name: .windowSnapLayoutsChanged, object: nil)
        }
        // Push the imported state everywhere: hotkeys, snapshot timer, login item,
        // and every tab's controls (installContent clears + rebuilds them).
        LoginItem.setEnabled(Settings.shared.launchAtLogin)
        onShortcutsChanged?()
        onLayoutShortcutsChanged?()
        onSnapshotIntervalChanged?()
        if let content = window?.contentView { installContent(into: content, select: 7) }
        reloadLayouts()
        LayoutManager.notify("Settings imported", "Preferences and layouts applied.")
    }

}
