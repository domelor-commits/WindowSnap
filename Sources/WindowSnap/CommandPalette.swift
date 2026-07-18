import Cocoa

/// One runnable entry in the command palette.
struct PaletteAction {
    let title: String
    let subtitle: String
    let run: () -> Void
}

/// A searchable overlay (Raycast/Alfred-style) listing every WindowSnap action —
/// snaps, layout restores, captures, utilities, launchers. Type to filter, ↑/↓
/// to move, Return to run, Esc to dismiss.
final class CommandPalette: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                            NSTextFieldDelegate, NSWindowDelegate {
    static let shared = CommandPalette()

    private var panel: NSPanel?
    private var searchField: NSTextField!
    private var table: NSTableView!
    private var all: [PaletteAction] = []
    private var filtered: [PaletteAction] = []
    private var frontApp: NSRunningApplication?

    func show(actions: [PaletteAction]) {
        if panel != nil { close(); return }
        frontApp = NSWorkspace.shared.frontmostApplication   // so snaps target the right window
        all = actions
        filtered = actions
        CurrencyRates.prefetch()   // warm currency rates for "100 usd to sgd"
        build()
    }

    private func build() {
        let w: CGFloat = 460, h: CGFloat = 420
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "Command Palette"
        p.isFloatingPanel = true
        p.level = .floating
        p.becomesKeyOnlyIfNeeded = false
        p.isReleasedWhenClosed = false
        p.delegate = self

        searchField = NSTextField()
        searchField.placeholderString = "Run a command…"
        searchField.font = .systemFont(ofSize: 15)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cmd"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 34
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(chooseClicked)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = p.contentView!
        content.addSubview(searchField)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: w, height: h)
        p.setFrameOrigin(NSPoint(x: vis.midX - w / 2, y: vis.maxY - h - 120))

        panel = p
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(searchField)
        if !filtered.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    private func applyFilter(_ q: String) {
        var results: [PaletteAction] = []
        // Calculator: arithmetic / unit / currency result as a copyable top row.
        if let answer = Calculator.evaluate(q) {
            results.append(PaletteAction(title: "= \(answer)", subtitle: "Copy result") {
                let pb = NSPasteboard.general
                pb.clearContents(); pb.setString(answer, forType: .string)
            })
        }
        let matches: [PaletteAction]
        if q.isEmpty {
            matches = all
        } else {
            let ql = q.lowercased()
            matches = all.filter { $0.title.lowercased().contains(ql) || $0.subtitle.lowercased().contains(ql) }
        }
        filtered = results + matches
        table?.reloadData()
        if !filtered.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    // MARK: Search key handling

    func controlTextDidChange(_ obj: Notification) { applyFilter(searchField.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)):        move(1);  return true
        case #selector(NSResponder.moveUp(_:)):          move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):   chooseSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): close();  return true
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

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let a = filtered[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: a.title)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        let sub = NSTextField(labelWithString: a.subtitle)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .right
        sub.setContentHuggingPriority(.required, for: .horizontal)
        sub.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(title); cell.addSubview(sub)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            sub.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            sub.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            sub.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func chooseClicked() { chooseSelected() }

    private func chooseSelected() {
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let action = filtered[row]
        close()
        // Restore the previously-frontmost app so window actions (snaps) target it,
        // then run the command.
        frontApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { action.run() }
    }

    private func close() { panel?.close() }
    func windowWillClose(_ notification: Notification) { panel = nil }
}
