import Cocoa

/// A translucent HUD listing every currently-assigned keyboard shortcut, grouped
/// into Snapping / Layouts / Launchers. Toggled from the menu bar or a bindable
/// system task. Dismissed with Esc, by clicking it, or by toggling again.
final class CheatSheetOverlay {
    static let shared = CheatSheetOverlay()

    private var panel: NSPanel?
    private var keyMonitor: Any?

    var isVisible: Bool { panel != nil }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard panel == nil else { return }
        let rows = Self.groupedShortcuts()
        let content = Self.buildContentView(groups: rows)

        let size = content.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = content

        // Center on the screen under the pointer.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2))
        }
        p.orderFrontRegardless()
        panel = p

        // Dismiss on Esc or any click.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.type == .keyDown, event.keyCode != 53 { return event }  // only Esc closes via keys
            self?.hide()
            return event.type == .keyDown ? nil : event
        }
    }

    func hide() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Content

    private struct Row { let action: String; let combo: String }

    private static func groupedShortcuts() -> [(title: String, rows: [Row])] {
        let sc = Settings.shared.shortcuts

        // Snapping — in a stable, readable order.
        let snapOrder: [(SnapRegion, String)] = [
            (.leftHalf, "Left Half"), (.rightHalf, "Right Half"),
            (.topHalf, "Top Half"), (.bottomHalf, "Bottom Half"),
            (.topLeft, "Top Left"), (.topRight, "Top Right"),
            (.bottomLeft, "Bottom Left"), (.bottomRight, "Bottom Right"),
            (.leftThird, "Left Third"), (.centerThird, "Center Third"), (.rightThird, "Right Third"),
            (.maximize, "Maximize"), (.center, "Center"),
        ]
        var snapping: [Row] = []
        for (region, label) in snapOrder {
            if let s = sc[region.rawValue] { snapping.append(Row(action: label, combo: s.display)) }
        }

        // Layouts — pinned restores/overwrites plus any per-saved-layout binding.
        var layouts: [Row] = []
        func add(_ key: String, _ label: String) {
            if let s = sc[key] { layouts.append(Row(action: label, combo: s.display)) }
        }
        add("restoreDefault", "Restore Default Layout")
        add("restorePresentation", "Restore Presentation Layout")
        add("overwriteDefault", "Overwrite Default Layout")
        add("overwritePresentation", "Overwrite Presentation Layout")
        for layout in LayoutManager.loadAll() {
            add("restoreLayout:\(layout.id)", "Restore: \(layout.name)")
            add("overwriteLayout:\(layout.id)", "Overwrite: \(layout.name)")
        }

        // Launchers — each assigned slot with its app / system-task title.
        var launchers: [Row] = []
        for slot in Settings.launcherSlots {
            guard let s = sc["launcher:\(slot)"],
                  let assignment = Settings.shared.functionKeyApps[slot], !assignment.isEmpty else { continue }
            launchers.append(Row(action: Settings.functionKeyAssignmentTitle(assignment), combo: s.display))
        }

        return [("Snapping", snapping), ("Layouts", layouts), ("Launchers", launchers)]
            .filter { !$0.rows.isEmpty }
    }

    private static func buildContentView(groups: [(title: String, rows: [Row])]) -> NSView {
        // Rounded translucent backdrop.
        let root = NSVisualEffectView()
        root.material = .hudWindow
        root.state = .active
        root.blendingMode = .behindWindow
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true
        root.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "Keyboard Shortcuts")
        heading.font = .systemFont(ofSize: 17, weight: .bold)
        stack.addArrangedSubview(heading)

        if groups.isEmpty {
            let none = NSTextField(labelWithString: "No shortcuts assigned yet.")
            none.textColor = .secondaryLabelColor
            stack.addArrangedSubview(none)
        }

        for group in groups {
            let sectionTitle = NSTextField(labelWithString: group.title.uppercased())
            sectionTitle.font = .systemFont(ofSize: 11, weight: .semibold)
            sectionTitle.textColor = .secondaryLabelColor
            stack.setCustomSpacing(14, after: stack.arrangedSubviews.last ?? heading)
            stack.addArrangedSubview(sectionTitle)

            let grid = NSGridView()
            grid.columnSpacing = 24
            grid.rowSpacing = 4
            grid.translatesAutoresizingMaskIntoConstraints = false
            for row in group.rows {
                let action = NSTextField(labelWithString: row.action)
                action.font = .systemFont(ofSize: 13)
                let combo = NSTextField(labelWithString: row.combo)
                combo.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
                combo.alignment = .right
                grid.addRow(with: [action, combo])
            }
            if grid.numberOfColumns >= 2 {
                grid.column(at: 1).xPlacement = .trailing
            }
            stack.addArrangedSubview(grid)
        }

        let hint = NSTextField(labelWithString: "Press Esc or click to dismiss")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last ?? heading)
        stack.addArrangedSubview(hint)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        root.frame = NSRect(origin: .zero, size: root.fittingSize)
        return root
    }
}
