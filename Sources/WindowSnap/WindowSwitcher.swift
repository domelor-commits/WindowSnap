import Cocoa
import ApplicationServices

/// AltTab-style window switcher: a HUD of every open window (thumbnail + app icon
/// + title). Trigger the shortcut to open it; press it again — or Tab / arrows —
/// to move the selection; Return or releasing the trigger modifier switches to
/// the chosen window; Esc cancels.
final class WindowSwitcher {
    static let shared = WindowSwitcher()

    private struct Item {
        let pid: pid_t
        let appName: String
        let title: String
        let icon: NSImage?
        let thumb: NSImage?
        let axWindow: AXUIElement
    }

    private var items: [Item] = []
    private var cells: [NSView] = []
    private var selection = 0
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var flagsLocalMonitor: Any?
    private var flagsGlobalMonitor: Any?
    private var triggerMods: NSEvent.ModifierFlags = []

    var isVisible: Bool { panel != nil }

    /// Open the switcher, or advance the selection if it's already open (so
    /// repeatedly tapping the trigger cycles through windows).
    func toggle() {
        if isVisible { advance(1) } else { show() }
    }

    // MARK: Build

    private func show() {
        items = Self.collectWindows()
        Logger.log("Switcher: \(items.count) window(s)")
        guard items.count > 1 else {
            // Nothing to switch to (0 or 1 window) — a soft beep and bail.
            NSSound.beep()
            return
        }
        selection = 1   // pre-select the next window, so one tap+commit = "previous"
        triggerMods = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])

        let content = buildContent()
        let size = content.frame.size   // set explicitly in buildContent (scroll views don't report fittingSize)
        let p = SwitcherKeyPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .modalPanel
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = content
        // Center on the screen under the pointer (predictable across monitors).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2))
        }
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        highlight()
        installMonitors()
    }

    private func buildContent() -> NSView {
        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow; backdrop.state = .active; backdrop.blendingMode = .behindWindow
        backdrop.wantsLayer = true; backdrop.layer?.cornerRadius = 16; backdrop.layer?.masksToBounds = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        cells = items.enumerated().map { idx, item in makeCell(item, index: idx) }

        // Wrap the cells into a grid so many windows still fit on screen.
        let screenW = (NSScreen.main?.visibleFrame.width ?? 1200)
        let columns = max(1, min(cells.count, Int((screenW - 140) / 160)))
        var rowViews: [NSView] = []
        var i = 0
        while i < cells.count {
            let slice = Array(cells[i..<min(i + columns, cells.count)])
            let r = NSStackView(views: slice)
            r.orientation = .horizontal; r.spacing = 10; r.alignment = .top; r.distribution = .fill
            rowViews.append(r)
            i += columns
        }
        let grid = NSStackView(views: rowViews)
        grid.orientation = .vertical; grid.spacing = 10; grid.alignment = .leading
        grid.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        grid.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: backdrop.topAnchor),
            grid.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        backdrop.layoutSubtreeIfNeeded()
        backdrop.frame = NSRect(origin: .zero, size: backdrop.fittingSize)
        return backdrop
    }

    private func makeCell(_ item: Item, index: Int) -> NSView {
        let cell = NSView()
        cell.wantsLayer = true
        cell.layer?.cornerRadius = 10
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let thumb = NSImageView()
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.image = item.thumb ?? item.icon
        thumb.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = item.icon
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: item.title.isEmpty ? item.appName : item.title)
        title.font = .systemFont(ofSize: 11)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(thumb); cell.addSubview(icon); cell.addSubview(title)
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: cell.topAnchor, constant: 10),
            thumb.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 130),
            thumb.heightAnchor.constraint(equalToConstant: 100),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 6),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            title.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            title.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -10),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(cellClicked(_:)))
        cell.addGestureRecognizer(click)
        cell.identifier = NSUserInterfaceItemIdentifier("wswitch:\(index)")
        return cell
    }

    // MARK: Selection

    private func advance(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = ((selection + delta) % items.count + items.count) % items.count
        highlight()
    }

    private func highlight() {
        for (i, cell) in cells.enumerated() {
            cell.layer?.backgroundColor = (i == selection)
                ? NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
                : NSColor.clear.cgColor
        }
    }

    @objc private func cellClicked(_ g: NSClickGestureRecognizer) {
        guard let raw = g.view?.identifier?.rawValue, raw.hasPrefix("wswitch:"),
              let i = Int(raw.dropFirst("wswitch:".count)) else { return }
        selection = i
        commit()
    }

    // MARK: Monitors

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self else { return e }
            switch e.keyCode {
            case 48: self.advance(e.modifierFlags.contains(.shift) ? -1 : 1)   // Tab
            case 124, 125: self.advance(1)                                     // →, ↓
            case 123, 126: self.advance(-1)                                    // ←, ↑
            case 36, 76, 49: self.commit()                                     // Return, Enter, Space
            case 53: self.cancel()                                             // Esc
            default: break
            }
            return nil   // swallow keys while the switcher is up
        }
        // Commit when the trigger modifier is released (classic hold-and-release).
        if !triggerMods.isEmpty {
            let onFlags: (NSEvent) -> Void = { [weak self] e in
                guard let self = self else { return }
                if e.modifierFlags.intersection([.command, .option, .control, .shift]).isDisjoint(with: self.triggerMods) {
                    self.commit()
                }
            }
            flagsLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in onFlags(e); return e }
            flagsGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { e in onFlags(e) }
        }
    }

    private func removeMonitors() {
        for m in [keyMonitor, flagsLocalMonitor, flagsGlobalMonitor] { if let m = m { NSEvent.removeMonitor(m) } }
        keyMonitor = nil; flagsLocalMonitor = nil; flagsGlobalMonitor = nil
    }

    // MARK: Commit / cancel

    private func commit() {
        guard isVisible, selection >= 0, selection < items.count else { cancel(); return }
        let item = items[selection]
        close()
        NSRunningApplication(processIdentifier: item.pid)?.activate(options: [.activateIgnoringOtherApps])
        AXUIElementSetAttributeValue(item.axWindow, kAXMainWindowAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(item.axWindow, kAXRaiseAction as CFString)
        Logger.log("Switcher: → \(item.appName) — \(item.title.prefix(40))")
    }

    private func cancel() { close() }

    private func close() {
        removeMonitors()
        panel?.orderOut(nil); panel = nil
        cells = []; items = []
    }

    // MARK: Enumerate windows

    private static func collectWindows() -> [Item] {
        var result: [Item] = []
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Frontmost app first so the current window is index 0.
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { a, b in (a.processIdentifier == frontPID ? 0 : 1) < (b.processIdentifier == frontPID ? 0 : 1) }
        for app in apps {
            let icon = app.icon
            for win in WindowController.windows(of: app.processIdentifier) {
                guard WindowController.isRealWindow(win, bundleID: app.bundleIdentifier) else { continue }
                let title = WindowController.getTitle(of: win)
                let thumb = WindowController.windowNumber(of: win).flatMap { thumbnail(for: CGWindowID($0)) }
                result.append(Item(pid: app.processIdentifier,
                                   appName: app.localizedName ?? "App",
                                   title: title,
                                   icon: icon,
                                   thumb: thumb,
                                   axWindow: win))
            }
        }
        return result
    }

    /// A window's live image, if Screen Recording permission allows it; else nil
    /// (the cell falls back to the app icon).
    private static func thumbnail(for windowID: CGWindowID) -> NSImage? {
        guard windowID != 0 else { return nil }
        guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID,
                                               [.boundsIgnoreFraming, .nominalResolution]) else { return nil }
        guard cg.width > 1, cg.height > 1 else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// A borderless panel that can still become key (so it receives keyboard input).
private final class SwitcherKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
