import Cocoa
import ApplicationServices

/// One captured window.
///
/// Identifying windows is layered because no single field is stable in every
/// situation, and Chrome is the hard case: its title follows the active tab, so
/// the title changes whenever you close a tab.
///
/// - `cgWindowNumber` (CoreGraphics window id): stable for the life of the app
///   process and does NOT change when a tab/title changes — the best key for
///   telling many open Chrome windows apart within a session.
/// - `windowIndex`: the window's position in the app's window list — a fallback
///   that survives relaunches as long as windows aren't reordered.
/// - `windowTitle`: last resort, and skipped for apps whose titles are volatile.
struct WindowSnapshot: Codable {
    var appName: String
    var appBundleID: String
    var pid: Int32
    var cgWindowNumber: Int?    // per-session stable id (survives title changes)
    var windowIndex: Int        // position in the app's window list
    var windowTitle: String
    var frame: CGRectCodable
    var displayID: String       // which monitor (matches DisplayInfo.id)
}

struct CGRectCodable: Codable {
    var x, y, width, height: CGFloat
    init(_ r: CGRect) { x = r.minX; y = r.minY; width = r.width; height = r.height }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// A monitor's geometry, captured with the layout so the viewer can draw it.
struct DisplayInfo: Codable {
    var id: String             // signature of frame
    var name: String
    var frame: CGRectCodable
    var isPrimary: Bool
}

struct Layout: Codable {
    var id: String = UUID().uuidString
    var name: String
    var displaySignature: String
    var displays: [DisplayInfo]
    var windows: [WindowSnapshot]
    var savedAt: Date
}

enum LayoutManager {

    /// Reserved, non-deletable "pinned" layouts shown at the top of the list.
    /// Each lives in its own file, separate from the user's saved-layouts list.
    static let defaultLayoutID = "windowsnap.default.layout"
    static let defaultLayoutName = "Default"
    static let presentationLayoutID = "windowsnap.presentation.layout"
    static let presentationLayoutName = "Presentation"

    /// The pinned layouts in display order: (id, name).
    static let pinnedLayouts: [(id: String, name: String)] = [
        (defaultLayoutID, defaultLayoutName),
        (presentationLayoutID, presentationLayoutName),
    ]

    static func isPinned(_ id: String) -> Bool {
        pinnedLayouts.contains { $0.id == id }
    }

    static func pinnedName(for id: String) -> String {
        pinnedLayouts.first { $0.id == id }?.name ?? "Layout"
    }

    // MARK: - Rolling "Saved" periodic capture

    /// Name prefix used for the auto-captured rolling snapshot in the saved list.
    static let autoSavedNamePrefix = "Saved "
    /// Current name for the rolling auto-capture. The save date/time is shown in
    /// its own column, so the name no longer carries a timestamp.
    static let autoSavedName = "Saved"

    /// True if a saved layout is the rolling auto-capture. Matches the current
    /// bare "Saved" name as well as the legacy "Saved <timestamp>" names.
    static func isAutoSaved(_ layout: Layout) -> Bool {
        layout.name == autoSavedName || layout.name.hasPrefix(autoSavedNamePrefix)
    }

    /// Capture the current windows into a single rolling "Saved <timestamp>"
    /// layout in the saved-layouts list, deleting any previous "Saved …" entry
    /// first so only the newest exists. Returns the captured layout, or nil if
    /// the capture was empty (e.g. screen locked) — in which case nothing is
    /// written and the previous Saved entry is kept.
    @discardableResult
    static func writeRollingSavedCapture() -> Layout? {
        let fresh = capture(named: "")
        guard !fresh.windows.isEmpty else { return nil }

        var saved = fresh
        saved.name = autoSavedName   // date/time shown in its own column now
        saved.id = UUID().uuidString

        var all = loadAll().filter { !isAutoSaved($0) }   // drop old Saved entries
        all.append(saved)
        save(all)
        return saved
    }

    /// The newest rolling "Saved …" capture from the saved list, if any.
    static func latestRollingSavedCapture() -> Layout? {
        loadAll().filter { isAutoSaved($0) }.max(by: { $0.savedAt < $1.savedAt })
    }

    /// True only if every display recorded in the layout has at least one window
    /// on it — i.e. all monitors have apps. Used to avoid overwriting the Default
    /// layout with a partial capture that misses a monitor.
    static func windowsCoverAllDisplays(_ layout: Layout) -> Bool {
        guard !layout.displays.isEmpty else { return false }
        let withWindows = Set(layout.windows.map { $0.displayID })
        return layout.displays.allSatisfy { withWindows.contains($0.id) }
    }

