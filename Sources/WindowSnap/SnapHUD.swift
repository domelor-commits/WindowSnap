import Cocoa

/// A brief translucent flash over the region a window was just snapped to, giving
/// keyboard snaps the same visual confirmation that drag-to-snap gets from its
/// live preview. Fades in, holds briefly, fades out.
final class SnapHUD {
    static let shared = SnapHUD()

    private var hideWork: DispatchWorkItem?
    private lazy var panel: NSPanel = Self.makePanel()

    /// Flash the snap target for `region` on `screen`. Call on the main thread.
    func flash(region: SnapRegion, on screen: NSScreen) {
        let v = screen.visibleFrame
        let r = region.frame(in: CGRect(x: 0, y: 0, width: v.width, height: v.height))
        // region.frame is top-left origin; convert to global bottom-left (AppKit).
        let frame = NSRect(x: v.minX + r.origin.x,
                           y: v.minY + (v.height - r.origin.y - r.height),
                           width: r.width, height: r.height)

        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            panel.animator().alphaValue = 1
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                self.panel.animator().alphaValue = 0
            }, completionHandler: { self.panel.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 8
        p.contentView = view
        return p
    }
}
