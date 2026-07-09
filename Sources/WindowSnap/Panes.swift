import Cocoa

// MARK: - Clipboard history tab

/// In-window clipboard history: a searchable list; double-click or Copy puts an
/// item back on the clipboard. (Auto-paste lives in the floating picker, since
/// here the app window itself is frontmost.)
final class ClipboardHistoryPane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let table = NSTableView()
    private let searchField = NSTextField()
    private var filtered: [ClipEntry] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: .windowSnapClipboardChanged, object: nil)
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        searchField.placeholderString = "Search…"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col); table.headerView = nil; table.rowHeight = 28
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(copySelected)

        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.translatesAutoresizingMaskIntoConstraints = false

        let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copySelected))
        let clearBtn = NSButton(title: "Clear", target: self, action: #selector(clearAll))
        for b in [copyBtn, clearBtn] { b.bezelStyle = .rounded; b.translatesAutoresizingMaskIntoConstraints = false }
        let hint = NSTextField(labelWithString: "Double-click or Copy to put an item back on the clipboard.")
        hint.font = .systemFont(ofSize: 10); hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        addSubview(searchField); addSubview(scroll); addSubview(copyBtn); addSubview(clearBtn); addSubview(hint)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: copyBtn.topAnchor, constant: -8),
            copyBtn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            copyBtn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            clearBtn.leadingAnchor.constraint(equalTo: copyBtn.trailingAnchor, constant: 8),
            clearBtn.centerYAnchor.constraint(equalTo: copyBtn.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            hint.centerYAnchor.constraint(equalTo: copyBtn.centerYAnchor),
        ])
    }

    @objc func reload() { applyFilter(searchField.stringValue) }

    private func applyFilter(_ q: String) {
        let all = ClipboardHistory.shared.entries
        let ql = q.lowercased()
        filtered = q.isEmpty ? all : all.filter {
            if case .text(let s) = $0.kind { return s.lowercased().contains(ql) }
            return "image".contains(ql)
        }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter(searchField.stringValue) }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let l = NSTextField(labelWithString: ClipboardHistoryPanel.preview(filtered[row]))
        l.lineBreakMode = .byTruncatingTail; l.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            l.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            l.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    @objc private func copySelected() {
        let r = table.selectedRow; guard r >= 0, r < filtered.count else { return }
        let pb = NSPasteboard.general; pb.clearContents()
        switch filtered[r].kind {
        case .text(let s):  pb.setString(s, forType: .string)
        case .image(let i): pb.writeObjects([i])
        }
    }
    @objc private func clearAll() { ClipboardHistory.shared.clear() }
}

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
                                   ("cpu", "CPU", 70), ("status", "Status", 130)] {
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

// MARK: - Command palette tab

final class CommandPalettePane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var actionsProvider: (() -> [PaletteAction])?
    var runAction: ((PaletteAction) -> Void)?

    private let table = NSTableView()
    private let searchField = NSTextField()
    private var all: [PaletteAction] = []
    private var filtered: [PaletteAction] = []

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); build() }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        searchField.placeholderString = "Run a command…"
        searchField.font = .systemFont(ofSize: 14)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cmd"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col); table.headerView = nil; table.rowHeight = 32
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(runSelected)

        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.translatesAutoresizingMaskIntoConstraints = false

        let runBtn = NSButton(title: "Run", target: self, action: #selector(runSelected))
        runBtn.bezelStyle = .rounded; runBtn.translatesAutoresizingMaskIntoConstraints = false
        let hint = NSTextField(labelWithString: "↑/↓ to move · Return to run")
        hint.font = .systemFont(ofSize: 10); hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        addSubview(searchField); addSubview(scroll); addSubview(runBtn); addSubview(hint)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: runBtn.topAnchor, constant: -8),
            runBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            runBtn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            hint.centerYAnchor.constraint(equalTo: runBtn.centerYAnchor),
        ])
    }

    func reload() {
        all = actionsProvider?() ?? []
        applyFilter(searchField.stringValue)
    }

    private func applyFilter(_ q: String) {
        let ql = q.lowercased()
        filtered = q.isEmpty ? all : all.filter {
            $0.title.lowercased().contains(ql) || $0.subtitle.lowercased().contains(ql)
        }
        table.reloadData()
        if !filtered.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter(searchField.stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)):      move(1);  return true
        case #selector(NSResponder.moveUp(_:)):        move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): runSelected(); return true
        default: return false
        }
    }
    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let cur = table.selectedRow < 0 ? 0 : table.selectedRow
        let next = min(max(0, cur + delta), filtered.count - 1)
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let a = filtered[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: a.title)
        title.font = .systemFont(ofSize: 13); title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        let sub = NSTextField(labelWithString: a.subtitle)
        sub.font = .systemFont(ofSize: 11); sub.textColor = .secondaryLabelColor; sub.alignment = .right
        sub.setContentHuggingPriority(.required, for: .horizontal)
        sub.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(title); cell.addSubview(sub)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            sub.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            sub.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            sub.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    @objc private func runSelected() {
        let r = table.selectedRow
        guard r >= 0, r < filtered.count else { return }
        runAction?(filtered[r])
    }
}
