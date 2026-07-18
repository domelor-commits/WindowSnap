import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import UniformTypeIdentifiers

/// The main app window with three tabs: Layouts, Settings, Annotate.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate, NSPopoverDelegate {

    var onShortcutsChanged: (() -> Void)?
    var onSnapRequested: ((SnapRegion) -> Void)?
    var onSaveLayoutRequested: (() -> Void)?

    var tabView: NSTabView!
    var annotatorPane: AnnotatorPane!
    var layoutCanvas: LayoutCanvas!
    var defaultCanvas: LayoutCanvas!
    var defaultTableView: NSTableView!
    var mainTableView: NSTableView!
    var rowShortcutPopover: NSPopover?
    var selectedLayoutID: String?
    /// The most recently selected SAVED layout id (from the main table only).
    /// Used to keep the Saved Layout canvas populated even when focus moves to
    /// the Default row.
    var lastSavedLayoutID: String?
    var layouts: [Layout] = []
    var pinnedRestoreRecorders: [String: ShortcutRecorder] = [:]
    var pinnedRestoreRows: [NSView] = []
    var overwriteShortcutButton: ShortcutRecorder!

    /// Called by the app delegate when a layout's restore shortcut changes,
    /// so global hotkeys can be re-registered.
    var onLayoutShortcutsChanged: (() -> Void)?

    /// Supplied by the app delegate so the Command Palette tab can list and run
    /// every action (and restore focus to the previously-active app for snaps).
    var paletteActionsProvider: (() -> [PaletteAction])?
    var runPaletteAction: ((PaletteAction) -> Void)?

    // In-window feature tabs (mirror the shared data behind the floating panels).
    var clipboardPane: ClipboardHistoryPane?
    var forceQuitPane: ForceQuitPane?
    /// Stops the live translator when its tab is hidden or the window closes.
    var translationPaneStop: (() -> Void)?

    // Settings-tab controls the toggle handlers read back (in extension files).
    var gapField: NSTextField?
    var snapshotIntervalField: NSTextField?
    var snapshotIntervalStepper: NSStepper?
    var overlayCloseField: NSTextField?
    var overlayCloseStepper: NSStepper?
    /// Called when the periodic snapshot interval changes so the timer restarts.
    var onSnapshotIntervalChanged: (() -> Void)?
    var accessibilityStatusLabel: NSTextField!
    var logTextView: NSTextView!

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

    @objc func layoutsChangedExternally() {
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
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        syncTabActivity()   // (re)start the Force Quit poll if that tab is showing
    }

    func windowWillClose(_ notification: Notification) {
        forceQuitPane?.stop()   // don't keep sampling CPU while the window is closed
        translationPaneStop?()  // stop audio capture / transcription
    }

    /// Size the window so the entire Settings tab content is visible without
    /// scrolling, capped to the screen's visible height, and re-center it.
    func resizeToFitContent() {
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

    func sectionHeader(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s.uppercased())
        l.font = .systemFont(ofSize: 10, weight: .bold)
        l.textColor = .secondaryLabelColor
        return l
    }

    /// Wraps a vertical content stack in a top-anchored scroll view for a tab.
    func wrapInScroll(_ doc: NSStackView, identifier: String, label: String) -> NSTabViewItem {
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

    // MARK: - Window content: custom tab header (icon above label) + tab views

    var tabButtons: [NSButton] = []

    func installContent(into content: NSView, select index: Int) {
        content.subviews.forEach { $0.removeFromSuperview() }
        tabButtons = []

        let tv = NSTabView()
        tv.tabViewType = .noTabsNoBorder
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.addTabViewItem(makeLayoutsTab())      // 0
        tv.addTabViewItem(makeAnnotateTab())     // 1
        tv.addTabViewItem(makeClipboardTab())    // 2
        tv.addTabViewItem(makeForceQuitTab())    // 3
        tv.addTabViewItem(makeShortcutsTab())    // 4
        tv.addTabViewItem(makeConversionTab())   // 5
        tv.addTabViewItem(makeTranslationTab())  // 6
        tv.addTabViewItem(makeSettingsTab())     // 7
        tv.delegate = self
        self.tabView = tv

        let defs: [(String, String)] = [
            ("Layouts", "macwindow"),
            ("Annotate", "pencil.tip.crop.circle"),
            ("Clipboard", "doc.on.clipboard"),
            ("Force Quit", "xmark.octagon"),
            ("Shortcuts", "command"),
            ("Convert", "arrow.left.arrow.right"),
            ("Translation", "globe"),
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

    @objc func tabButtonPressed(_ sender: NSButton) { selectTab(sender.tag) }

    func selectTab(_ i: Int) {
        guard let tv = tabView, i >= 0, i < tv.numberOfTabViewItems else { return }
        tv.selectTabViewItem(at: i)
        for (j, b) in tabButtons.enumerated() {
            b.contentTintColor = (j == i) ? .controlAccentColor : .secondaryLabelColor
        }
    }

    func checkbox(_ title: String, state: Bool, action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.state = state ? .on : .off
        return b
    }

    @objc func toggleLaunchAtLogin(_ s: NSButton) {
        let on = s.state == .on
        Settings.shared.launchAtLogin = on; Settings.shared.save()
        LoginItem.setEnabled(on)
    }

    @objc func toggleMenuBar(_ s: NSButton) {
        Settings.shared.showInMenuBar = s.state == .on; Settings.shared.save()
        NotificationCenter.default.post(name: .windowSnapMenuBarToggled, object: nil)
    }
    @objc func toggleSnapEdges(_ s: NSButton) {
        Settings.shared.snapToScreenEdges = s.state == .on; Settings.shared.save()
    }
    @objc func toggleSound(_ s: NSButton) {
        Settings.shared.playFeedbackSound = s.state == .on; Settings.shared.save()
    }
    func applyOverlayClose(_ raw: Int) {
        let clamped = min(120, max(1, raw))
        Settings.shared.overlayAutoCloseSeconds = clamped
        Settings.shared.save()
        overlayCloseField?.stringValue = "\(clamped)"
        overlayCloseStepper?.integerValue = clamped
    }
    @objc func overlayCloseStepped(_ s: NSStepper) { applyOverlayClose(s.integerValue) }
    @objc func overlayCloseChanged(_ f: NSTextField) {
        applyOverlayClose(Int(f.stringValue) ?? Settings.shared.overlayAutoCloseSeconds)
    }
    @objc func gapChanged(_ s: NSStepper) {
        Settings.shared.gapBetweenWindows = s.integerValue; Settings.shared.save()
        gapField?.stringValue = "\(s.integerValue)"
    }
    func applySnapshotInterval(_ raw: Int) {
        let clamped = min(3600, max(5, raw))
        Settings.shared.snapshotIntervalSeconds = clamped
        Settings.shared.save()
        snapshotIntervalField?.stringValue = "\(clamped)"
        snapshotIntervalStepper?.integerValue = clamped
        onSnapshotIntervalChanged?()
    }
    @objc func snapshotIntervalStepped(_ s: NSStepper) {
        applySnapshotInterval(s.integerValue)
    }
    @objc func snapshotIntervalChanged(_ f: NSTextField) {
        applySnapshotInterval(Int(f.stringValue) ?? Settings.shared.snapshotIntervalSeconds)
    }
    @objc func toggleOverwriteOnStandbyOrLock(_ s: NSButton) {
        let on = s.state == .on
        Settings.shared.overwriteOnStandby = on
        Settings.shared.overwriteOnLock = on
        // Locked to the Default layout.
        Settings.shared.standbyLayoutID = LayoutManager.defaultLayoutID
        Settings.shared.save()
    }
    @objc func toggleShowMagnifier(_ s: NSButton) {
        Settings.shared.overlayShowMagnifier = s.state == .on; Settings.shared.save()
    }
    @objc func toggleMeetingBar(_ s: NSButton) {
        Settings.shared.meetingBarEnabled = s.state == .on; Settings.shared.save()
        if s.state == .on { MeetingBar.shared.requestAccessIfEnabled() }
    }
    @objc func toggleKeystrokeVizSetting(_ s: NSButton) {
        // start()/stop() persist the setting and start/stop the global monitor.
        if s.state == .on { KeystrokeVisualizer.shared.start() } else { KeystrokeVisualizer.shared.stop() }
    }
    @objc func dictationLanguageChanged(_ sender: NSPopUpButton) {
        Settings.shared.dictationLanguage = (sender.selectedItem?.representedObject as? String) ?? ""
        Settings.shared.save()
    }
    @objc func toggleDragToSnap(_ s: NSButton) {
        Settings.shared.dragToSnapEnabled = s.state == .on; Settings.shared.save()
        NotificationCenter.default.post(name: .windowSnapDragToSnapToggled, object: nil)
    }
    @objc func toggleSnapFlash(_ s: NSButton) {
        Settings.shared.snapFlashEnabled = s.state == .on; Settings.shared.save()
    }
    @objc func toggleClipboardHistory(_ s: NSButton) {
        let on = s.state == .on
        Settings.shared.clipboardHistoryEnabled = on; Settings.shared.save()
        if on { ClipboardHistory.shared.start() } else { ClipboardHistory.shared.stop() }
    }
    @objc func toggleClipboardAutoPaste(_ s: NSButton) {
        Settings.shared.clipboardAutoPaste = s.state == .on; Settings.shared.save()
    }
    @objc func toggleClipboardPersist(_ s: NSButton) {
        Settings.shared.clipboardPersistToDisk = s.state == .on; Settings.shared.save()
        // Write the current history now, or delete the on-disk store immediately.
        ClipboardHistory.shared.syncPersistence()
    }
    @objc func toggleRestoreOnWake(_ s: NSButton) {
        Settings.shared.restoreOnWake = s.state == .on
        // Locked to the Default layout.
        Settings.shared.wakeLayoutID = LayoutManager.defaultLayoutID
        Settings.shared.save()
    }

    /// Builds the assignment menu for one function key and selects the current
    /// assignment. Items carry their stored value in `representedObject`:
    /// "none", "choose", "system:<id>", or an app bundle path.
}

// MARK: - Table data source / delegate

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
