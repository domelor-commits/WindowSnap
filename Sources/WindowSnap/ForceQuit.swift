import Cocoa
import ApplicationServices
import Darwin

/// One app's live health snapshot.
struct AppStatus {
    let pid: pid_t
    let name: String
    let icon: NSImage?
    let cpu: Double        // percent; can exceed 100 on multicore (a runaway thread)
    let mem: UInt64        // physical memory footprint in bytes (Activity Monitor's "Memory")
    let responding: Bool
}

/// Samples running UI apps for CPU usage and responsiveness so the user can spot
/// and kill whatever is bogging the Mac down.
final class ProcessMonitor {
    static let shared = ProcessMonitor()
    private var prev: [pid_t: (cpu: UInt64, time: Date)] = [:]

    /// Snapshot of foreground (UI) apps, sorted not-responding first then by CPU
    /// descending. Call OFF the main thread — the responsiveness probe blocks
    /// briefly for each hung app.
    func snapshot() -> [AppStatus] {
        let now = Date()
        let selfPid = ProcessInfo.processInfo.processIdentifier
        var out: [AppStatus] = []
        var seen = Set<pid_t>()

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            guard pid > 0, pid != selfPid else { continue }
            seen.insert(pid)

            var pct = 0.0
            let cpuNow = Self.cpuTimeNs(pid)
            if let cur = cpuNow, let last = prev[pid] {
                let dCPU = Double(cur &- last.cpu)
                let dWall = now.timeIntervalSince(last.time) * 1_000_000_000
                if dWall > 0 { pct = max(0, dCPU / dWall * 100) }
            }
            if let cur = cpuNow { prev[pid] = (cur, now) }

            out.append(AppStatus(pid: pid, name: app.localizedName ?? "Unknown",
                                 icon: app.icon, cpu: pct, mem: Self.memoryBytes(pid),
                                 responding: Self.isResponding(pid)))
        }
        prev = prev.filter { seen.contains($0.key) }   // forget exited pids

        return out.sorted {
            if $0.responding != $1.responding { return !$0.responding }
            return $0.cpu > $1.cpu
        }
    }

    /// Cumulative CPU time (user+system) in nanoseconds for a pid, or nil.
    private static func cpuTimeNs(_ pid: pid_t) -> UInt64? {
        var usage = rusage_info_current()
        let rc = withUnsafeMutablePointer(to: &usage) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, Int32(RUSAGE_INFO_CURRENT), $0)
            }
        }
        guard rc == 0 else { return nil }
        return usage.ri_user_time &+ usage.ri_system_time
    }

    /// Physical memory footprint (bytes) for a pid, matching Activity Monitor's
    /// "Memory" column. 0 if it can't be read (e.g. the process just exited).
    private static func memoryBytes(_ pid: pid_t) -> UInt64 {
        var usage = rusage_info_current()
        let rc = withUnsafeMutablePointer(to: &usage) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, Int32(RUSAGE_INFO_CURRENT), $0)
            }
        }
        return rc == 0 ? usage.ri_phys_footprint : 0
    }

    /// Heuristic: probe an Accessibility attribute with a short timeout. A blocked
    /// main thread can't service the request, so it times out (`.cannotComplete`).
    private static func isResponding(_ pid: pid_t) -> Bool {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.35)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &value)
        return err != .cannotComplete
    }
}

