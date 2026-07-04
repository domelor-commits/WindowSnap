#!/usr/bin/swift
// Renders WindowSnap's app icon to PNG files at all required sizes using only
// AppKit — no librsvg or other external dependencies. Writes to a .iconset
// directory passed as the first argument. macOS's `iconutil` then turns that
// into Icon.icns (handled by make-icon.sh).
import AppKit

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "WindowSnap.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = size
    // Scale helper: design is defined on a 1024 grid.
    func u(_ v: CGFloat) -> CGFloat { v / 1024 * s }

    // Background rounded square with blue vertical gradient.
    let bgRect = NSRect(x: u(112), y: u(112), width: u(800), height: u(800))
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: u(180), yRadius: u(180))
    let grad = NSGradient(starting: NSColor(red: 0.231, green: 0.510, blue: 0.965, alpha: 1),
                          ending:   NSColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 1))
    grad?.draw(in: bg, angle: -90)
    bg.addClip()

    // Window container (faint).
    let container = NSBezierPath(roundedRect: NSRect(x: u(216), y: u(248), width: u(592), height: u(528)),
                                 xRadius: u(48), yRadius: u(48))
    NSColor(white: 1, alpha: 0.16).setFill(); container.fill()

    // Snapped left pane (solid white). Note: AppKit is bottom-left origin, so a
    // pane drawn from y=248 upward to 776 fills the left half vertically.
    let leftPane = NSBezierPath(roundedRect: NSRect(x: u(216), y: u(248), width: u(280), height: u(528)),
                                xRadius: u(40), yRadius: u(40))
    NSColor.white.setFill(); leftPane.fill()

    // Title bar accent near the top of the left pane.
    let titleBar = NSBezierPath(roundedRect: NSRect(x: u(262), y: u(700), width: u(188), height: u(34)),
                                xRadius: u(17), yRadius: u(17))
    NSColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 0.85).setFill(); titleBar.fill()

    // Ghosted content lines on the right (top to bottom).
    let lines: [(CGFloat, CGFloat, CGFloat)] = [ (540,700,210), (540,620,210), (540,540,150) ]
    for (i, l) in lines.enumerated() {
        let line = NSBezierPath(roundedRect: NSRect(x: u(l.0), y: u(l.1), width: u(l.2), height: u(34)),
                                xRadius: u(17), yRadius: u(17))
        NSColor(white: 1, alpha: i == 0 ? 0.55 : 0.40).setFill(); line.fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ size: Int, _ name: String) {
    let rep = drawIcon(size: CGFloat(size))
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}

// Standard iconset sizes (1x and 2x).
write(16,   "icon_16x16.png")
write(32,   "icon_16x16@2x.png")
write(32,   "icon_32x32.png")
write(64,   "icon_32x32@2x.png")
write(128,  "icon_128x128.png")
write(256,  "icon_128x128@2x.png")
write(256,  "icon_256x256.png")
write(512,  "icon_256x256@2x.png")
write(512,  "icon_512x512.png")
write(1024, "icon_512x512@2x.png")
print("Rendered icon PNGs into \(outDir)")
