import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import UniformTypeIdentifiers

extension SettingsWindowController {
    // MARK: - Tab 3: Layouts
    func makeLayoutsTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "layouts")
        item.label = "▦ Layouts"
        let container = NSView()
        // Reset pinned-restore tracking so a rebuild doesn't keep stale views.
        pinnedRestoreRecorders.removeAll()
        pinnedRestoreRows.removeAll()

        // Box 1: Default only.
        defaultTableView = NSTableView()
        defaultTableView.tag = Self.defaultTableTag
        let dCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        dCol.title = "Default"
        dCol.width = 240
        defaultTableView.addTableColumn(dCol)
        defaultTableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        defaultTableView.dataSource = self
        defaultTableView.delegate = self
        defaultTableView.headerView = nil   // section label already says "Default"
        defaultTableView.rowHeight = 54

        let defaultListScroll = NSScrollView()
        defaultListScroll.documentView = defaultTableView
        defaultListScroll.hasVerticalScroller = false
        defaultListScroll.translatesAutoresizingMaskIntoConstraints = false
        defaultListScroll.heightAnchor.constraint(equalToConstant: 60).isActive = true

        // Box 2: Presentation + saved layouts.
        mainTableView = NSTableView()
        mainTableView.tag = Self.mainTableTag
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.title = "Layout"
        col.width = 240
        mainTableView.addTableColumn(col)
        mainTableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        mainTableView.rowHeight = 54
        mainTableView.dataSource = self
        mainTableView.delegate = self
        mainTableView.headerView = nil
        // Double-click a row to rename it inline.
        mainTableView.target = self
        mainTableView.doubleAction = #selector(beginRenameSelected)

        let listScroll = NSScrollView()
        listScroll.documentView = mainTableView
        listScroll.hasVerticalScroller = true
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        let saveBtn = NSButton(title: "New", target: self, action: #selector(saveCurrentLayout))
        let deleteBtn = NSButton(title: "Delete", target: self, action: #selector(deleteSelected))
        for b in [saveBtn, deleteBtn] {
            b.bezelStyle = .rounded
            b.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        func sectionLabel(_ s: String, bold: Bool = true) -> NSTextField {
            let l = NSTextField(labelWithString: s.uppercased())
            l.font = .systemFont(ofSize: 9, weight: bold ? .semibold : .regular)
            l.textColor = .tertiaryLabelColor
            return l
        }

        // --- Group 1: actions on the selected SAVED layout. Restore and Overwrite
        // are now the inline per-row buttons, so only Save New / Delete remain. ---
        let actionsTop = NSStackView(views: [saveBtn, deleteBtn])
        actionsTop.orientation = .horizontal; actionsTop.distribution = .fillEqually; actionsTop.spacing = 8

        // The left column is split into two vertical stacks so the saved-layouts
        // table can be pinned to line up with the Saved Layout canvas on the
        // right. The upper stack holds the Default section; the lower stack holds
        // the saved-layouts section, and its top is constrained to the Saved
        // canvas top further below. Restore + overwrite shortcuts now live inline
        // in each table row, so the old separate rows/sections were removed.
        let upperColumnViews: [NSView] = [
            sectionLabel("Default", bold: false),
            defaultListScroll,
        ]
        let lowerColumnViews: [NSView] = [
            sectionLabel("Saved layouts"),
            listScroll,
            makeDivider(),
            sectionLabel("Manage saved layouts"), actionsTop,
        ]

        let leftColumn = NSStackView(views: upperColumnViews)
        leftColumn.orientation = .vertical
        leftColumn.spacing = 6
        leftColumn.alignment = .leading
        leftColumn.translatesAutoresizingMaskIntoConstraints = false
        leftColumn.setCustomSpacing(12, after: defaultListScroll)

        let savedColumn = NSStackView(views: lowerColumnViews)
        savedColumn.orientation = .vertical
        savedColumn.spacing = 6
        savedColumn.alignment = .leading
        savedColumn.translatesAutoresizingMaskIntoConstraints = false
        savedColumn.setCustomSpacing(12, after: listScroll)

        // Make the management button row fill the column width.
        actionsTop.translatesAutoresizingMaskIntoConstraints = false
        actionsTop.leadingAnchor.constraint(equalTo: savedColumn.leadingAnchor).isActive = true
        actionsTop.trailingAnchor.constraint(equalTo: savedColumn.trailingAnchor).isActive = true
        listScroll.leadingAnchor.constraint(equalTo: savedColumn.leadingAnchor).isActive = true
        listScroll.trailingAnchor.constraint(equalTo: savedColumn.trailingAnchor).isActive = true
        listScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        listScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        listScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        defaultListScroll.leadingAnchor.constraint(equalTo: leftColumn.leadingAnchor).isActive = true
        defaultListScroll.trailingAnchor.constraint(equalTo: leftColumn.trailingAnchor).isActive = true

        layoutCanvas = LayoutCanvas()
        layoutCanvas.translatesAutoresizingMaskIntoConstraints = false
        layoutCanvas.wantsLayer = true
        layoutCanvas.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
        layoutCanvas.layer?.cornerRadius = 8

        // Second canvas, hard-locked to the Default layout, shown above the
        // selection canvas. Always displays Default regardless of selection.
        defaultCanvas = LayoutCanvas()
        defaultCanvas.translatesAutoresizingMaskIntoConstraints = false
        defaultCanvas.wantsLayer = true
        defaultCanvas.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
        defaultCanvas.layer?.cornerRadius = 8
        defaultCanvas.layout = LayoutManager.loadPinned(LayoutManager.defaultLayoutID)

        let defaultHeader = NSTextField(labelWithString: "Default Layout - Monitors and Apps")
        defaultHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        defaultHeader.textColor = .secondaryLabelColor
        defaultHeader.translatesAutoresizingMaskIntoConstraints = false

        let selectedHeader = NSTextField(labelWithString: "Saved Layout - Monitors and Apps")
        selectedHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        selectedHeader.textColor = .secondaryLabelColor
        selectedHeader.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(leftColumn)
        container.addSubview(savedColumn)
        container.addSubview(defaultHeader)
        container.addSubview(defaultCanvas)
        container.addSubview(selectedHeader)
        container.addSubview(layoutCanvas)

        let logSection = makeLogSection()
        container.addSubview(logSection)

        // The saved-layouts column lines up with the Saved Layout canvas on the
        // right when there's room, but this alignment is OPTIONAL: the required
        // collision guard below (saved column always sits below the Default
        // section) must win when the window is short, otherwise the saved table
        // would overlap the Default section.
        let savedTopAlignsCanvas = savedColumn.topAnchor.constraint(equalTo: selectedHeader.topAnchor)
        savedTopAlignsCanvas.priority = .defaultHigh

        NSLayoutConstraint.activate([
            leftColumn.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            leftColumn.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            leftColumn.widthAnchor.constraint(equalToConstant: 280),

            savedColumn.leadingAnchor.constraint(equalTo: leftColumn.leadingAnchor),
            savedColumn.widthAnchor.constraint(equalTo: leftColumn.widthAnchor),
            savedTopAlignsCanvas,
            savedColumn.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16),
            // Required: keep the upper Default stack from colliding with the saved
            // column. This always wins over the optional canvas alignment above.
            savedColumn.topAnchor.constraint(greaterThanOrEqualTo: leftColumn.bottomAnchor, constant: 12),

            // Default canvas (top), with its header.
            defaultHeader.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            defaultHeader.leadingAnchor.constraint(equalTo: leftColumn.trailingAnchor, constant: 16),
            defaultHeader.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            defaultCanvas.topAnchor.constraint(equalTo: defaultHeader.bottomAnchor, constant: 4),
            defaultCanvas.leadingAnchor.constraint(equalTo: leftColumn.trailingAnchor, constant: 16),
            defaultCanvas.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            // Selected canvas (below), with its header.
            selectedHeader.topAnchor.constraint(equalTo: defaultCanvas.bottomAnchor, constant: 12),
            selectedHeader.leadingAnchor.constraint(equalTo: leftColumn.trailingAnchor, constant: 16),
            selectedHeader.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            layoutCanvas.topAnchor.constraint(equalTo: selectedHeader.bottomAnchor, constant: 4),
            layoutCanvas.leadingAnchor.constraint(equalTo: leftColumn.trailingAnchor, constant: 16),
            layoutCanvas.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            layoutCanvas.bottomAnchor.constraint(equalTo: logSection.topAnchor, constant: -12),

            // The two canvases split the available height evenly.
            defaultCanvas.heightAnchor.constraint(equalTo: layoutCanvas.heightAnchor),

            // The activity log is aligned to the canvas column (right of the
            // left layout column) instead of spanning the full window width.
            logSection.leadingAnchor.constraint(equalTo: leftColumn.trailingAnchor, constant: 16),
            logSection.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            logSection.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        item.view = container
        return item
    }

    @objc func saveCurrentLayout() {
        // This button manages SAVED layouts only. The Default layout has its own
        // Save button, so a pinned selection here still creates a new saved
        // layout rather than overwriting the pinned slot.
        let alert = NSAlert()
        alert.messageText = "Save current window layout"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = "Layout \(LayoutManager.loadAll().count + 1)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            var all = LayoutManager.loadAll()
            let captured = LayoutManager.capture(named: field.stringValue)
            all.append(captured)
            LayoutManager.save(all)
            layouts = all
            mainTableView.reloadData()
            Logger.log("New “\(captured.name)” (\(captured.windows.count) win)")
        }
    }

    @objc func overwriteSelected() {
        // Manages SAVED layouts only — operates on the last selected saved layout.
        guard let id = lastSavedLayoutID,
              let i = layouts.firstIndex(where: { $0.id == id }) else { NSSound.beep(); return }
        let old = layouts[i]
        // No confirmation prompt: overwrite immediately with the current windows.
        var fresh = LayoutManager.capture(named: old.name)
        fresh.id = old.id                       // keep stable id
        layouts[i] = fresh
        LayoutManager.save(layouts)
        mainTableView.reloadData()
        layoutCanvas.layout = fresh
        Logger.log("Overwrote “\(old.name)” (\(fresh.windows.count) win)")
    }

    @objc func restoreSelected() {
        // Manages SAVED layouts only.
        guard let id = lastSavedLayoutID,
              let target = layouts.first(where: { $0.id == id }) else { NSSound.beep(); return }
        LayoutManager.restore(target)
    }

    @objc func deleteSelected() {
        // Manages SAVED layouts only.
        guard let id = lastSavedLayoutID,
              let i = layouts.firstIndex(where: { $0.id == id }) else { NSSound.beep(); return }
        let target = layouts[i]
        layouts.remove(at: i)
        LayoutManager.save(layouts)
        // Drop any per-layout restore shortcut so it isn't left dangling.
        Settings.shared.shortcuts["restoreLayout:\(target.id)"] = nil
        Settings.shared.save()
        selectedLayoutID = nil
        lastSavedLayoutID = nil
        mainTableView.reloadData()
        layoutCanvas.layout = nil
        onLayoutShortcutsChanged?()
        Logger.log("Deleted “\(target.name)”")
    }

    // MARK: - Default-layout management (always act on the Default layout,
    // independent of the current table selection).

    @objc func saveDefaultLayout() {
        let id = LayoutManager.defaultLayoutID
        var fresh = LayoutManager.capture(named: LayoutManager.defaultLayoutName)
        fresh.id = id
        LayoutManager.savePinned(fresh, id: id)
        Logger.log("Saved Default (\(fresh.windows.count) win)")
        reloadLayouts()
        defaultCanvas?.layout = fresh
    }

    @objc func overwriteDefaultLayout() {
        // Same effect as save for a pinned slot: recapture into the Default id.
        saveDefaultLayout()
    }

    @objc func restoreDefaultLayout() {
        guard let target = LayoutManager.loadPinned(LayoutManager.defaultLayoutID) else {
            NSSound.beep(); return
        }
        LayoutManager.restore(target)
    }

    @objc func deleteDefaultLayout() {
        LayoutManager.deletePinned(LayoutManager.defaultLayoutID)
        Logger.log("Cleared Default")
        reloadLayouts()
        defaultCanvas?.layout = LayoutManager.loadPinned(LayoutManager.defaultLayoutID)
        onLayoutShortcutsChanged?()
    }

    @objc func clearOverwriteShortcut() {
        Settings.shared.shortcuts["overwriteLayout"] = nil
        Settings.shared.save()
        overwriteShortcutButton.title = "Click to set"
        onShortcutsChanged?()
    }

    func makeDivider() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }
}
