import Cocoa

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
