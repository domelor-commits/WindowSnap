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
        let displayImage = CGWindowListCreateImage(dispCG, [.optionOnScreenOnly], kCGNullWindowID, [.bestResolution])
            .map { NSImage(cgImage: $0, size: f.size) }

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

// MARK: - Screen grabbing

enum ScreenGrab {
    /// Captures a global-CG-coordinate rect of the screen at full resolution.
    static func cgImage(_ rect: CGRect) -> CGImage? {
        CGWindowListCreateImage(rect, [.optionOnScreenOnly], kCGNullWindowID,
                                [.bestResolution])
    }

    static func image(_ rect: CGRect) -> NSImage? {
        cgImage(rect).map { NSImage(cgImage: $0, size: rect.size) }
    }
}

// MARK: - Scrolling capture

/// CleanShot-style scrolling capture: select a region over scrollable content;
/// the region is captured, scrolled programmatically, captured again, and the
/// frames are stitched into one tall image by matching overlapping rows.
enum ScrollingCapture {

    /// Ask the user for a region, then capture + stitch off the main thread.
    static func start(completion: @escaping (NSImage?) -> Void) {
        RegionSelector.shared.begin { cgRect in
            guard let rect = cgRect, rect.width > 40, rect.height > 60 else {
                completion(nil)
                return
            }
            Settings.shared.lastCaptureRect =
                "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
            Settings.shared.save()
            DispatchQueue.global(qos: .userInitiated).async {
                let img = run(rect: rect)
                DispatchQueue.main.async { completion(img) }
            }
        }
    }

    private static func run(rect: CGRect) -> NSImage? {
        guard let first = ScreenGrab.cgImage(rect) else { return nil }
        let scale = CGFloat(first.width) / rect.width          // retina factor
        let frameH = first.height
        let scrollPoints = Int(rect.height * 0.6)              // per-step scroll
        let expected = Int(CGFloat(scrollPoints) * scale)      // expected px shift
        let center = CGPoint(x: rect.midX, y: rect.midY)

        var frames: [CGImage] = [first]
        var offsets: [Int] = [0]                               // top of each frame in the composite
        var prevProfile = rowProfile(first)
        var total = frameH

        for _ in 0..<25 {
            scroll(at: center, byPixels: scrollPoints)
            usleep(500_000)   // let smooth-scrolling settle
            guard let cur = ScreenGrab.cgImage(rect),
                  let curProf = rowProfile(cur),
                  let prevProf = prevProfile else { break }

            // Identical frames → the content stopped scrolling (bottom reached).
            if meanRowDiff(prevProf, curProf, h: frameH, shift: 0) < 1.5 { break }

            // Find the true pixel shift between consecutive frames.
            guard let s = bestShift(prevProf, curProf, h: frameH,
                                    expected: expected, window: 140), s > 4 else { break }
            offsets.append(offsets.last! + s)
            frames.append(cur)
            total = offsets.last! + frameH
            prevProfile = curProf

            if total > 40_000 { break }   // sanity cap on composite height
        }

        guard frames.count > 1 else {
            Logger.log("Scrolling capture: content didn't scroll — single frame")
            return NSImage(cgImage: first, size: rect.size)
        }

        // Compose: draw each frame at its offset (top-left space → CG flip).
        let w = first.width
        guard let ctx = CGContext(data: nil, width: w, height: total,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(cgImage: first, size: rect.size) }

        for (i, img) in frames.enumerated() {
            let y = total - offsets[i] - img.height
            ctx.draw(img, in: CGRect(x: 0, y: CGFloat(y),
                                     width: CGFloat(w), height: CGFloat(img.height)))
        }
        guard let out = ctx.makeImage() else { return NSImage(cgImage: first, size: rect.size) }
        Logger.log("Scrolling capture: \(frames.count) frames → \(total)px tall")
        return NSImage(cgImage: out,
                       size: NSSize(width: CGFloat(w) / scale, height: CGFloat(total) / scale))
    }

