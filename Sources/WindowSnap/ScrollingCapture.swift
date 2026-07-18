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

// MARK: - Screen grabbing

enum ScreenGrab {
    /// Captures a global-CG-coordinate rect of the screen at full resolution.
    ///
    /// Deliberately still `CGWindowListCreateImage` (deprecated macOS 14): the
    /// scrolling-capture stitch loop compares consecutive grabs synchronously
    /// while the user scrolls, and ScreenCaptureKit's screenshot API is
    /// async-only — bridging it in here would add latency/jank to that loop.
    /// This is the ONE remaining call site; new code should use ScreenCaptureKit
    /// (see WindowSwitcher.loadThumbnails for the pattern).
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

    /// Ask the user for a region, then hand off to the interactive session
    /// (CleanShot-style): a floating control bar with Start / Done / Cancel and
    /// an auto-scroll toggle. Nothing scrolls or captures until Start is pressed.
    static func start(completion: @escaping (NSImage?) -> Void) {
        RegionSelector.shared.begin { cgRect in
            guard let rect = cgRect, rect.width > 40, rect.height > 60 else {
                completion(nil)
                return
            }
            Settings.shared.lastCaptureRect =
                "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
            Settings.shared.save()
            DispatchQueue.main.async {
                ScrollingCaptureSession.shared.begin(rect: rect, completion: completion)
            }
        }
    }

