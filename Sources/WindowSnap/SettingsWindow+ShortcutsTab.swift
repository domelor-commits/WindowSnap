import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import UniformTypeIdentifiers

extension SettingsWindowController {
    // MARK: - Tab: Shortcuts (keyboard shortcuts + custom launchers)
    func makeShortcutsTab() -> NSTabViewItem {
        let doc = NSStackView()
        doc.addArrangedSubview(sectionHeader("Keyboard shortcuts"))

        // Build a shortcut row (icon + label + recorder) for one key.
        func makeShortcutRow(_ key: String) -> NSView? {
            guard let current = Settings.shared.shortcuts[key] else { return nil }
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 10

            let icon = NSImageView()
            icon.image = SettingsWindowController.regionIcon(for: key)
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 18).isActive = true

            let label = NSTextField(labelWithString: KeyNames.regionLabel(key))
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 150).isActive = true

            let recorder = ShortcutRecorder(regionKey: key, current: current) { [weak self] newShortcut in
                Settings.shared.setShortcut(key, newShortcut)
                self?.onShortcutsChanged?()
            }
            recorder.translatesAutoresizingMaskIntoConstraints = false
            recorder.widthAnchor.constraint(equalToConstant: 140).isActive = true

            row.addArrangedSubview(icon)
            row.addArrangedSubview(label)
            row.addArrangedSubview(recorder)
            return row
        }

        // Collect the visible shortcut keys (excluding ones that live in the
        // Layouts tab), then split them across two columns to halve the height.
        let shortcutKeys = KeyNames.order.filter { key in
            key != "overwriteLayout" && key != "restoreLayout" && key != "restoreDefault"
                && Settings.shared.shortcuts[key] != nil
        }
        let half = (shortcutKeys.count + 1) / 2
        let leftKeys = Array(shortcutKeys.prefix(half))
        let rightKeys = Array(shortcutKeys.suffix(from: half))

        let leftShortcuts = NSStackView(views: leftKeys.compactMap { makeShortcutRow($0) })
        leftShortcuts.orientation = .vertical
        leftShortcuts.alignment = .leading
        leftShortcuts.spacing = 8
        let rightShortcuts = NSStackView(views: rightKeys.compactMap { makeShortcutRow($0) })
        rightShortcuts.orientation = .vertical
        rightShortcuts.alignment = .leading
        rightShortcuts.spacing = 8

        let shortcutColumns = NSStackView(views: [leftShortcuts, rightShortcuts])
        shortcutColumns.orientation = .horizontal
        shortcutColumns.alignment = .top
        shortcutColumns.spacing = 32
        doc.addArrangedSubview(shortcutColumns)

        let reset = NSButton(title: "Reset All Shortcuts to Defaults", target: self, action: #selector(resetShortcuts))
        reset.bezelStyle = .rounded
        doc.addArrangedSubview(reset)

        // Divider before function key launchers.
        let fkDiv = NSBox(); fkDiv.boxType = .separator
        fkDiv.translatesAutoresizingMaskIntoConstraints = false
        doc.addArrangedSubview(fkDiv)
        fkDiv.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -40).isActive = true

        // ===== Custom launchers section =====
        doc.addArrangedSubview(sectionHeader("Custom launchers"))
        let fkHint = NSTextField(labelWithString:
            "Click a shortcut to set a key (e.g. F13–F19), then choose what it launches.")
        fkHint.font = .systemFont(ofSize: 11)
        fkHint.textColor = .secondaryLabelColor
        doc.addArrangedSubview(fkHint)

        // One launcher row: a shortcut recorder + the assignment dropdown.
        func makeLauncherRow(_ slot: String) -> NSView {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6

            let key = "launcher:\(slot)"
            let recorder = ShortcutRecorder(regionKey: key, current: Settings.shared.shortcuts[key]) { [weak self] sc in
                Settings.shared.setShortcut(key, sc)
                self?.onShortcutsChanged?()
            }
            recorder.onClear = { [weak self] in
                Settings.shared.clearShortcut(key)
                self?.onShortcutsChanged?()
            }
            recorder.controlSize = .small
            recorder.font = .systemFont(ofSize: 11)
            recorder.toolTip = "Click, then press a key (e.g. F13–F19) to set this launcher's shortcut."
            recorder.translatesAutoresizingMaskIntoConstraints = false
            recorder.widthAnchor.constraint(equalToConstant: 92).isActive = true

            let popup = NSPopUpButton()
            popup.identifier = NSUserInterfaceItemIdentifier("fkPopup:\(slot)")
            popup.target = self
            popup.action = #selector(functionKeyPopupChanged(_:))
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 11)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 240).isActive = true
            buildFunctionKeyMenu(for: slot, popup: popup)

            row.addArrangedSubview(recorder)
            row.addArrangedSubview(popup)
            return row
        }

        // Two columns of four: slots 1–4 on the left, 5–8 on the right.
        let slots = Settings.launcherSlots
        let leftCol = NSStackView(views: slots.prefix(4).map { makeLauncherRow($0) })
        leftCol.orientation = .vertical; leftCol.alignment = .leading; leftCol.spacing = 8
        let rightCol = NSStackView(views: slots.suffix(from: 4).map { makeLauncherRow($0) })
        rightCol.orientation = .vertical; rightCol.alignment = .leading; rightCol.spacing = 8
        let launcherColumns = NSStackView(views: [leftCol, rightCol])
        launcherColumns.orientation = .horizontal
        launcherColumns.alignment = .top
        launcherColumns.spacing = 24
        doc.addArrangedSubview(launcherColumns)

        return wrapInScroll(doc, identifier: "shortcuts", label: "Shortcuts")
    }

    @objc func resetShortcuts() {
        Settings.shared.resetShortcuts()
        onShortcutsChanged?()
        // Rebuild the window (recorder titles refresh) and stay on the Shortcuts tab.
        if let content = window?.contentView { installContent(into: content, select: 5) }
    }

}