    /// Posts pixel-precise scroll-wheel events at a screen point (CG coords).
    private static func scroll(at point: CGPoint, byPixels px: Int) {
        CGWarpMouseCursorPosition(point)
        usleep(60_000)
        var remaining = px
        while remaining > 0 {
            let d = min(50, remaining)
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 1, wheel1: Int32(-d), wheel2: 0, wheel3: 0) {
                e.location = point
                e.post(tap: .cghidEventTap)
            }
            remaining -= d
            usleep(10_000)
        }
    }

    // MARK: Frame matching

    private static let profileWidth = 100

    /// Downscales a frame to a 100-wide grayscale strip: one luminance row per
    /// pixel row, cheap to compare.
    private static func rowProfile(_ img: CGImage) -> [UInt8]? {
        let w = profileWidth, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let buf = data.assumingMemoryBound(to: UInt8.self)
        return [UInt8](UnsafeBufferPointer(start: buf, count: w * h))
    }

    /// Mean absolute row difference between A shifted down by `shift` and B.
    /// (After scrolling down by s, B's row r matches A's row r+s.)
    private static func meanRowDiff(_ a: [UInt8], _ b: [UInt8], h: Int, shift: Int) -> Double {
        let w = profileWidth
        let rows = h - shift
        guard rows > 20 else { return .greatestFiniteMagnitude }
        var totalDiff = 0
        var samples = 0
        var r = 0
        while r < rows {
            let aBase = (r + shift) * w
            let bBase = r * w
            var rowDiff = 0
            var x = 0
            while x < w {
                rowDiff += abs(Int(a[aBase + x]) - Int(b[bBase + x]))
                x += 2
            }
            totalDiff += rowDiff
            samples += w / 2
            r += 6
        }
        return samples > 0 ? Double(totalDiff) / Double(samples) : .greatestFiniteMagnitude
    }

    /// The pixel shift (within expected ± window) that best aligns two frames.
    private static func bestShift(_ a: [UInt8], _ b: [UInt8], h: Int,
                                  expected: Int, window: Int) -> Int? {
        var best: Int?
        var bestCost = Double.greatestFiniteMagnitude
        let lo = max(4, expected - window)
        let hi = min(h - 30, expected + window)
        guard lo < hi else { return nil }
        for s in stride(from: lo, through: hi, by: 2) {
            let c = meanRowDiff(a, b, h: h, shift: s)
            if c < bestCost { bestCost = c; best = s }
        }
        // A weak best match means the frames don't actually overlap (animation,
        // fixed headers, etc.) — better to stop than stitch garbage.
        return bestCost < 18 ? best : nil
    }
}

// MARK: - All-in-One capture menu

/// CleanShot's All-in-One mode: one shortcut shows a small chooser with every
/// capture type; pick one and it runs the matching task.
final class CaptureMenu: NSObject {
    static let shared = CaptureMenu()
    private var panel: NSPanel?
    private var handler: ((String) -> Void)?

    func show(handler: @escaping (String) -> Void) {
        dismiss()
        self.handler = handler

        let items: [(String, String)] = [
            ("Area", "screenshotAreaClip"),
            ("Window", "screenshotWindowClip"),
            ("Screen", "screenshotFullClip"),
            ("Scrolling", "scrollingCapture"),
            ("Previous", "screenshotPrevArea"),
            ("OCR", "ocrArea"),
        ]
        let btnW: CGFloat = 74, btnH: CGFloat = 24, pad: CGFloat = 10
        let w = pad * 2 + CGFloat(items.count) * (btnW + 4) + 26
        let h = btnH + pad * 2

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        root.layer?.cornerRadius = 10

        var x = pad
        for (title, id) in items {
            let b = NSButton(title: title, target: self, action: #selector(pick(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.identifier = NSUserInterfaceItemIdentifier(id)
            b.frame = NSRect(x: x, y: pad, width: btnW, height: btnH)
            root.addSubview(b)
            x += btnW + 4
        }
        let close = NSButton(title: "✕", target: self, action: #selector(closePressed))
        close.bezelStyle = .rounded
        close.controlSize = .small
        close.font = .systemFont(ofSize: 11)
        close.frame = NSRect(x: x, y: pad, width: 24, height: btnH)
        root.addSubview(close)

        panel.contentView = root

        // Centered on the screen with the mouse.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vis.midX - w / 2, y: vis.midY - h / 2))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    @objc private func pick(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? ""
        let h = handler
        dismiss()
        // Small delay so the chooser is gone before an interactive capture starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { h?(id) }
    }

    @objc private func closePressed() { dismiss() }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        handler = nil
    }
}
