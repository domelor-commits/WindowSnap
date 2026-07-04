import Cocoa

/// Draws all displays from a Layout to scale, with each saved window rendered
/// as a labeled rectangle inside the monitor it belongs to. Each window shows
/// app name, window title, and PID.
///
/// Coordinate handling: everything is converted into a single TOP-LEFT-origin
/// global space first (call it "doc space"), then a single affine map scales
/// doc space into the view. No per-element flipping — that double-flip was the
/// earlier bug that put windows in the wrong place.
final class LayoutCanvas: NSView {
    var layout: Layout? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }  // view origin top-left, matches doc space

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()

        guard let layout = layout, !layout.displays.isEmpty else {
            drawPlaceholder("Select a saved layout to preview it")
            return
        }

        // --- 1. Build doc space (top-left origin) for displays. ---
        // NSScreen frames are bottom-left origin. Convert each to top-left using
        // the global top edge (max maxY across all displays).
        let displayFrames = layout.displays.map { $0.frame.rect }
        let globalTop = displayFrames.map { $0.maxY }.max()!      // highest point
        let globalLeft = displayFrames.map { $0.minX }.min()!

        func displayToDoc(_ f: CGRect) -> CGRect {
            // top-left x stays; y measured down from globalTop
            CGRect(x: f.minX - globalLeft,
                   y: globalTop - f.maxY,
                   width: f.width, height: f.height)
        }

        // AX window frames are ALREADY top-left origin, but measured from the
        // primary display's top (y=0 at the menu-bar screen's top). The primary
        // display's top in global bottom-left coords is its own maxY. Convert an
        // AX point into the same doc space by aligning tops.
        let primaryFrame = layout.displays.first(where: { $0.isPrimary })?.frame.rect
            ?? displayFrames.first!
        // AX y=0 corresponds to the primary display's top edge. In doc space that
        // edge sits at (globalTop - primaryFrame.maxY).
        let axTopInDoc = globalTop - primaryFrame.maxY
        let axLeftInDoc = primaryFrame.minX - globalLeft

        func axToDoc(_ f: CGRect) -> CGRect {
            CGRect(x: axLeftInDoc + f.minX,
                   y: axTopInDoc + f.minY,
                   width: f.width, height: f.height)
        }

        // --- 2. Compute doc-space bounds and the doc->view transform. ---
        let docRects = displayFrames.map(displayToDoc)
        let docW = docRects.map { $0.maxX }.max()! - docRects.map { $0.minX }.min()!
        let docH = docRects.map { $0.maxY }.max()! - docRects.map { $0.minY }.min()!
        let docMinX = docRects.map { $0.minX }.min()!
        let docMinY = docRects.map { $0.minY }.min()!

        let inset: CGFloat = 24
        let avail = bounds.insetBy(dx: inset, dy: inset)
        guard docW > 0, docH > 0, avail.width > 0, avail.height > 0 else { return }
        let scale = min(avail.width / docW, avail.height / docH)
        let offsetX = avail.minX + (avail.width  - docW * scale) / 2
        let offsetY = avail.minY + (avail.height - docH * scale) / 2

        func toView(_ doc: CGRect) -> CGRect {
            CGRect(x: offsetX + (doc.minX - docMinX) * scale,
                   y: offsetY + (doc.minY - docMinY) * scale,
                   width: doc.width * scale,
                   height: doc.height * scale)
        }

        // --- 3. Draw monitors. ---
        // Distinct tint per monitor so they're easy to tell apart.
        let monitorTints: [NSColor] = [
            NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.34, alpha: 1),  // blue-grey
            NSColor(calibratedRed: 0.16, green: 0.30, blue: 0.22, alpha: 1),  // green-grey
            NSColor(calibratedRed: 0.32, green: 0.24, blue: 0.16, alpha: 1),  // amber-grey
            NSColor(calibratedRed: 0.28, green: 0.18, blue: 0.30, alpha: 1),  // purple-grey
            NSColor(calibratedRed: 0.16, green: 0.28, blue: 0.30, alpha: 1),  // teal-grey
        ]
        let borderTints: [NSColor] = [
            .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemTeal
        ]

        for (i, d) in layout.displays.enumerated() {
            // Larger inset for a clearer gap between adjacent monitors.
            let r = toView(displayToDoc(d.frame.rect)).insetBy(dx: 9, dy: 9)
            let bg = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
            monitorTints[i % monitorTints.count].setFill(); bg.fill()
            borderTints[i % borderTints.count].setStroke()
            bg.lineWidth = 2.5; bg.stroke()

            // Numbered badge in the top-left corner.
            let badgeSize: CGFloat = 20
            let badgeRect = NSRect(x: r.minX + 7, y: r.minY + 7, width: badgeSize, height: badgeSize)
            let badge = NSBezierPath(ovalIn: badgeRect)
            borderTints[i % borderTints.count].setFill(); badge.fill()
            let numStyle = NSMutableParagraphStyle(); numStyle.alignment = .center
            ("\(i + 1)" as NSString).draw(
                in: badgeRect.insetBy(dx: 0, dy: 2.5),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 13),
                                 .foregroundColor: NSColor.white,
                                 .paragraphStyle: numStyle])

            let dims = "\(Int(d.frame.width))×\(Int(d.frame.height))"
            let label = d.isPrimary ? "\(d.name) · \(dims) · primary" : "\(d.name) · \(dims)"
            // Bottom-left of the monitor (view is flipped, so larger y is lower).
            drawText(label, in: CGRect(x: r.minX + 8, y: r.maxY - 20, width: r.width - 16, height: 16),
                     size: 11, color: .white, bold: true)
        }

        // --- 4. Draw windows. ---
        let palette: [NSColor] = [
            .systemBlue, .systemGreen, .systemOrange, .systemPurple,
            .systemTeal, .systemPink, .systemIndigo, .systemBrown
        ]
        var colorForApp: [String: NSColor] = [:]
        var nextColor = 0

        // Combined desktop bounds in AX (top-left) space, to drop any stale
        // saved Finder desktop window that spans every monitor.
        let combinedBounds: CGRect = {
            let allFrames = layout.displays.map { $0.frame.rect }
            let minX = allFrames.map { $0.minX }.min() ?? 0
            let maxX = allFrames.map { $0.maxX }.max() ?? 0
            let totalW = maxX - minX
            let totalH = (allFrames.map { $0.maxY }.max() ?? 0) - (allFrames.map { $0.minY }.min() ?? 0)
            return CGRect(x: 0, y: 0, width: totalW, height: totalH)
        }()

        for win in layout.windows {
            // Skip a Finder window that spans (about) the whole desktop — that's
            // the desktop window, not a real window. Covers layouts saved before
            // capture-time filtering existed.
            if win.appBundleID == "com.apple.finder" {
                let f = win.frame.rect
                let tol: CGFloat = 8
                if abs(f.width - combinedBounds.width) <= tol &&
                   abs(f.height - combinedBounds.height) <= tol {
                    continue
                }
                if win.windowTitle.isEmpty { continue }
            }
            let r = toView(axToDoc(win.frame.rect)).insetBy(dx: 1.5, dy: 1.5)
            guard r.width > 6, r.height > 6 else { continue }

            let color = colorForApp[win.appBundleID] ?? {
                let c = palette[nextColor % palette.count]; nextColor += 1
                colorForApp[win.appBundleID] = c; return c
            }()

            let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            color.withAlphaComponent(0.22).setFill(); path.fill()
            color.setStroke(); path.lineWidth = 1; path.stroke()

            if r.height > 28 {
                drawText(win.appName,
                         in: CGRect(x: r.minX + 5, y: r.minY + 4, width: r.width - 10, height: 14),
                         size: 11, color: .labelColor, bold: true)
                let sub = "PID \(win.pid)" + (win.windowTitle.isEmpty ? "" : " · \(win.windowTitle)")
                drawText(sub,
                         in: CGRect(x: r.minX + 5, y: r.minY + 18, width: r.width - 10, height: 12),
                         size: 9, color: .secondaryLabelColor, bold: false)
            } else if r.height > 14 {
                drawText("\(win.appName) · PID \(win.pid)",
                         in: CGRect(x: r.minX + 5, y: r.minY + 2, width: r.width - 10, height: 12),
                         size: 9, color: .labelColor, bold: false)
            }
        }
    }

    private func drawText(_ s: String, in rect: CGRect, size: CGFloat, color: NSColor, bold: Bool) {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
            .foregroundColor: color, .paragraphStyle: p
        ]
        (s as NSString).draw(in: rect, withAttributes: attrs)
    }

    private func drawPlaceholder(_ s: String) {
        drawText(s, in: bounds.insetBy(dx: 20, dy: bounds.height/2 - 10),
                 size: 13, color: .tertiaryLabelColor, bold: false)
    }
}