    /// Cheap drift check used by the post-wake fix-up passes: for each app that
    /// still has at least as many windows open as the layout saved, every display
    /// must hold at least the saved number of that app's windows. Returns false
    /// when a late display reconnect has shuffled windows off their monitor.
    static func arrangementMatches(_ layout: Layout) -> Bool {
        guard layout.displaySignature == displaySignature() else { return false }

        var expected: [String: [String: Int]] = [:]   // displayID → bundle → count
        var expectedTotal: [String: Int] = [:]        // bundle → saved total
        for w in layout.windows {
            expected[w.displayID, default: [:]][w.appBundleID, default: 0] += 1
            expectedTotal[w.appBundleID, default: 0] += 1
        }

        var actual: [String: [String: Int]] = [:]
        var actualTotal: [String: Int] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundle = app.bundleIdentifier, expectedTotal[bundle] != nil else { continue }
            for win in WindowController.windows(of: app.processIdentifier) {
                guard WindowController.isRealWindow(win, bundleID: bundle),
                      let f = WindowController.getFrame(of: win) else { continue }
                actual[displayID(forAXFrame: f), default: [:]][bundle, default: 0] += 1
                actualTotal[bundle, default: 0] += 1
            }
        }

        for (bundle, total) in expectedTotal {
            // If the user closed windows (fewer open than saved), skip this app
            // rather than flag a false drift.
            guard (actualTotal[bundle] ?? 0) >= total else { continue }
            for (disp, apps) in expected {
                if let savedCount = apps[bundle],
                   (actual[disp]?[bundle] ?? 0) < savedCount {
                    return false
                }
            }
        }
        return true
    }

