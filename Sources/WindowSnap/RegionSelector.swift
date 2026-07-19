import Cocoa

// MARK: - Region selector

/// Full-screen translucent overlay where the user drags out a rectangle.
/// Reports the selection in GLOBAL CoreGraphics coordinates (top-left origin
/// on the primary display), or nil when cancelled with Esc. Appears on the
/// screen currently containing the mouse pointer.
final class RegionSelector {
    static let shared = RegionSelector()
    private var panel: NSPanel?
    private var completion: ((CGRect?) -> Void)?

    func begin(_ completion: @escaping (CGRect?) -> Void) {
        guard panel == nil else { completion(nil); return }
        self.completion = completion

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.frame
        let primaryTop = NSScreen.screens[0].frame.maxY

        // Grab this display (before showing the overlay) so the magnifier can
        // sample live pixels without capturing the overlay itself.
        let dispCG = CGRect(x: f.minX, y: primaryTop - f.maxY, width: f.width, height: f.height)
        let displayImage = ScreenGrab.cgImage(dispCG).map { NSImage(cgImage: $0, size: f.size) }

        let panel = KeyablePanel(contentRect: f,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Exclude this overlay from screen captures. Without this, if the panel is
        // still on screen the instant CGWindowListCreateImage runs, sub-pixel
        // rounding of the capture rect can pick up the dim/border it draws just
        // outside the selection — showing as a thin line on the top/left edges.
        // sharingType .none makes the window invisible to capture APIs (the user
        // still sees it), so nothing it draws can ever land in a grabbed image.
        panel.sharingType = .none

        let view = RegionSelectionView(frame: NSRect(origin: .zero, size: f.size))
        view.displayImage = displayImage
        view.screenOrigin = f.origin
        view.primaryTop = primaryTop
        view.showMagnifier = Settings.shared.overlayShowMagnifier
        view.onDone = { [weak self] localRect in
            guard let self = self else { return }
            let done = self.completion
            self.cancel()
            guard let r = localRect else { done?(nil); return }
            let nsRect = r.offsetBy(dx: f.minX, dy: f.minY)
            let cgRect = CGRect(x: nsRect.minX, y: primaryTop - nsRect.maxY,
                                width: nsRect.width, height: nsRect.height)
            done?(cgRect)
        }
        panel.contentView = view
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        NSCursor.crosshair.set()
        self.panel = panel
    }

    private func cancel() {
        panel?.orderOut(nil)
        panel = nil
        completion = nil
        NSCursor.arrow.set()
    }
}

/// Borderless panels refuse key status by default; the selector needs it so
/// Esc can cancel.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class RegionSelectionView: NSView {
    var onDone: ((CGRect?) -> Void)?
    var displayImage: NSImage?
    var screenOrigin: CGPoint = .zero    // this screen's global NS origin
    var primaryTop: CGFloat = 0
    var showMagnifier = true