/// Floating panel listing apps with CPU% + responsiveness and a Force Quit button.
final class ForceQuitPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let shared = ForceQuitPanel()

    private var panel: NSPanel?
    private var table: NSTableView!
    private var statuses: [AppStatus] = []
    private var timer: Timer?
    private var refreshing = false

    func show() {
        if let p = panel {
            NSApp.activate()
            p.makeKeyAndOrderFront(nil)
            refresh()
            return
        }
        build()
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }  // quick CPU fill-in
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func build() {
        let w: CGFloat = 560, h: CGFloat = 380
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "Force Quit — Activity"
        p.isFloatingPanel = true
        p.level = .floating
        p.becomesKeyOnlyIfNeeded = false
        p.isReleasedWhenClosed = false
        p.delegate = self

        table = NSTableView()
        for (id, title, width) in [("app", "Application", CGFloat(240)),
                                   ("cpu", "CPU", 70), ("mem", "Memory", 80),
                                   ("status", "Status", 130)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title; c.width = width
            table.addTableColumn(c)
        }
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(forceQuitSelected)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let quitBtn = NSButton(title: "Force Quit", target: self, action: #selector(forceQuitSelected))
        quitBtn.bezelStyle = .rounded
        quitBtn.keyEquivalent = "\r"
        quitBtn.translatesAutoresizingMaskIntoConstraints = false
        let refreshBtn = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.translatesAutoresizingMaskIntoConstraints = false
        let hint = NSTextField(labelWithString: "Not-responding apps and CPU hogs are listed first.")
        hint.font = .systemFont(ofSize: 10); hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let content = p.contentView!
        content.addSubview(scroll)
        content.addSubview(quitBtn)
        content.addSubview(refreshBtn)
        content.addSubview(hint)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: quitBtn.topAnchor, constant: -8),
            quitBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            quitBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            refreshBtn.trailingAnchor.constraint(equalTo: quitBtn.leadingAnchor, constant: -8),
            refreshBtn.centerYAnchor.constraint(equalTo: quitBtn.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            hint.centerYAnchor.constraint(equalTo: quitBtn.centerYAnchor),
        ])

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: w, height: h)
        p.setFrameOrigin(NSPoint(x: vis.midX - w / 2, y: vis.midY - h / 2))

        panel = p
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
    }

    private func refresh() {
        guard !refreshing, panel != nil else { return }
        refreshing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snap = ProcessMonitor.shared.snapshot()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.refreshing = false
                guard self.panel != nil else { return }
                let selPid = (self.table.selectedRow >= 0 && self.table.selectedRow < self.statuses.count)
                    ? self.statuses[self.table.selectedRow].pid : nil
                self.statuses = snap
                self.table.reloadData()
                if let pid = selPid, let idx = snap.firstIndex(where: { $0.pid == pid }) {
                    self.table.selectRowIndexes([idx], byExtendingSelection: false)
                }
            }
        }
    }

    @objc private func refreshClicked() { refresh() }

    @objc private func forceQuitSelected() {
        let row = table.selectedRow
        guard row >= 0, row < statuses.count else { NSSound.beep(); return }
        let s = statuses[row]
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Force quit “\(s.name)”?"
        alert.informativeText = "Force quitting is abrupt — any unsaved work in \(s.name) will be lost."
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let killed = NSRunningApplication(processIdentifier: s.pid)?.forceTerminate() ?? false
        Logger.log("Force quit \(s.name) (pid \(s.pid)) — \(killed ? "ok" : "failed")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { statuses.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let s = statuses[row]
        let id = col?.identifier.rawValue ?? ""
        let cell = NSTableCellView()

        if id == "app" {
            let iv = NSImageView(); iv.image = s.icon
            iv.translatesAutoresizingMaskIntoConstraints = false
            let tf = NSTextField(labelWithString: s.name)
            tf.lineBreakMode = .byTruncatingTail
            tf.textColor = s.responding ? .labelColor : .systemRed
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv); cell.addSubview(tf)
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 18),
                iv.heightAnchor.constraint(equalToConstant: 18),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            if id == "cpu" {
                tf.stringValue = "\(Int(s.cpu.rounded()))%"
                tf.alignment = .right
                tf.textColor = s.cpu >= 80 ? .systemOrange : .secondaryLabelColor
            } else if id == "mem" {
                tf.stringValue = ByteCountFormatter.string(fromByteCount: Int64(s.mem), countStyle: .memory)
                tf.alignment = .right
                tf.textColor = s.mem >= 2_000_000_000 ? .systemOrange : .secondaryLabelColor
            } else {   // status
                tf.stringValue = s.responding ? "Responding" : "Not Responding"
                tf.textColor = s.responding ? .secondaryLabelColor : .systemRed
            }
            cell.addSubview(tf)
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil
        panel = nil
    }
}

