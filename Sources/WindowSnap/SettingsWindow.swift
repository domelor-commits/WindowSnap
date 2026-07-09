import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import UniformTypeIdentifiers

/// The main app window with three tabs: Layouts, Settings, Annotate.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {

    var onShortcutsChanged: (() -> Void)?
    var onSnapRequested: ((SnapRegion) -> Void)?
    var onSaveLayoutRequested: (() -> Void)?

    private var tabView: NSTabView!
    private var annotatorPane: AnnotatorPane!
    private var layoutCanvas: LayoutCanvas!
    private var defaultCanvas: LayoutCanvas!
    private var defaultTableView: NSTableView!
    private var mainTableView: NSTableView!
    private var selectedLayoutID: String?
    /// The most recently selected SAVED layout id (from the main table only).
    /// Used to keep the Saved Layout canvas populated even when focus moves to
    /// the Default row.
    private var lastSavedLayoutID: String?
    private var layouts: [Layout] = []
    private var pinnedRestoreRecorders: [String: ShortcutRecorder] = [:]
    private var pinnedRestoreRows: [NSView] = []
    private var overwriteShortcutButton: ShortcutRecorder!

    /// Called by the app delegate when a layout's restore shortcut changes,
    /// so global hotkeys can be re-registered.
    var onLayoutShortcutsChanged: (() -> Void)?

    /// Supplied by the app delegate so the Command Palette tab can list and run
    /// every action (and restore focus to the previously-active app for snaps).
    var paletteActionsProvider: (() -> [PaletteAction])?
    var runPaletteAction: ((PaletteAction) -> Void)?

    // In-window feature tabs (mirror the shared data behind the floating panels).
    private var clipboardPane: ClipboardHistoryPane?
    private var forceQuitPane: ForceQuitPane?
    private var commandPane: CommandPalettePane?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "WindowSnap"
        window.minSize = NSSize(width: 640, height: 460)
        window.center()
        self.init(window: window)
        window.delegate = self

        installContent(into: window.contentView!, select: 0)

        // Reload the saved-layouts table when the list changes outside the UI
        // (e.g. the periodic 'Saved' capture writing a new entry).
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutsChangedExternally),
            name: .windowSnapLayoutsChanged, object: nil)
    }

    @objc private func layoutsChangedExternally() {
        // Only the saved-layouts table needs refreshing; reload on the main
        // thread since the notification may arrive from a timer/system callback.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.mainTableView != nil else { return }
            self.layouts = LayoutManager.loadAll()
            self.mainTableView?.reloadData()
        }
    }

    func show() {
        layouts = LayoutManager.loadAll()
        defaultTableView?.reloadData()
        mainTableView?.reloadData()
        defaultCanvas?.layout = LayoutManager.loadPinned(LayoutManager.defaultLayoutID)
        // The Saved Layout canvas shows the last selected saved layout (if any),
        // independent of which row currently has focus.
        if let id = lastSavedLayoutID,
           let saved = layouts.first(where: { $0.id == id }) {
            layoutCanvas?.layout = saved
        } else if lastSavedLayoutID == nil {
            layoutCanvas?.layout = nil
        }
        refreshAccessibilityStatus()
        resizeToFitContent()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        syncTabActivity()   // (re)start the Force Quit poll if that tab is showing
    }

    func windowWillClose(_ notification: Notification) {
        forceQuitPane?.stop()   // don't keep sampling CPU while the window is closed
    }

    /// Size the window so the entire Settings tab content is visible without
    /// scrolling, capped to the screen's visible height, and re-center it.
    private func resizeToFitContent() {
        guard let window = window else { return }
        let screen = window.screen ?? NSScreen.main
        let maxH = (screen?.visibleFrame.height ?? 900) - 40
        let target = NSSize(width: 780, height: min(860, maxH))
        var frame = window.frame
        // Convert desired content size to a full window frame size.
        let contentRect = window.contentRect(forFrameRect: frame)
        let chromeH = frame.height - contentRect.height
        frame.size.width = max(target.width, window.minSize.width)
        frame.size.height = target.height + chromeH
        window.setFrame(frame, display: true)
        window.center()
    }

    private func sectionHeader(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s.uppercased())
        l.font = .systemFont(ofSize: 10, weight: .bold)
        l.textColor = .secondaryLabelColor
        return l
    }

    /// Wraps a vertical content stack in a top-anchored scroll view for a tab.
    private func wrapInScroll(_ doc: NSStackView, identifier: String, label: String) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: identifier)
        item.label = label
        let container = NSView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        doc.orientation = .vertical
        doc.alignment = .leading
        doc.spacing = 8
        doc.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        doc.translatesAutoresizingMaskIntoConstraints = false
        let flipped = FlippedClipView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(doc)
        scroll.documentView = flipped
        let clip = scroll.contentView
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            flipped.topAnchor.constraint(equalTo: clip.topAnchor),
            flipped.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            flipped.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            flipped.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            flipped.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
            doc.topAnchor.constraint(equalTo: flipped.topAnchor),
            doc.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            doc.bottomAnchor.constraint(lessThanOrEqualTo: flipped.bottomAnchor),
        ])
        item.view = container
        return item
    }

    // MARK: - Tab: Settings
    private func makeSettingsTab() -> NSTabViewItem {
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
        doc.addArrangedSubview(checkbox("When my Mac goes on standby or is locked, overwrite the Default layout with the current windows",
            state: s.overwriteOnStandby || s.overwriteOnLock, action: #selector(toggleOverwriteOnStandbyOrLock(_:))))
        doc.addArrangedSubview(checkbox("When my Mac wakes from standby, restore windows to the Default layout",
            state: s.restoreOnWake, action: #selector(toggleRestoreOnWake(_:))))
        doc.addArrangedSubview(checkbox("Show magnifier while selecting a screen capture",
            state: s.overlayShowMagnifier, action: #selector(toggleShowMagnifier(_:))))

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

        return wrapInScroll(doc, identifier: "settings", label: "Settings")
    }

    // MARK: - Tab: Shortcuts (keyboard shortcuts + custom launchers)
    private func makeShortcutsTab() -> NSTabViewItem {
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

    @objc private func resetShortcuts() {
        Settings.shared.resetShortcuts()
        onShortcutsChanged?()
        // Rebuild the window (recorder titles refresh) and stay on Settings.
        if let content = window?.contentView { installContent(into: content, select: 2) }
    }

    // MARK: - Window content: custom tab header (icon above label) + tab views

    private var tabButtons: [NSButton] = []

    private func installContent(into content: NSView, select index: Int) {
        content.subviews.forEach { $0.removeFromSuperview() }
        tabButtons = []

        let tv = NSTabView()
        tv.tabViewType = .noTabsNoBorder
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.addTabViewItem(makeLayoutsTab())      // 0
        tv.addTabViewItem(makeAnnotateTab())     // 1
        tv.addTabViewItem(makeShortcutsTab())    // 2
        tv.addTabViewItem(makeClipboardTab())    // 3
        tv.addTabViewItem(makeForceQuitTab())    // 4
        tv.addTabViewItem(makeCommandTab())      // 5
        tv.addTabViewItem(makeShelfTab())        // 6
        tv.addTabViewItem(makeSettingsTab())     // 7
        tv.delegate = self
        self.tabView = tv

        let defs: [(String, String)] = [
            ("Layouts", "macwindow"),
            ("Annotate", "pencil.tip.crop.circle"),
            ("Shortcuts", "command"),
            ("Clipboard", "doc.on.clipboard"),
            ("Force Quit", "xmark.octagon"),
            ("Palette", "magnifyingglass"),
            ("Shelf", "tray.and.arrow.down"),
            ("Settings", "gearshape"),
        ]
        let header = NSStackView()
        header.orientation = .horizontal
        header.distribution = .fill
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false
        for (i, (title, symbol)) in defs.enumerated() {
            let b = NSButton(title: title, target: self, action: #selector(tabButtonPressed(_:)))
            b.bezelStyle = .regularSquare
            b.isBordered = false
            b.imagePosition = .imageAbove
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .regular))
            b.imageScaling = .scaleProportionallyDown
            // A short small-font blank line above the label pushes it further
            // below the icon, widening the icon↔label gap.
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let at = NSMutableAttributedString(string: "\n",
                attributes: [.font: NSFont.systemFont(ofSize: 7), .paragraphStyle: para])
            at.append(NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .paragraphStyle: para]))
            b.attributedTitle = at
            b.tag = i
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 76).isActive = true
            tabButtons.append(b)
            header.addArrangedSubview(b)
        }
        header.addArrangedSubview(NSView())   // trailing spacer keeps tabs left-aligned

        let sep = NSBox(); sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        content.addSubview(sep)
        content.addSubview(tv)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            header.heightAnchor.constraint(equalToConstant: 54),
            sep.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            sep.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tv.topAnchor.constraint(equalTo: sep.bottomAnchor),
            tv.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tv.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        selectTab(index)
    }

    @objc private func tabButtonPressed(_ sender: NSButton) { selectTab(sender.tag) }

    private func selectTab(_ i: Int) {
        guard let tv = tabView, i >= 0, i < tv.numberOfTabViewItems else { return }
        tv.selectTabViewItem(at: i)
        for (j, b) in tabButtons.enumerated() {
            b.contentTintColor = (j == i) ? .controlAccentColor : .secondaryLabelColor
        }
    }

    // MARK: - Tab: Annotate

    /// A CleanShot-style annotation editor for screenshots captured via the
    /// shortcut buttons (and any other image). The pane is created once and
    /// re-hosted on rebuilds so annotations in progress survive.
    private func makeAnnotateTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "annotate")
        item.label = "✎ Annotate"
        let container = NSView()
        if annotatorPane == nil { annotatorPane = AnnotatorPane() }
        annotatorPane.removeFromSuperview()
        annotatorPane.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(annotatorPane)
        NSLayoutConstraint.activate([
            annotatorPane.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            annotatorPane.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            annotatorPane.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            annotatorPane.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        item.view = container
        return item
    }

    /// Open the window on the Annotate tab with a freshly captured screenshot.
    func showAnnotate(path: String) {
        show()
        selectTab(1)   // Annotate
        annotatorPane?.loadExternal(path: path)
    }

    /// Open the Annotate tab with an image loaded straight from the clipboard
    /// (memory buffer), for captures that aren't written to a file.
    func showAnnotateFromClipboard(_ image: NSImage) {
        show()
        selectTab(1)   // Annotate
        annotatorPane?.loadImage(image, path: nil)
    }

    // MARK: - Tabs: Clipboard / Force Quit / Command Palette / Shelf

    private func makeClipboardTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "clipboard")
        item.label = "Clipboard"
        let pane = ClipboardHistoryPane(frame: .zero)
        pane.autoresizingMask = [.width, .height]
        clipboardPane = pane
        item.view = pane
        return item
    }

    private func makeForceQuitTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "forcequit")
        item.label = "Force Quit"
        let pane = ForceQuitPane(frame: .zero)
        pane.autoresizingMask = [.width, .height]
        forceQuitPane = pane
        item.view = pane
        return item
    }

    private func makeCommandTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "command")
        item.label = "Palette"
        let pane = CommandPalettePane(frame: .zero)
        pane.autoresizingMask = [.width, .height]
        pane.actionsProvider = { [weak self] in self?.paletteActionsProvider?() ?? [] }
        pane.runAction = { [weak self] in self?.runPaletteAction?($0) }
        commandPane = pane
        item.view = pane
        return item
    }

    private func makeShelfTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "shelf")
        item.label = "Shelf"
        let view = ShelfDropView(frame: .zero)
        view.autoresizingMask = [.width, .height]
        item.view = view
        return item
    }

    /// Start/stop per-tab live activity: the Force Quit poll runs only while its
    /// tab is showing; the clipboard/command lists refresh when revealed.
    private func syncTabActivity() {
        let sel = tabView?.selectedTabViewItem?.identifier as? String
        if sel == "forcequit" { forceQuitPane?.start() } else { forceQuitPane?.stop() }
        if sel == "clipboard" { clipboardPane?.reload() }
        if sel == "command" { commandPane?.reload() }
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        syncTabActivity()
    }

    private var gapField: NSTextField?
    private var snapshotIntervalField: NSTextField?
    private var snapshotIntervalStepper: NSStepper?
    private var overlayCloseField: NSTextField?
    private var overlayCloseStepper: NSStepper?
    /// Called when the periodic snapshot interval changes so the timer restarts.
    var onSnapshotIntervalChanged: (() -> Void)?
    private var accessibilityStatusLabel: NSTextField!
    private var logTextView: NSTextView!

    private func checkbox(_ title: String, state: Bool, action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.state = state ? .on : .off
        return b
    }

    @objc private func toggleLaunchAtLogin(_ s: NSButton) {
        let on = s.state == .on
        Settings.shared.launchAtLogin = on; Settings.shared.save()
        LoginItem.setEnabled(on)
    }

    @objc private func toggleMenuBar(_ s: NSButton) {
        Settings.shared.showInMenuBar = s.state == .on; Settings.shared.save()
        NotificationCenter.default.post(name: .windowSnapMenuBarToggled, object: nil)
    }
    @objc private func toggleSnapEdges(_ s: NSButton) {
        Settings.shared.snapToScreenEdges = s.state == .on; Settings.shared.save()
    }
    @objc private func toggleSound(_ s: NSButton) {
        Settings.shared.playFeedbackSound = s.state == .on; Settings.shared.save()
    }
    private func applyOverlayClose(_ raw: Int) {
        let clamped = min(120, max(1, raw))
        Settings.shared.overlayAutoCloseSeconds = clamped
        Settings.shared.save()
        overlayCloseField?.stringValue = "\(clamped)"
        overlayCloseStepper?.integerValue = clamped
    }
    @objc private func overlayCloseStepped(_ s: NSStepper) { applyOverlayClose(s.integerValue) }
    @objc private func overlayCloseChanged(_ f: NSTextField) {
        applyOverlayClose(Int(f.stringValue) ?? Settings.shared.overlayAutoCloseSeconds)
    }
    @objc private func gapChanged(_ s: NSStepper) {
        Settings.shared.gapBetweenWindows = s.integerValue; Settings.shared.save()
        gapField?.stringValue = "\(s.integerValue)"
    }
    private func applySnapshotInterval(_ raw: Int) {
        let clamped = min(3600, max(5, raw))
        Settings.shared.snapshotIntervalSeconds = clamped
        Settings.shared.save()
        snapshotIntervalField?.stringValue = "\(clamped)"
        snapshotIntervalStepper?.integerValue = clamped
        onSnapshotIntervalChanged?()
    }
    @objc private func snapshotIntervalStepped(_ s: NSStepper) {
        applySnapshotInterval(s.integerValue)
    }
    @objc private func snapshotIntervalChanged(_ f: NSTextField) {
        applySnapshotInterval(Int(f.stringValue) ?? Settings.shared.snapshotIntervalSeconds)
    }
    @objc private func toggleOverwriteOnStandbyOrLock(_ s: NSButton) {
        let on = s.state == .on
        Settings.shared.overwriteOnStandby = on
        Settings.shared.overwriteOnLock = on
        // Locked to the Default layout.
        Settings.shared.standbyLayoutID = LayoutManager.defaultLayoutID
        Settings.shared.save()
    }
    @objc private func toggleShowMagnifier(_ s: NSButton) {
        Settings.shared.overlayShowMagnifier = s.state == .on; Settings.shared.save()
    }
    @objc private func toggleDragToSnap(_ s: NSButton) {
        Settings.shared.dragToSnapEnabled = s.state == .on; Settings.shared.save()
        NotificationCenter.default.post(name: .windowSnapDragToSnapToggled, object: nil)
    }
    @objc private func toggleSnapFlash(_ s: NSButton) {
        Settings.shared.snapFlashEnabled = s.state == .on; Settings.shared.save()
    }
    @objc private func toggleClipboardHistory(_ s: NSButton) {
        let on = s.state == .on
        Settings.shared.clipboardHistoryEnabled = on; Settings.shared.save()
        if on { ClipboardHistory.shared.start() } else { ClipboardHistory.shared.stop() }
    }
    @objc private func toggleClipboardAutoPaste(_ s: NSButton) {
        Settings.shared.clipboardAutoPaste = s.state == .on; Settings.shared.save()
    }
    @objc private func toggleRestoreOnWake(_ s: NSButton) {
        Settings.shared.restoreOnWake = s.state == .on
        // Locked to the Default layout.
        Settings.shared.wakeLayoutID = LayoutManager.defaultLayoutID
        Settings.shared.save()
    }

    /// Builds the assignment menu for one function key and selects the current
    /// assignment. Items carry their stored value in `representedObject`:
    /// "none", "choose", "system:<id>", or an app bundle path.
    private func buildFunctionKeyMenu(for fk: String, popup: NSPopUpButton) {
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

    @objc private func functionKeyPopupChanged(_ sender: NSPopUpButton) {
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
    private func chooseApplication(for fk: String) -> URL? {
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
    private func promptForKillProcessName(appURL: URL) -> String? {
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

    @objc private func grantAccessibility() {
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

    private func refreshAccessibilityStatus() {
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
    private func makePinnedRestoreRow(id: String, name: String) -> NSView {
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

    @objc private func restorePinnedButton(_ sender: NSButton) {
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

    @objc private func clearPinnedShortcut(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("pinnedClear:") else { return }
        let key = String(raw.dropFirst("pinnedClear:".count))
        Settings.shared.clearShortcut(key)
        // Reset the recorder title for whichever pinned id maps to this key.
        let id = (key == "restoreDefault") ? LayoutManager.defaultLayoutID : LayoutManager.presentationLayoutID
        pinnedRestoreRecorders[id]?.title = "Click to set"
        onShortcutsChanged?()
    }

    /// Builds the activity-log section (used at the bottom of the Layouts tab).
    private func makeLogSection() -> NSView {
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

    private func refreshLogTextValue() {
        guard let tv = logTextView else { return }
        tv.string = Logger.formattedLines().joined(separator: "\n")
        // Newest is now the first line — keep the view scrolled to the top.
        tv.scrollToBeginningOfDocument(nil)
    }

    @objc private func refreshLog() {
        DispatchQueue.main.async { [weak self] in self?.refreshLogTextValue() }
    }

    @objc private func clearLog() {
        Logger.clear()
        refreshLogTextValue()
    }

    // MARK: - Tab 3: Layouts
    private func makeLayoutsTab() -> NSTabViewItem {
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

    @objc private func saveCurrentLayout() {
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

    @objc private func overwriteSelected() {
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

    @objc private func restoreSelected() {
        // Manages SAVED layouts only.
        guard let id = lastSavedLayoutID,
              let target = layouts.first(where: { $0.id == id }) else { NSSound.beep(); return }
        LayoutManager.restore(target)
    }

    @objc private func deleteSelected() {
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

    @objc private func saveDefaultLayout() {
        let id = LayoutManager.defaultLayoutID
        var fresh = LayoutManager.capture(named: LayoutManager.defaultLayoutName)
        fresh.id = id
        LayoutManager.savePinned(fresh, id: id)
        Logger.log("Saved Default (\(fresh.windows.count) win)")
        reloadLayouts()
        defaultCanvas?.layout = fresh
    }

    @objc private func overwriteDefaultLayout() {
        // Same effect as save for a pinned slot: recapture into the Default id.
        saveDefaultLayout()
    }

    @objc private func restoreDefaultLayout() {
        guard let target = LayoutManager.loadPinned(LayoutManager.defaultLayoutID) else {
            NSSound.beep(); return
        }
        LayoutManager.restore(target)
    }

    @objc private func deleteDefaultLayout() {
        LayoutManager.deletePinned(LayoutManager.defaultLayoutID)
        Logger.log("Cleared Default")
        reloadLayouts()
        defaultCanvas?.layout = LayoutManager.loadPinned(LayoutManager.defaultLayoutID)
        onLayoutShortcutsChanged?()
    }

    @objc private func clearOverwriteShortcut() {
        Settings.shared.shortcuts["overwriteLayout"] = nil
        Settings.shared.save()
        overwriteShortcutButton.title = "Click to set"
        onShortcutsChanged?()
    }

    private func makeDivider() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }
}

// MARK: - Table data source / delegate
extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    // Table tags distinguish the two boxes.
    fileprivate static let defaultTableTag = 1   // Box 1: Default only
    fileprivate static let mainTableTag = 2      // Box 2: Presentation + saved

    /// The id displayed at a given row of a given table, or nil.
    private func layoutID(in tableTag: Int, row: Int) -> String? {
        if tableTag == Self.defaultTableTag {
            return row == 0 ? LayoutManager.defaultLayoutID : nil
        }
        // Main table shows ONLY saved layouts (the pinned layouts live in their
        // own box / restore buttons, not in this list).
        return (row >= 0 && row < layouts.count) ? layouts[row].id : nil
    }

    /// The layout at a given row of a given table, or nil.
    private func layout(in tableTag: Int, row: Int) -> Layout? {
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
    private func makeLayoutRowCell(id: String, name: String, key: String,
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

    /// The Overwrite-shortcut · Restore-shortcut · Clear button row under a name.
    /// `restoreKey` is the restore shortcut key; the overwrite key is derived from
    /// the layout id. Clear wipes BOTH shortcuts.
    private func makeActionButtonsRow(id: String, name: String, key restoreKey: String) -> NSView {
        let overwriteKey: String
        if LayoutManager.isPinned(id) {
            overwriteKey = (id == LayoutManager.defaultLayoutID) ? "overwriteDefault" : "overwritePresentation"
        } else {
            overwriteKey = "overwriteLayout:\(id)"
        }

        let overwriteControl = makeShortcutControl(key: overwriteKey, id: id, name: name, isOverwrite: true)
        let restoreControl = makeShortcutControl(key: restoreKey, id: id, name: name, isOverwrite: false)

        let clearBtn = NSButton(title: "Clear", target: self, action: #selector(clearRowShortcut(_:)))
        clearBtn.bezelStyle = .rounded
        clearBtn.controlSize = .small
        clearBtn.font = .systemFont(ofSize: 11)
        clearBtn.toolTip = "Clear both the overwrite and restore shortcuts for “\(name)”."
        // Encode both keys so the handler can clear them together.
        clearBtn.identifier = NSUserInterfaceItemIdentifier("rowClear:\(restoreKey)||\(overwriteKey)")

        for (v, w) in [(overwriteControl, CGFloat(92)), (restoreControl, 92), (clearBtn, 46)] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: w).isActive = true
        }

        // Restore (↻) sits to the LEFT of Overwrite (💾).
        let stack = NSStackView(views: [restoreControl, overwriteControl, clearBtn])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.distribution = .fill
        return stack
    }

    /// Builds one shortcut control: while unbound it records a shortcut; once
    /// bound it becomes a button that performs the action (overwrite or restore)
    /// on click. The bound hotkey also works globally.
    private func makeShortcutControl(key: String, id: String, name: String, isOverwrite: Bool) -> NSView {
        // 💾 (save) for overwrite, ↻ (restore) for restore.
        let glyph = isOverwrite ? "💾" : "↻"
        if let sc = Settings.shared.shortcuts[key] {
            let btn = NSButton(title: "\(glyph) \(sc.display)", target: self,
                               action: isOverwrite ? #selector(overwriteRowButton(_:)) : #selector(restoreRowButton(_:)))
            btn.identifier = NSUserInterfaceItemIdentifier((isOverwrite ? "rowOverwrite:" : "rowRestore:") + id)
            btn.toolTip = isOverwrite
                ? "Click to overwrite “\(name)” with the current windows (or press \(sc.display)). Use Clear to change."
                : "Click to restore “\(name)” (or press \(sc.display)). Use Clear to change."
            btn.bezelStyle = .rounded; btn.controlSize = .small; btn.font = .systemFont(ofSize: 11)
            return btn
        }
        let recorder = ShortcutRecorder(regionKey: key, current: nil) { [weak self] sc in
            Settings.shared.setShortcut(key, sc)
            self?.onShortcutsChanged?()
            self?.reloadLayoutTables()
        }
        recorder.onClear = { [weak self] in
            Settings.shared.clearShortcut(key)
            self?.onShortcutsChanged?()
        }
        recorder.title = "\(glyph) set key"
        recorder.toolTip = isOverwrite
            ? "Click, then press a key to set an OVERWRITE shortcut for “\(name)”."
            : "Click, then press a key to set a RESTORE shortcut for “\(name)”."
        recorder.bezelStyle = .rounded; recorder.controlSize = .small; recorder.font = .systemFont(ofSize: 11)
        return recorder
    }

    /// Reload both layout tables (used when an inline shortcut is set/cleared).
    private func reloadLayoutTables() {
        defaultTableView?.reloadData()
        mainTableView?.reloadData()
    }

    @objc private func beginRenameSelected() {
        let r = mainTableView.selectedRow
        guard r >= 0, r < layouts.count else { return }
        mainTableView.editColumn(0, row: r, with: nil, select: true)
    }

    @objc private func restoreRowButton(_ sender: NSButton) {
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

    @objc private func clearRowShortcut(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("rowClear:") else { return }
        let keys = String(raw.dropFirst("rowClear:".count)).components(separatedBy: "||")
        for k in keys where !k.isEmpty { Settings.shared.clearShortcut(k) }
        onShortcutsChanged?()
        // Refresh so the buttons reset to "set key".
        reloadLayoutTables()
    }

    @objc private func overwriteRowButton(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("rowOverwrite:") else { return }
        let id = String(raw.dropFirst("rowOverwrite:".count))
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

    @objc private func renameCommitted(_ sender: NSTextField) {
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

extension Notification.Name {
    static let windowSnapMenuBarToggled = Notification.Name("windowSnapMenuBarToggled")
    /// Posted when the drag-to-edge snapping preference is toggled, so the app
    /// delegate can start or stop the global mouse monitors.
    static let windowSnapDragToSnapToggled = Notification.Name("windowSnapDragToSnapToggled")
    /// Posted when the Keep Awake state changes (menu can refresh its checkmarks).
    static let windowSnapKeepAwakeChanged = Notification.Name("windowSnapKeepAwakeChanged")
    /// Posted when the clipboard history changes (open picker can refresh live).
    static let windowSnapClipboardChanged = Notification.Name("windowSnapClipboardChanged")
    /// Posted when the shelf contents change (all shelf views refresh).
    static let windowSnapShelfChanged = Notification.Name("windowSnapShelfChanged")
    /// Posted when the saved-layouts list changes outside the UI (e.g. the
    /// periodic 'Saved' capture) so the Layouts tab can reload its table.
    static let windowSnapLayoutsChanged = Notification.Name("windowSnapLayoutsChanged")
}

/// A flipped container view used as a scroll view's documentView so its content
/// is anchored to the top-left (instead of AppKit's default bottom-left origin)
/// when the document is shorter than the visible area.
final class FlippedClipView: NSView {
    override var isFlipped: Bool { true }
}
