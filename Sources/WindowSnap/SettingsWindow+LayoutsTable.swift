import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import UniformTypeIdentifiers

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    // Table tags distinguish the two boxes.
    static let defaultTableTag = 1   // Box 1: Default only
    static let mainTableTag = 2      // Box 2: Presentation + saved

    /// The id displayed at a given row of a given table, or nil.
    func layoutID(in tableTag: Int, row: Int) -> String? {
        if tableTag == Self.defaultTableTag {
            return row == 0 ? LayoutManager.defaultLayoutID : nil
        }
        // Main table shows ONLY saved layouts (the pinned layouts live in their
        // own box / restore buttons, not in this list).
        return (row >= 0 && row < layouts.count) ? layouts[row].id : nil
    }

    /// The layout at a given row of a given table, or nil.
    func layout(in tableTag: Int, row: Int) -> Layout? {
        guard let id = layoutID(in: tableTag, row: row) else { return nil }
        if LayoutManager.isPinned(id) { return LayoutManager.loadPinned(id) }
        return layouts.first { $0.id == id }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView.tag == Self.defaultTableTag ? 1 : layouts.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // Each row is a stacked cell: the layout name on top, with the action
        // buttons (Overwrite · shortcut/Restore · Clear) below it.
        guard let id = layoutID(in: tableView.tag, row: row) else { return NSView() }
        let name: String
        let key: String
        let savedAt: Date?
        if LayoutManager.isPinned(id) {
            name = LayoutManager.pinnedName(for: id)
            key = (id == LayoutManager.defaultLayoutID) ? "restoreDefault" : "restorePresentation"
            savedAt = LayoutManager.loadPinned(id)?.savedAt
        } else if let layout = layouts.first(where: { $0.id == id }) {
            name = layout.name
            key = "restoreLayout:\(id)"
            savedAt = layout.savedAt
        } else {
            return NSView()
        }
        let editable = !LayoutManager.isPinned(id) && tableView.tag == Self.mainTableTag
        let dateText = savedAt.map { Self.shortDateFormatter.string(from: $0) } ?? ""
        return makeLayoutRowCell(id: id, name: name, key: key, editableName: editable, dateText: dateText)
    }

    /// Short "day month, time" format with no seconds, e.g. "30 Jun, 14:32".
    static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    /// Builds one layout row: the name (with the saved date/time on its right) on
    /// top, action buttons below.
    func makeLayoutRowCell(id: String, name: String, key: String,
                                   editableName: Bool, dateText: String) -> NSView {
        let cell = NSTableCellView()

        let nameField: NSTextField
        if editableName {
            nameField = NSTextField(string: name)
            nameField.isBezeled = false
            nameField.drawsBackground = false
            nameField.isEditable = true
            nameField.target = self
            nameField.action = #selector(renameCommitted(_:))
        } else {
            nameField = NSTextField(labelWithString: name)
        }
        nameField.font = .systemFont(ofSize: NSFont.systemFontSize)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(nameField)
        cell.textField = nameField

        // Saved date/time, right-aligned on the same line as the name.
        let dateLabel = NSTextField(labelWithString: dateText)
        dateLabel.font = .systemFont(ofSize: 11)
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.alignment = .right
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        cell.addSubview(dateLabel)

        let buttons = makeActionButtonsRow(id: id, name: name, key: key)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(buttons)

        NSLayoutConstraint.activate([
            nameField.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            nameField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),

            dateLabel.firstBaselineAnchor.constraint(equalTo: nameField.firstBaselineAnchor),
            dateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameField.trailingAnchor, constant: 8),
            dateLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),

            buttons.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 5),
            buttons.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
        ])
        return cell
    }

    /// The action row shown under each layout name: a **Restore** button and an
    /// **Overwrite** button (both act immediately on click — no shortcut needed),
    /// plus a **Shortcut** button that opens a popover for assigning/clearing the
    /// restore & overwrite hotkeys. Separating the actions from shortcut
    /// assignment is the key usability fix: previously these controls doubled as
    /// key recorders, so with no hotkey bound a click recorded a key instead of
    /// restoring/overwriting.
    func makeActionButtonsRow(id: String, name: String, key restoreKey: String) -> NSView {
        let overwriteKey = overwriteShortcutKey(for: id)

        let restoreBtn = NSButton(title: " Restore", target: self, action: #selector(restoreRowButton(_:)))
        restoreBtn.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Restore")
        restoreBtn.imagePosition = .imageLeading
        restoreBtn.identifier = NSUserInterfaceItemIdentifier("rowRestore:\(id)")
        restoreBtn.toolTip = "Restore “\(name)” — put your windows back to this saved arrangement."

        let overwriteBtn = NSButton(title: " Overwrite", target: self, action: #selector(overwriteRowButton(_:)))
        overwriteBtn.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Overwrite")
        overwriteBtn.imagePosition = .imageLeading
        overwriteBtn.identifier = NSUserInterfaceItemIdentifier("rowOverwrite:\(id)")
        overwriteBtn.toolTip = "Overwrite “\(name)” with your current window arrangement."

        // Shortcut button: shows the restore hotkey when set, else a prompt.
        let restoreSC = Settings.shared.shortcuts[restoreKey]
        let overwriteSC = Settings.shared.shortcuts[overwriteKey]
        let shortcutBtn = NSButton(title: restoreSC.map { " \($0.display)" } ?? " Shortcut",
                                   target: self, action: #selector(openShortcutPopover(_:)))
        shortcutBtn.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Shortcuts")
        shortcutBtn.imagePosition = .imageLeading
        shortcutBtn.identifier = NSUserInterfaceItemIdentifier("rowShortcut:\(id)")
        shortcutBtn.contentTintColor = (restoreSC != nil || overwriteSC != nil) ? .controlAccentColor : nil
        if let r = restoreSC {
            shortcutBtn.toolTip = "Restore: \(r.display)" + (overwriteSC.map { " · Overwrite: \($0.display)" } ?? "") + "  (click to change)"
        } else if let o = overwriteSC {
            shortcutBtn.toolTip = "Overwrite: \(o.display)  (click to change)"
        } else {
            shortcutBtn.toolTip = "Set a keyboard shortcut for “\(name)”."
        }

        for b in [restoreBtn, overwriteBtn, shortcutBtn] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
        }

        let stack = NSStackView(views: [restoreBtn, overwriteBtn, shortcutBtn])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.distribution = .fill
        return stack
    }

    /// Settings key holding the overwrite shortcut for a layout id.
    func overwriteShortcutKey(for id: String) -> String {
        if LayoutManager.isPinned(id) {
            return id == LayoutManager.defaultLayoutID ? "overwriteDefault" : "overwritePresentation"
        }
        return "overwriteLayout:\(id)"
    }

    /// Settings key holding the restore shortcut for a layout id.
    func restoreShortcutKey(for id: String) -> String {
        if LayoutManager.isPinned(id) {
            return id == LayoutManager.defaultLayoutID ? "restoreDefault" : "restorePresentation"
        }
        return "restoreLayout:\(id)"
    }

    /// Display name for a layout id.
    func layoutDisplayName(for id: String) -> String {
        if LayoutManager.isPinned(id) { return LayoutManager.pinnedName(for: id) }
        return layouts.first(where: { $0.id == id })?.name ?? "Layout"
    }

    /// Popover for assigning/clearing the restore & overwrite hotkeys for a layout.
    @objc func openShortcutPopover(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("rowShortcut:") else { return }
        let id = String(raw.dropFirst("rowShortcut:".count))
        let name = layoutDisplayName(for: id)
        let restoreKey = restoreShortcutKey(for: id)
        let overwriteKey = overwriteShortcutKey(for: id)

        func recorder(for key: String) -> ShortcutRecorder {
            let rec = ShortcutRecorder(regionKey: key, current: Settings.shared.shortcuts[key]) { [weak self] sc in
                Settings.shared.setShortcut(key, sc); self?.onShortcutsChanged?()
            }
            rec.onClear = { [weak self] in Settings.shared.clearShortcut(key); self?.onShortcutsChanged?() }
            rec.controlSize = .regular; rec.font = .systemFont(ofSize: 12)
            rec.translatesAutoresizingMaskIntoConstraints = false
            rec.widthAnchor.constraint(equalToConstant: 170).isActive = true
            return rec
        }
        func labeledRow(_ text: String, _ rec: NSView) -> NSStackView {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 12)
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 78).isActive = true
            let row = NSStackView(views: [l, rec])
            row.orientation = .horizontal; row.spacing = 8; row.distribution = .fill
            row.translatesAutoresizingMaskIntoConstraints = false
            return row
        }

        let title = NSTextField(labelWithString: "Keyboard shortcuts")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let subtitle = NSTextField(labelWithString: name)
        subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .secondaryLabelColor

        let restoreRow = labeledRow("Restore", recorder(for: restoreKey))
        let overwriteRow = labeledRow("Overwrite", recorder(for: overwriteKey))

        let clearBtn = NSButton(title: "Clear both", target: self, action: #selector(clearRowShortcut(_:)))
        clearBtn.bezelStyle = .rounded; clearBtn.controlSize = .small; clearBtn.font = .systemFont(ofSize: 11)
        clearBtn.identifier = NSUserInterfaceItemIdentifier("rowClear:\(restoreKey)||\(overwriteKey)")

        let hint = NSTextField(labelWithString: "Click a field, then press keys. ⌫ clears one.")
        hint.font = .systemFont(ofSize: 10); hint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [title, subtitle, restoreRow, overwriteRow, clearBtn, hint])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        content.frame = NSRect(origin: .zero, size: content.fittingSize)

        let vc = NSViewController(); vc.view = content
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = vc
        popover.contentSize = content.frame.size
        popover.delegate = self
        rowShortcutPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    // Refresh the rows (so the Shortcut buttons show updated bindings) once the
    // popover closes — done here rather than on each keystroke so editing both
    // shortcuts doesn't rebuild (and dismiss) the popover mid-interaction.
    func popoverDidClose(_ notification: Notification) {
        rowShortcutPopover = nil
        reloadLayoutTables()
    }

    /// Reload both layout tables (used when an inline shortcut is set/cleared).
    func reloadLayoutTables() {
        defaultTableView?.reloadData()
        mainTableView?.reloadData()
    }

    @objc func beginRenameSelected() {
        let r = mainTableView.selectedRow
        guard r >= 0, r < layouts.count else { return }
        mainTableView.editColumn(0, row: r, with: nil, select: true)
    }

    @objc func restoreRowButton(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("rowRestore:") else { return }
        let id = String(raw.dropFirst("rowRestore:".count))
        // Pinned (Default) layouts live in their own store; saved ones in the list.
        if LayoutManager.isPinned(id) {
            guard let target = LayoutManager.loadPinned(id) else {
                NSSound.beep()
                LayoutManager.notify("No \(LayoutManager.pinnedName(for: id)) layout",
                                     "Capture it with Overwrite first.")
                return
            }
            LayoutManager.restore(target)
            return
        }
        guard let target = layouts.first(where: { $0.id == id }) else { NSSound.beep(); return }
        LayoutManager.restore(target)
    }

    @objc func clearRowShortcut(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("rowClear:") else { return }
        let keys = String(raw.dropFirst("rowClear:".count)).components(separatedBy: "||")
        for k in keys where !k.isEmpty { Settings.shared.clearShortcut(k) }
        onShortcutsChanged?()
        // Refresh so the buttons reset to "set key".
        reloadLayoutTables()
    }

    @objc func overwriteRowButton(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("rowOverwrite:") else { return }
        let id = String(raw.dropFirst("rowOverwrite:".count))
        // Confirm — overwrite replaces the saved windows and can't be undone, and
        // the button now sits right next to Restore.
        let name = layoutDisplayName(for: id)
        let confirm = NSAlert()
        confirm.messageText = "Overwrite “\(name)”?"
        confirm.informativeText = "This replaces the windows saved in “\(name)” with your current arrangement. This can’t be undone."
        confirm.addButton(withTitle: "Overwrite")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        // Pinned (Default) layout: recapture into its own store.
        if LayoutManager.isPinned(id) {
            var fresh = LayoutManager.capture(named: LayoutManager.pinnedName(for: id))
            fresh.id = id
            LayoutManager.savePinned(fresh, id: id)
            defaultCanvas?.layout = LayoutManager.loadPinned(LayoutManager.defaultLayoutID)
            reloadLayoutTables()
            Logger.log("Overwrote \(LayoutManager.pinnedName(for: id)) (\(fresh.windows.count) win)")
            return
        }
        guard let i = layouts.firstIndex(where: { $0.id == id }) else { NSSound.beep(); return }
        let old = layouts[i]
        var fresh = LayoutManager.capture(named: old.name)
        fresh.id = old.id                       // keep stable id
        layouts[i] = fresh
        LayoutManager.save(layouts)
        layoutCanvas?.layout = fresh
        reloadLayoutTables()
        Logger.log("Overwrote “\(old.name)” (\(fresh.windows.count) win)")
    }

    @objc func renameCommitted(_ sender: NSTextField) {
        let r = mainTableView.row(for: sender)
        guard r >= 0, r < layouts.count else { return }
        let newName = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != layouts[r].name else {
            sender.stringValue = (r < layouts.count) ? layouts[r].name : sender.stringValue
            return
        }
        let old = layouts[r].name
        layouts[r].name = newName
        LayoutManager.save(layouts)
        Logger.log("Renamed “\(old)” → “\(newName)”")
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        let row = table.selectedRow
        // When the main table loses its selection, clear the Selected canvas
        // instead of leaving the previously shown layout on screen.
        guard row >= 0, let id = layoutID(in: table.tag, row: row) else {
            if table.tag == Self.mainTableTag,
               (defaultTableView?.selectedRow ?? -1) < 0 {
                selectedLayoutID = nil
                UserDefaults.standard.removeObject(forKey: "WindowSnapSelectedLayoutID")
            }
            return
        }
        // Deselect the OTHER table so selection is unambiguous across both boxes.
        if table.tag == Self.defaultTableTag {
            mainTableView?.deselectAll(nil)
        } else {
            defaultTableView?.deselectAll(nil)
        }
        selectedLayoutID = id
        // The Saved Layout canvas only ever shows saved layouts from the main
        // table. Selecting a saved row updates it AND records it as the last
        // saved layout. Selecting the Default row leaves the canvas on whatever
        // saved layout was shown last, rather than going blank.
        if table.tag == Self.mainTableTag {
            lastSavedLayoutID = id
            layoutCanvas.layout = layout(in: table.tag, row: row)
        }
        UserDefaults.standard.set(id, forKey: "WindowSnapSelectedLayoutID")
    }

    /// The id of the currently selected layout from the live tables, or nil.
    func liveSelectedLayoutID() -> String? {
        guard window?.isVisible == true else { return nil }
        if let t = defaultTableView, t.selectedRow == 0 { return LayoutManager.defaultLayoutID }
        if let t = mainTableView, t.selectedRow >= 0 {
            return layoutID(in: Self.mainTableTag, row: t.selectedRow)
        }
        return nil
    }

    /// Reload layouts from disk and refresh both tables/previews.
    func reloadLayouts() {
        layouts = LayoutManager.loadAll()
        defaultTableView?.reloadData()
        mainTableView?.reloadData()
        // Always keep the Default canvas current.
        defaultCanvas?.layout = LayoutManager.loadPinned(LayoutManager.defaultLayoutID)
        // The Saved Layout canvas tracks the last selected saved layout and
        // never shows the Default layout.
        if let id = lastSavedLayoutID,
           let saved = layouts.first(where: { $0.id == id }) {
            layoutCanvas?.layout = saved
        } else {
            lastSavedLayoutID = nil
            layoutCanvas?.layout = nil
        }
    }
}