    /// Posts pixel-precise scroll-wheel events at a screen point (CG coords).
    fileprivate static func scroll(at point: CGPoint, byPixels px: Int) {
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

    fileprivate static let profileWidth = 100

    /// Downscales a frame to a 100-wide grayscale strip: one luminance row per
    /// pixel row, cheap to compare.
    fileprivate static func rowProfile(_ img: CGImage) -> [UInt8]? {
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
    fileprivate static func meanRowDiff(_ a: [UInt8], _ b: [UInt8], h: Int, shift: Int) -> Double {
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
    fileprivate static func bestShift(_ a: [UInt8], _ b: [UInt8], h: Int,
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

// MARK: - Interactive scrolling-capture session

/// Drives one scrolling capture with a CleanShot-style floating control bar:
/// select a region, press Start, then either let auto-scroll walk the content
/// or scroll it yourself at any pace — frames are stitched live either way,
/// with a running height readout. Press Done to deliver (or it finishes itself
/// when auto-scroll hits the bottom). Cancel discards.
final class ScrollingCaptureSession {
    static let shared = ScrollingCaptureSession()

    private var panel: NSPanel?
    private var statusLabel: NSTextField!
    private var startButton: NSButton!
    private var doneButton: NSButton!
    private var autoCheckbox: NSButton!

    private var rect: CGRect = .zero
    private var completion: ((NSImage?) -> Void)?

    // Capture state — touched only on `queue` once the timer is running.
    private let queue = DispatchQueue(label: "windowsnap.scrollcapture", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var frames: [CGImage] = []
    private var offsets: [Int] = []          // top of each frame in the composite (px)
    private var prevProfile: [UInt8]?
    private var frameH = 0
    private var stillCount = 0               // consecutive no-movement ticks (auto mode)
    private var autoScroll = true            // mirrored from the checkbox

    func begin(rect: CGRect, completion: @escaping (NSImage?) -> Void) {
        guard panel == nil else { completion(nil); return }
        self.rect = rect
        self.completion = completion
        queue.async { [weak self] in self?.resetOnQueue() }
        buildPanel()
    }

    // MARK: Control bar

    private func buildPanel() {
        let w: CGFloat = 400, h: CGFloat = 66, pad: CGFloat = 10

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none      // never appears in the captured frames

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        root.layer?.cornerRadius = 10

        statusLabel = NSTextField(labelWithString:
            "Position the content, then Start. Scroll yourself or let auto-scroll run.")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .white
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: pad, y: h - 26, width: w - pad * 2, height: 16)
        root.addSubview(statusLabel)

        startButton = NSButton(title: "Start", target: self, action: #selector(startPressed))
        doneButton = NSButton(title: "Done", target: self, action: #selector(donePressed))
        doneButton.isEnabled = false
        let cancelButton = NSButton(title: "✕", target: self, action: #selector(cancelPressed))
        for b in [startButton!, doneButton!, cancelButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
        }
        autoCheckbox = NSButton(checkboxWithTitle: "Auto-scroll", target: self,
                                action: #selector(autoToggled(_:)))
        autoCheckbox.state = .on
        autoCheckbox.controlSize = .small
        autoCheckbox.attributedTitle = NSAttributedString(string: "Auto-scroll", attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11)])

        startButton.frame = NSRect(x: pad, y: pad, width: 66, height: 24)
        doneButton.frame = NSRect(x: pad + 70, y: pad, width: 66, height: 24)
        autoCheckbox.frame = NSRect(x: pad + 146, y: pad + 3, width: 110, height: 18)
        cancelButton.frame = NSRect(x: w - pad - 28, y: pad, width: 28, height: 24)
        root.addSubview(startButton)
        root.addSubview(doneButton)
        root.addSubview(autoCheckbox)
        root.addSubview(cancelButton)
        panel.contentView = root

        // Place the bar just below the selected region (above it if no room),
        // clamped to the screen holding the region. sharingType .none keeps it
        // out of the capture even when it must overlap the region.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let nsRegion = NSRect(x: rect.minX, y: primaryTop - rect.maxY,
                              width: rect.width, height: rect.height)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(nsRegion) }) ?? NSScreen.main
        let vis = screen?.visibleFrame ?? nsRegion
        var px = nsRegion.midX - w / 2
        px = max(vis.minX + 8, min(px, vis.maxX - w - 8))
        var py = nsRegion.minY - h - 12
        if py < vis.minY + 8 { py = nsRegion.minY + 12 }
        panel.setFrameOrigin(NSPoint(x: px, y: py))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    @objc private func startPressed() {
        startButton.isEnabled = false
        doneButton.isEnabled = true
        statusLabel.stringValue = "Capturing… 0 px"
        Logger.log("Scrolling capture: started (\(Int(rect.width))×\(Int(rect.height)))")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(350))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    @objc private func donePressed() { finish(cancelled: false) }
    @objc private func cancelPressed() { finish(cancelled: true) }

    @objc private func autoToggled(_ sender: NSButton) {
        let on = sender.state == .on
        queue.async { [weak self] in self?.autoScroll = on }
    }

    // MARK: Capture loop (runs on `queue`)

    private func tick() {
        // First frame anchors the composite; no scrolling before it.
        if frames.isEmpty {
            guard let first = ScreenGrab.cgImage(rect),
                  let prof = ScrollingCapture.rowProfile(first) else { return }
            frames = [first]; offsets = [0]; prevProfile = prof; frameH = first.height
            return
        }

        if autoScroll {
            ScrollingCapture.scroll(at: CGPoint(x: rect.midX, y: rect.midY),
                                    byPixels: Int(rect.height * 0.55))
            usleep(420_000)   // let smooth scrolling settle before grabbing
        }

        guard let cur = ScreenGrab.cgImage(rect),
              let prof = ScrollingCapture.rowProfile(cur),
              let prev = prevProfile else { return }

        // Unchanged frame: content didn't move since the last tick. In auto
        // mode, several in a row after a scroll attempt means the bottom was
        // reached — finish on the user's behalf like CleanShot does.
        if ScrollingCapture.meanRowDiff(prev, prof, h: frameH, shift: 0) < 1.5 {
            if autoScroll {
                stillCount += 1
                if stillCount >= 3 {
                    DispatchQueue.main.async { self.finish(cancelled: false) }
                }
            }
            return
        }
        stillCount = 0

        // Find how far the content moved and stitch. The full plausible shift
        // range is searched so manual scrolling at any speed still aligns.
        guard let s = ScrollingCapture.bestShift(prev, prof, h: frameH,
                                                 expected: frameH / 2, window: frameH / 2),
              s > 4 else { return }
        offsets.append(offsets.last! + s)
        frames.append(cur)
        prevProfile = prof

        let totalPx = offsets.last! + frameH
        if totalPx > 40_000 {   // sanity cap on composite height
            DispatchQueue.main.async { self.finish(cancelled: false) }
            return
        }
        let scale = CGFloat(frames[0].width) / rect.width
        let pts = Int(CGFloat(totalPx) / scale)
        let count = frames.count
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.stringValue = "Capturing… \(pts) px · \(count) frames"
        }
    }

    // MARK: Finish

    private func finish(cancelled: Bool) {
        guard panel != nil else { return }   // ignore double-finish
        timer?.cancel(); timer = nil
        panel?.orderOut(nil); panel = nil
        let done = completion; completion = nil

        if cancelled {
            queue.async { [weak self] in self?.resetOnQueue() }
            Logger.log("Scrolling capture: cancelled")
            done?(nil)
            return
        }
        // Compose on the capture queue: it runs after any in-flight tick, so
        // the frame list is complete and no longer mutating.
        queue.async { [weak self] in
            guard let self = self else { return }
            let img = self.compose()
            self.resetOnQueue()
            DispatchQueue.main.async { done?(img) }
        }
    }

    private func compose() -> NSImage? {
        guard let first = frames.first else { return nil }
        guard frames.count > 1, let lastOffset = offsets.last else {
            Logger.log("Scrolling capture: content didn't scroll — single frame")
            return NSImage(cgImage: first, size: rect.size)
        }
        let w = first.width
        let total = lastOffset + frameH
        guard let ctx = CGContext(data: nil, width: w, height: total,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(cgImage: first, size: rect.size) }

        // Draw each frame at its offset (top-left space → CG flip).
        for (i, img) in frames.enumerated() {
            let y = total - offsets[i] - img.height
            ctx.draw(img, in: CGRect(x: 0, y: CGFloat(y),
                                     width: CGFloat(w), height: CGFloat(img.height)))
        }
        guard let out = ctx.makeImage() else { return NSImage(cgImage: first, size: rect.size) }
        let scale = CGFloat(w) / rect.width
        Logger.log("Scrolling capture: \(frames.count) frames → \(total)px tall")
        return NSImage(cgImage: out, size: NSSize(width: CGFloat(w) / scale,
                                                  height: CGFloat(total) / scale))
    }

    private func resetOnQueue() {
        frames = []; offsets = []; prevProfile = nil
        frameH = 0; stillCount = 0; autoScroll = true
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