    private var start: CGPoint?
    private var current: CGPoint?
    private var cursor: CGPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited], owner: self, userInfo: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Darker surround so the selection stands out more.
        let dim = NSColor(calibratedWhite: 0, alpha: 0.5)

        if let a = start, let b = current {
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                           width: abs(a.x - b.x), height: abs(a.y - b.y))
            // Dim ONLY outside the selection: fill the whole view with the
            // selection punched out (even-odd), so the selected area shows true,
            // undimmed pixels. No border is drawn — a stroked outline can bleed
            // into the captured pixels on the top/left edges if the overlay is
            // still on screen at grab time.
            dim.setFill()
            let mask = NSBezierPath(rect: bounds)
            mask.append(NSBezierPath(rect: r))
            mask.windingRule = .evenOdd
            mask.fill()
            drawDimensions(r)
        } else {
            dim.setFill()
            bounds.fill()
            let hint = NSAttributedString(string: "Drag to select — Esc cancels",
                attributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.white])
            let sz = hint.size()
            hint.draw(at: CGPoint(x: bounds.midX - sz.width / 2, y: bounds.maxY - 60))
        }
        drawMagnifier(at: cursor)
    }

    /// Large W × H readout plus the simplified aspect ratio, following the
    /// selection's top edge. Big font so it's easy to read while dragging.
    private func drawDimensions(_ r: CGRect) {
        let w = Int(r.width.rounded()), h = Int(r.height.rounded())
        let text = "\(w) × \(h)   ·   \(Self.aspectRatioString(w, h))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34, weight: .bold),
            .foregroundColor: NSColor.white]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz = str.size()
        var pos = CGPoint(x: r.midX - sz.width / 2, y: r.maxY + 10)
        pos.x = max(bounds.minX + 8, min(pos.x, bounds.maxX - sz.width - 8))
        if pos.y + sz.height > bounds.maxY - 4 { pos.y = r.minY - sz.height - 10 }
        let bg = CGRect(x: pos.x - 12, y: pos.y - 6, width: sz.width + 24, height: sz.height + 12)
        NSColor(calibratedWhite: 0, alpha: 0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()
        str.draw(at: pos)
    }

    /// Aspect ratio as a recognizable name. Snaps to common monitor/slide
    /// ratios (16:9, 21:9, 32:9, 16:10, 4:3, 3:2 …) when the selection is close,
    /// so an ultrawide reads "21:9" rather than its exact "43:18".
    static func aspectRatioString(_ w: Int, _ h: Int) -> String {
        guard w > 0, h > 0 else { return "—" }
        let ratio = Double(w) / Double(h)
        // (decimal value, label). Ultrawide 3440×1440 is exactly 43:18 ≈ 2.389
        // but is universally called 21:9, so both map to "21:9".
        let common: [(Double, String)] = [
            (1.0, "1:1"), (1.25, "5:4"), (4.0 / 3.0, "4:3"), (1.5, "3:2"),
            (1.6, "16:10"), (16.0 / 9.0, "16:9"), (2.333, "21:9"),
            (3440.0 / 1440.0, "21:9"), (32.0 / 9.0, "32:9"),
            (3.0 / 4.0, "3:4"), (9.0 / 16.0, "9:16"), (10.0 / 16.0, "10:16"),
        ]
        if let best = common.min(by: { abs($0.0 - ratio) < abs($1.0 - ratio) }),
           abs(best.0 - ratio) / ratio < 0.02 {   // within 2%
            return best.1
        }
        // Otherwise show the reduced fraction if small, else a decimal.
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(w, h), rw = w / g, rh = h / g
        if rw <= 40 && rh <= 40 { return "\(rw):\(rh)" }
        return String(format: "%.2f:1", ratio)
    }

    /// CleanShot-style loupe: a zoomed, pixelated view of the pixels under the
    /// cursor, with crosshair, a highlighted center pixel, and coordinates.
    private func drawMagnifier(at p: CGPoint) {
        guard showMagnifier, let img = displayImage else { return }
        let loupe: CGFloat = 116, zoom: CGFloat = 8
        let srcHalf = loupe / (2 * zoom)
        let src = CGRect(x: p.x - srcHalf, y: p.y - srcHalf, width: srcHalf * 2, height: srcHalf * 2)

        var lx = p.x + 18, ly = p.y - loupe - 18
        if lx + loupe > bounds.maxX - 4 { lx = p.x - loupe - 18 }
        if ly < bounds.minY + 4 { ly = p.y + 18 }
        let dest = CGRect(x: lx, y: ly, width: loupe, height: loupe)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: dest, xRadius: 8, yRadius: 8).addClip()
        NSColor.black.setFill(); dest.fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        img.draw(in: dest, from: src, operation: .copy, fraction: 1)   // non-flipped view → upright
        NSGraphicsContext.restoreGraphicsState()

        NSColor(calibratedWhite: 1, alpha: 0.55).setStroke()
        let ch = NSBezierPath()
        ch.move(to: CGPoint(x: dest.midX, y: dest.minY)); ch.line(to: CGPoint(x: dest.midX, y: dest.maxY))
        ch.move(to: CGPoint(x: dest.minX, y: dest.midY)); ch.line(to: CGPoint(x: dest.maxX, y: dest.midY))
        ch.lineWidth = 1; ch.stroke()

        NSColor.systemBlue.setStroke()
        NSBezierPath(rect: CGRect(x: dest.midX - zoom / 2, y: dest.midY - zoom / 2,
                                  width: zoom, height: zoom)).stroke()
        NSColor(calibratedWhite: 1, alpha: 0.85).setStroke()
        let border = NSBezierPath(roundedRect: dest, xRadius: 8, yRadius: 8); border.lineWidth = 1.5; border.stroke()

        // Global point coordinates under the cursor (x above y, like the loupe).
        let gx = Int(screenOrigin.x + p.x)
        let gy = Int(primaryTop - (screenOrigin.y + p.y))
        let coord = "\(gx)\n\(gy)"
        NSAttributedString(string: coord, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white]).draw(at: CGPoint(x: dest.minX + 3, y: dest.maxY + 3))
    }

    override func mouseMoved(with event: NSEvent) { cursor = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil); current = start; cursor = start!; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil); cursor = current!; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { start = nil; current = nil }
        guard let a = start, let b = current else { onDone?(nil); return }
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        onDone?(r.width > 20 && r.height > 20 ? r : nil)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone?(nil) } else { super.keyDown(with: event) }
    }
}
