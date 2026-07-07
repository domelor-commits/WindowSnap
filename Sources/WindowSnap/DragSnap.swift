import Cocoa
import ApplicationServices

/// Magnet-style drag-to-edge snapping. Watches global mouse events; when a
/// window is dragged near a screen edge or corner, it shows a translucent
/// preview of where the window will land and snaps it there on release.
///
/// Zones (per the screen under the pointer):
///   • left / right edge  → left / right half
///   • top edge           → maximize
///   • bottom edge        → bottom half
///   • any corner         → that quarter
final class DragSnapManager {
    /// Called on release to actually place `window` in `region` on `screen`.
    var onSnap: ((AXUIElement, SnapRegion, NSScreen) -> Void)?

    private var downMonitor: Any?
    private var dragMonitor: Any?
    private var upMonitor: Any?

    // Per-gesture state (between mouse-down and mouse-up).
    private var candidate: AXUIElement?
    private var startFrame: CGRect?
    private var isWindowDrag = false
    private var currentZone: (region: SnapRegion, screen: NSScreen)?

    private lazy var preview: NSPanel = Self.makePreviewPanel()

    private let edge: CGFloat = 6          // px from the screen border to activate a zone
    private let corner: CGFloat = 150      // corner-zone length measured along each edge
    private let moveThreshold: CGFloat = 8 // window must move this far to count as a drag

    var isRunning: Bool { downMonitor != nil }

    func start() {
        guard downMonitor == nil else { return }
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.mouseDown()
        }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            self?.mouseDragged()
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.mouseUp()
        }
        Logger.log("Drag-to-snap: on")
    }

    func stop() {
        for m in [downMonitor, dragMonitor, upMonitor] { if let m = m { NSEvent.removeMonitor(m) } }
        downMonitor = nil; dragMonitor = nil; upMonitor = nil
        hidePreview(); reset()
        Logger.log("Drag-to-snap: off")
    }

    private func reset() {
        candidate = nil; startFrame = nil; isWindowDrag = false; currentZone = nil
    }

    // MARK: Gesture

    private func mouseDown() {
        // Record the frontmost window as the drag candidate and its start frame.
        // Clicking a window to drag it makes that app frontmost first, so the
        // focused window is the one about to move.
        candidate = WindowController.focusedWindow()
        startFrame = candidate.flatMap { WindowController.getFrame(of: $0) }
        isWindowDrag = false
        currentZone = nil
        hidePreview()
    }

    private func mouseDragged() {
        guard let window = candidate else { return }
        let mouse = NSEvent.mouseLocation
        guard let zone = zone(at: mouse) else { hidePreview(); currentZone = nil; return }

        // Confirm the gesture is actually moving a window (not selecting text or
        // rubber-banding the desktop) before showing a preview: the candidate
        // window's origin must have shifted from where the drag began.
        if !isWindowDrag {
            guard let start = startFrame, let now = WindowController.getFrame(of: window) else { return }
            let moved = hypot(now.origin.x - start.origin.x, now.origin.y - start.origin.y)
            if moved < moveThreshold { return }
            isWindowDrag = true
        }
        currentZone = zone
        showPreview(region: zone.region, screen: zone.screen)
    }

    private func mouseUp() {
        defer { hidePreview(); reset() }
        guard isWindowDrag, let zone = currentZone, let window = candidate else { return }
        onSnap?(window, zone.region, zone.screen)
    }

    // MARK: Zones

    private func zone(at mouse: CGPoint) -> (region: SnapRegion, screen: NSScreen)? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else { return nil }
        let f = screen.frame   // global, bottom-left origin (matches NSEvent.mouseLocation)

        if mouse.x <= f.minX + edge {
            if mouse.y >= f.maxY - corner { return (.topLeft, screen) }
            if mouse.y <= f.minY + corner { return (.bottomLeft, screen) }
            return (.leftHalf, screen)
        }
        if mouse.x >= f.maxX - edge {
            if mouse.y >= f.maxY - corner { return (.topRight, screen) }
            if mouse.y <= f.minY + corner { return (.bottomRight, screen) }
            return (.rightHalf, screen)
        }
        if mouse.y >= f.maxY - edge {
            if mouse.x <= f.minX + corner { return (.topLeft, screen) }
            if mouse.x >= f.maxX - corner { return (.topRight, screen) }
            return (.maximize, screen)
        }
        if mouse.y <= f.minY + edge {
            if mouse.x <= f.minX + corner { return (.bottomLeft, screen) }
            if mouse.x >= f.maxX - corner { return (.bottomRight, screen) }
            return (.bottomHalf, screen)
        }
        return nil
    }

    // MARK: Preview overlay

    private func showPreview(region: SnapRegion, screen: NSScreen) {
        preview.setFrame(previewFrame(region: region, screen: screen), display: true)
        if !preview.isVisible { preview.orderFrontRegardless() }
    }

    private func hidePreview() {
        if preview.isVisible { preview.orderOut(nil) }
    }

    /// The window's target frame in global bottom-left (AppKit) coordinates,
    /// matching where the snap will place it inside the screen's visibleFrame.
    private func previewFrame(region: SnapRegion, screen: NSScreen) -> NSRect {
        let v = screen.visibleFrame
        let box = CGRect(x: 0, y: 0, width: v.width, height: v.height)
        let r = region.frame(in: box)                        // top-left origin within box
        let nsX = v.minX + r.origin.x
        let nsY = v.minY + (v.height - r.origin.y - r.height) // flip to bottom-left
        return NSRect(x: nsX, y: nsY, width: r.width, height: r.height)
    }

    private static func makePreviewPanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true    // never interfere with the drag
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 8
        p.contentView = view
        return p
    }
}