// MARK: - In-window Force Quit / activity tab

// MARK: - Force Quit / activity tab

final class ForceQuitPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var statuses: [AppStatus] = []
    private var timer: Timer?
    private var refreshing = false

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); build() }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        for (id, title, width) in [("app", "Application", CGFloat(240)),
                                   ("cpu", "CPU", 70), ("mem", "Memory", 80),
                                   ("status", "Status", 130)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title; c.width = width
            if id == "app" { c.resizingMask = .autoresizingMask }
            table.addTableColumn(c)
        }
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(forceQuitSelected)

        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.translatesAutoresizingMaskIntoConstraints = false

        let quitBtn = NSButton(title: "Force Quit", target: self, action: #selector(forceQuitSelected))
        let refreshBtn = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        for b in [quitBtn, refreshBtn] { b.bezelStyle = .rounded; b.translatesAutoresizingMaskIntoConstraints = false }
        let hint = NSTextField(labelWithString: "Not-responding apps and CPU hogs are listed first.")
        hint.font = .systemFont(ofSize: 10); hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll); addSubview(quitBtn); addSubview(refreshBtn); addSubview(hint)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: quitBtn.topAnchor, constant: -8),
            quitBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            quitBtn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            refreshBtn.trailingAnchor.constraint(equalTo: quitBtn.leadingAnchor, constant: -8),
            refreshBtn.centerYAnchor.constraint(equalTo: quitBtn.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            hint.centerYAnchor.constraint(equalTo: quitBtn.centerYAnchor),
        ])
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common); timer = t
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snap = ProcessMonitor.shared.snapshot()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.refreshing = false
                let selPid = (self.table.selectedRow >= 0 && self.table.selectedRow < self.statuses.count)
                    ? self.statuses[self.table.selectedRow].pid : nil
                self.statuses = snap
                self.table.reloadData()
                if let pid = selPid, let idx = snap.firstIndex(where: { $0.pid == pid }) {
                    self.table.selectRowIndexes([idx], byExtendingSelection: false)
                }
            }
        }
    }

    @objc private func refreshClicked() { refresh() }

    @objc private func forceQuitSelected() {
        let row = table.selectedRow
        guard row >= 0, row < statuses.count else { NSSound.beep(); return }
        let s = statuses[row]
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Force quit “\(s.name)”?"
        alert.informativeText = "Force quitting is abrupt — any unsaved work in \(s.name) will be lost."
        alert.addButton(withTitle: "Force Quit"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = NSRunningApplication(processIdentifier: s.pid)?.forceTerminate()
        Logger.log("Force quit \(s.name) (pid \(s.pid))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { statuses.count }
    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let s = statuses[row]
        let id = col?.identifier.rawValue ?? ""
        let cell = NSTableCellView()
        if id == "app" {
            let iv = NSImageView(); iv.image = s.icon; iv.translatesAutoresizingMaskIntoConstraints = false
            let tf = NSTextField(labelWithString: s.name)
            tf.lineBreakMode = .byTruncatingTail
            tf.textColor = s.responding ? .labelColor : .systemRed
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv); cell.addSubview(tf)
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 18), iv.heightAnchor.constraint(equalToConstant: 18),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        } else {
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            if id == "cpu" {
                tf.stringValue = "\(Int(s.cpu.rounded()))%"; tf.alignment = .right
                tf.textColor = s.cpu >= 80 ? .systemOrange : .secondaryLabelColor
            } else if id == "mem" {
                tf.stringValue = ByteCountFormatter.string(fromByteCount: Int64(s.mem), countStyle: .memory)
                tf.alignment = .right
                tf.textColor = s.mem >= 2_000_000_000 ? .systemOrange : .secondaryLabelColor
            } else {
                tf.stringValue = s.responding ? "Responding" : "Not Responding"
                tf.textColor = s.responding ? .secondaryLabelColor : .systemRed
            }
            cell.addSubview(tf)
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        return cell
    }
}