    static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowSnap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("layouts.json")
    }

    /// Per-pinned-layout storage file.
    static func pinnedStoreURL(for id: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowSnap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Use the id as the filename (sanitized) so each pinned layout is isolated.
        let safe = id.replacingOccurrences(of: ".", with: "-")
        return dir.appendingPathComponent("pinned-\(safe).json")
    }

    /// Load a pinned layout by id, or nil if it hasn't been saved yet.
    static func loadPinned(_ id: String) -> Layout? {
        guard let data = try? Data(contentsOf: pinnedStoreURL(for: id)),
              let layout = try? JSONDecoder().decode(Layout.self, from: data) else { return nil }
        return layout
    }

    /// Persist a pinned layout (atomic write).
    static func savePinned(_ layout: Layout, id: String) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        do { try data.write(to: pinnedStoreURL(for: id), options: .atomic) }
        catch { try? data.write(to: pinnedStoreURL(for: id)) }
    }

    /// Remove a pinned layout's saved windows (the row itself stays pinned).
    static func deletePinned(_ id: String) {
        try? FileManager.default.removeItem(at: pinnedStoreURL(for: id))
    }

    // --- Backward-compatible Default helpers (delegate to the generic ones).
    // The original Default file path is migrated on first load.
    static var defaultStoreURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowSnap", isDirectory: true)
        return dir.appendingPathComponent("default-layout.json")
    }

    static func loadDefault() -> Layout? {
        // Migrate the old default-layout.json to the new pinned path once.
        if FileManager.default.fileExists(atPath: defaultStoreURL.path),
           !FileManager.default.fileExists(atPath: pinnedStoreURL(for: defaultLayoutID).path),
           let data = try? Data(contentsOf: defaultStoreURL) {
            try? data.write(to: pinnedStoreURL(for: defaultLayoutID), options: .atomic)
        }
        return loadPinned(defaultLayoutID)
    }

    static func saveDefault(_ layout: Layout) { savePinned(layout, id: defaultLayoutID) }
    static func deleteDefault() { deletePinned(defaultLayoutID) }

    static func currentDisplays() -> [DisplayInfo] {
        let primaryFrame = NSScreen.screens.first?.frame ?? .zero
        return NSScreen.screens.enumerated().map { idx, screen in
            let f = screen.frame
            let sig = "\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))"
            let name = screen.localizedName.isEmpty ? "Display \(idx + 1)" : screen.localizedName
            return DisplayInfo(id: sig, name: name, frame: CGRectCodable(f),
                               isPrimary: f == primaryFrame)
        }
    }

    static func displaySignature() -> String {
        currentDisplays().map { $0.id }.sorted().joined(separator: "|")
    }

    /// Which display (by NSScreen frame) contains the center of an AX-origin frame.
    /// Returns "" when there are no screens (all displays asleep/disconnected),
    /// which callers treat as "unknown display".
    static func displayID(forAXFrame axFrame: CGRect) -> String {
        func signature(_ f: CGRect) -> String {
            "\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))"
        }
        guard let primaryHeight = NSScreen.screens.first?.frame.maxY else { return "" }
        let center = CGPoint(x: axFrame.midX, y: primaryHeight - axFrame.midY)
        for screen in NSScreen.screens where screen.frame.contains(center) {
            return signature(screen.frame)
        }
        guard let main = NSScreen.main else { return "" }
        return signature(main.frame)
    }

    static func loadAll() -> [Layout] {
        guard let data = try? Data(contentsOf: storeURL),
              let layouts = try? JSONDecoder().decode([Layout].self, from: data) else { return [] }
        return layouts
    }

    static func save(_ layouts: [Layout]) {
        guard let data = try? JSONEncoder().encode(layouts) else { return }
        // Atomic write: data lands in a temp file and is swapped in as a whole,
        // so a write interrupted by sleep can't truncate or corrupt the store.
        do {
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // Fall back to a plain write rather than losing the data entirely.
            try? data.write(to: storeURL)
        }
    }

    static func capture(named name: String) -> Layout {
        var snapshots: [WindowSnapshot] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let windows = WindowController.windows(of: app.processIdentifier)
            for (index, win) in windows.enumerated() {
                guard WindowController.isRealWindow(win, bundleID: app.bundleIdentifier) else { continue }
                guard let frame = WindowController.getFrame(of: win) else { continue }
                snapshots.append(WindowSnapshot(
                    appName: app.localizedName ?? "Unknown",
                    appBundleID: app.bundleIdentifier ?? "",
                    pid: app.processIdentifier,
                    cgWindowNumber: WindowController.windowNumber(of: win),
                    windowIndex: index,
                    windowTitle: WindowController.getTitle(of: win),
                    frame: CGRectCodable(frame),
                    displayID: displayID(forAXFrame: frame)))
            }
        }
        return Layout(name: name, displaySignature: displaySignature(),
                      displays: currentDisplays(), windows: snapshots, savedAt: Date())
    }

    static func restore(_ layout: Layout) {
        guard layout.displaySignature == displaySignature() else {
            notify("Display arrangement changed", "Saved layout was for a different monitor setup.")
            Logger.log("Restore “\(layout.name)”: aborted — monitors differ")
            return
        }

        // Map each saved displayID to the matching CURRENT screen frame. Because
        // a displayID is a frame signature and the overall signature matched
        // above, the same key exists now; we still resolve to the live frame so
        // a window can be translated onto the correct physical monitor even if a
        // display's origin shifted slightly across the wake.
        var currentScreenFrameByID: [String: CGRect] = [:]
        for screen in NSScreen.screens {
            let f = screen.frame
            currentScreenFrameByID["\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))"] = f
        }
        let savedFrameByID = Dictionary(uniqueKeysWithValues:
            layout.displays.map { ($0.id, $0.frame.rect) })

        // Translate a saved window frame so it lands on the same physical display
        // it was captured on, compensating for any shift in that display's origin.
        func targetFrame(for snap: WindowSnapshot) -> CGRect {
            guard let savedDisp = savedFrameByID[snap.displayID],
                  let liveDisp = currentScreenFrameByID[snap.displayID] else {
                return snap.frame.rect   // unknown display: use absolute frame
            }
            let dx = liveDisp.minX - savedDisp.minX
            let dy = liveDisp.minY - savedDisp.minY
            return snap.frame.rect.offsetBy(dx: dx, dy: dy)
        }

        let byBundle = Dictionary(grouping: layout.windows, by: { $0.appBundleID })

        var moved = 0
        var perDisplayMoved: [String: Int] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundle = app.bundleIdentifier, var targets = byBundle[bundle] else { continue }
            let liveWindows = WindowController.windows(of: app.processIdentifier)

            // Capture each live window's id, title, and CURRENT frame/monitor so
            // we can pair by the most stable key available and, failing that, by
            // physical position (so windows don't jump monitors).
            struct Live { let el: AXUIElement; let index: Int; let cg: Int?
                          let title: String; let frame: CGRect?; let display: String }
            let live: [Live] = liveWindows.enumerated().map { idx, el in
                let f = WindowController.getFrame(of: el)
                return Live(el: el, index: idx,
                            cg: WindowController.windowNumber(of: el),
                            title: WindowController.getTitle(of: el),
                            frame: f,
                            display: f.map { displayID(forAXFrame: $0) } ?? "")
            }
            var usedLive = Set<Int>()

            enum MatchMethod: String { case cgWindow = "id", title, position }

            func displayName(_ id: String) -> String {
                layout.displays.first(where: { $0.id == id })?.name ?? id
            }

            // Nearest unused live window to where this snapshot should land,
            // strongly preferring a window already on the target monitor so
            // windows are filled per-monitor and don't needlessly jump screens.
            func positionIndex(for snap: WindowSnapshot) -> Int? {
                let t = targetFrame(for: snap)
                let tc = CGPoint(x: t.midX, y: t.midY)
                var best: Int?; var bestScore = Double.greatestFiniteMagnitude
                for (i, l) in live.enumerated() where !usedLive.contains(l.index) {
                    let f = l.frame ?? .zero
                    let dx = Double(f.midX - tc.x), dy = Double(f.midY - tc.y)
                    let sameMonitor = (l.display == snap.displayID)
                    let score = (dx * dx + dy * dy).squareRoot() + (sameMonitor ? 0 : 5_000_000)
                    if score < bestScore { bestScore = score; best = i }
                }
                return best
            }

            // Build the pairing in stable-key order across ALL windows first, so a
            // reliable id/title match is never stolen by an earlier position guess.
            let sorted = targets.sorted { $0.windowIndex < $1.windowIndex }
            var assigned = Set<Int>()                                   // indices into `sorted`
            var plan: [(snapIdx: Int, liveIdx: Int, method: MatchMethod)] = []

            // Pass 1 — CoreGraphics window id: stable within a session and, unlike
            // the title, does NOT change when Chrome tabs open/close.
            for (si, snap) in sorted.enumerated() {
                guard let cg = snap.cgWindowNumber,
                      let i = live.firstIndex(where: { !usedLive.contains($0.index) && $0.cg == cg })
                else { continue }
                usedLive.insert(live[i].index); assigned.insert(si)
                plan.append((si, i, .cgWindow))
            }
            // Pass 2 — exact title: stable for apps whose titles don't change
            // (skipped for volatile ones like Chrome, which fall through to pos).
            if Settings.shared.restoreLayoutMatchByTitle {
                for (si, snap) in sorted.enumerated() where !assigned.contains(si) {
                    guard !snap.windowTitle.isEmpty,
                          let i = live.firstIndex(where: { !usedLive.contains($0.index) && $0.title == snap.windowTitle })
                    else { continue }
                    usedLive.insert(live[i].index); assigned.insert(si)
                    plan.append((si, i, .title))
                }
            }
            // Pass 3 — position: fills the remaining saved slots with the nearest
            // remaining windows, keeping each on its current monitor when possible.
            for (si, snap) in sorted.enumerated() where !assigned.contains(si) {
                guard let i = positionIndex(for: snap) else { continue }
                usedLive.insert(live[i].index); assigned.insert(si)
                plan.append((si, i, .position))
            }

            for step in plan {
                let snap = sorted[step.snapIdx]
                let el = live[step.liveIdx].el
                let frame = targetFrame(for: snap)
                let beforeDisplay = WindowController.getFrame(of: el).map { displayID(forAXFrame: $0) } ?? "?"
                WindowController.setFrame(frame, for: el)
                // If macOS clamped the cross-display move (window didn't reach the
                // target monitor), re-apply once — the second attempt starts from
                // the target screen and sticks.
                if let after = WindowController.getFrame(of: el),
                   displayID(forAXFrame: after) != snap.displayID {
                    WindowController.setFrame(frame, for: el)
                }
                moved += 1
                perDisplayMoved[snap.displayID, default: 0] += 1

                // Only log anomalies to keep the log short.
                if let after = WindowController.getFrame(of: el),
                   displayID(forAXFrame: after) != snap.displayID {
                    Logger.log("⚠︎ \(snap.appName): landed on \(displayName(displayID(forAXFrame: after))), not \(displayName(snap.displayID))")
                } else if step.method == .position, beforeDisplay != snap.displayID, beforeDisplay != "?" {
                    Logger.log("↔︎ \(snap.appName): \(displayName(beforeDisplay))→\(displayName(snap.displayID))")
                }
            }
            targets.removeAll()
        }

        // Compact one-line per-display summary, e.g. "LEN:4 DELL:3".
        let perDisp = layout.displays
            .map { "\($0.name):\(perDisplayMoved[$0.id] ?? 0)" }
            .joined(separator: " ")

        if Settings.shared.playFeedbackSound { NSSound.beep() }
        if moved == 0 {
            notify("Nothing to restore", "No matching windows for “\(layout.name)”.")
            Logger.log("Restore “\(layout.name)”: 0 placed")
        } else {
            notify("Layout restored", "\(layout.name) — \(moved) window\(moved == 1 ? "" : "s")")
            Logger.log("Restore “\(layout.name)”: \(moved)/\(layout.windows.count) placed [\(perDisp)]")
        }
    }

    static func notify(_ title: String, _ body: String) {
        Notifier.shared.post(title: title, body: body)
    }
}
