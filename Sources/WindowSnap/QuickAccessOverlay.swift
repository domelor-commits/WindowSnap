import Cocoa

// MARK: - Quick Access Overlay

/// CleanShot-style Quick Access Overlay: after every capture a small floating
/// thumbnail appears in the bottom-left corner of the screen. Click it (or the
/// Annotate button) to open the editor, drag it straight into another app to
/// drop the PNG there, Copy / Save / Pin it, or dismiss with ✕.
final class QuickAccessOverlay: NSObject {
    /// Every currently-visible overlay, so multiple captures can stack.
    private static var active: [QuickAccessOverlay] = []

    private var panel: NSPanel?
    private var image: NSImage?
    private var filePath: String?
    private var onAnnotate: (() -> Void)?
    private var tempURL: URL?
    private var autoCloseTimer: Timer?
    private var cornerButtons: [NSButton] = []

    /// Present a new overlay for a fresh capture, stacked above any existing
    /// ones. `filePath` is nil for clipboard-only (memory buffer) captures.
    static func present(image: NSImage, filePath: String?, onAnnotate: @escaping () -> Void) {
        let o = QuickAccessOverlay()
        let stackIndex = active.count
        active.append(o)
        o.build(image: image, filePath: filePath, onAnnotate: onAnnotate, stackIndex: stackIndex)
    }

    private func build(image: NSImage, filePath: String?,
                       onAnnotate: @escaping () -> Void, stackIndex: Int) {
        self.image = image
        self.filePath = filePath
        self.onAnnotate = onAnnotate
        self.tempURL = nil

        // Card sized to the thumbnail (the corner icons overlay its corners).
        let maxW: CGFloat = 260, maxH: CGFloat = 170
        let isz = image.size
        let sc = min(maxW / max(isz.width, 1), maxH / max(isz.height, 1), 1)
        let tw = max(120, isz.width * sc), th = max(80, isz.height * sc)

        let pad: CGFloat = 6
        let w = tw + pad * 2
        let h = th + pad * 2

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false

        let root = HoverTrackingView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        root.layer?.cornerRadius = 10

        let thumb = DraggableShotView(frame: NSRect(x: pad, y: pad, width: tw, height: th))
        thumb.image = image
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.masksToBounds = true
        thumb.fileURLProvider = { [weak self] in self?.dragURL() }
        thumb.onClick = { [weak self] in self?.annotateNow() }
        thumb.toolTip = "Click to annotate · drag into another app"
        root.addSubview(thumb)

        // Four corner icon buttons (bigger, white circular background so they're
        // clearly visible over any screenshot), hidden until hover.
        let bs: CGFloat = 36, inset: CGFloat = 6
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        func cornerButton(_ symbol: String, _ action: Selector, tip: String, at origin: CGPoint) {
            let b = NSButton(frame: NSRect(x: origin.x, y: origin.y, width: bs, height: bs))
            b.bezelStyle = .circular
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = NSColor.white.cgColor
            b.layer?.cornerRadius = bs / 2
            b.layer?.shadowColor = NSColor.black.cgColor
            b.layer?.shadowOpacity = 0.4
            b.layer?.shadowRadius = 3
            b.layer?.shadowOffset = CGSize(width: 0, height: -1)
            b.contentTintColor = .black
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(cfg)
            b.imageScaling = .scaleProportionallyDown
            b.target = self; b.action = action
            b.toolTip = tip
            b.isHidden = true
            root.addSubview(b)
            cornerButtons.append(b)
        }
        // Match the reference: pin ↖, close ↗, annotate ↙, save ↘.
        cornerButton("pin.fill", #selector(pinBtn), tip: "Pin on screen",
                     at: CGPoint(x: inset, y: h - bs - inset))
        cornerButton("xmark", #selector(closeBtn), tip: "Dismiss",
                     at: CGPoint(x: w - bs - inset, y: h - bs - inset))
        cornerButton("pencil.tip.crop.circle", #selector(annotateBtn), tip: "Annotate",
                     at: CGPoint(x: inset, y: inset))
        cornerButton("square.and.arrow.down", #selector(saveBtn),
                     tip: filePath == nil ? "Save…" : "Reveal in Finder",
                     at: CGPoint(x: w - bs - inset, y: inset))

        // Hovering pauses auto-close and reveals the corner icons.
        root.onHoverChanged = { [weak self] hovering in
            guard let self = self else { return }
            self.cornerButtons.forEach { $0.isHidden = !hovering }
            if hovering { self.autoCloseTimer?.invalidate() }
            else { self.restartAutoClose() }
        }

        panel.contentView = root

        // Bottom-left of the main screen, stacking upward for each extra popup.
        let vis = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let y = vis.minY + 16 + CGFloat(stackIndex) * (h + 8)
        panel.setFrameOrigin(NSPoint(x: vis.minX + 16, y: y))
        panel.orderFrontRegardless()
        self.panel = panel
        restartAutoClose()
    }

    /// (Re)arm the configurable inactivity auto-close.
    private func restartAutoClose() {
        autoCloseTimer?.invalidate()
        guard panel != nil else { return }
        let secs = TimeInterval(max(1, Settings.shared.overlayAutoCloseSeconds))
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        panel?.orderOut(nil)
        panel = nil
        QuickAccessOverlay.active.removeAll { $0 === self }
    }

    /// URL used for drag-out: the real file when one exists, otherwise a temp
    /// PNG written once from the in-memory capture.
    private func dragURL() -> URL? {
        if let p = filePath { return URL(fileURLWithPath: p) }
        if let t = tempURL { return t }
        guard let image = image, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Screenshot \(fmt.string(from: Date())).png")
        try? png.write(to: url)
        tempURL = url
        return url
    }

    private func annotateNow() {
        let action = onAnnotate
        dismiss()
        action?()
    }

    @objc private func annotateBtn() { annotateNow() }

    @objc private func saveBtn() {
        if let p = filePath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
            return
        }
        guard let image = image else { return }
        let save = NSSavePanel()
        save.allowedContentTypes = [.png]
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        save.nameFieldStringValue = "Screenshot \(fmt.string(from: Date())).png"
        save.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        NSApp.activate()
        if save.runModal() == .OK, let url = save.url,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            Logger.log("Overlay: saved \(url.lastPathComponent)")
            dismiss()
        }
    }

    @objc private func pinBtn() {
        if let image = image { PinnedImageWindow.pin(image) }
        dismiss()
    }

    @objc private func closeBtn() { dismiss() }
}

// MARK: - Hover tracking

/// Container that reports pointer enter/exit so the overlay can pause its
/// auto-close countdown while the user is interacting with it.
final class HoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}

// MARK: - Draggable thumbnail

/// Thumbnail that opens the annotator on click and supports dragging the
/// capture (as a PNG file) into other apps.
final class DraggableShotView: NSImageView, NSDraggingSource {
    var onClick: (() -> Void)?
    var fileURLProvider: (() -> URL?)?
    private var downPoint: NSPoint = .zero
    private var didDrag = false

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag else { return }
        let p = event.locationInWindow
        guard hypot(p.x - downPoint.x, p.y - downPoint.y) > 5,
              let url = fileURLProvider?() else { return }
        didDrag = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { onClick?() }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

// MARK: - Pinned image window

/// CleanShot's "Pin" — keeps a capture floating above all windows until closed.
/// Drag anywhere to move; resize from the edges (aspect ratio is kept).
final class PinnedImageWindow: NSObject {
    private static var pins: [PinnedImageWindow] = []
    private let panel: NSPanel

    static func pin(_ image: NSImage) {
        pins.append(PinnedImageWindow(image: image))
        Logger.log("Pinned screenshot to screen")
    }

    private init(image: NSImage) {
        // Open at the screenshot's own (normal) size, shrinking only if it would
        // be larger than the screen it appears on.
        let isz = image.size
        let vis = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let fit = min(1, min((vis.width - 40) / max(isz.width, 1),
                             (vis.height - 40) / max(isz.height, 1)))
        let w = max(80, isz.width * fit), h = max(60, isz.height * fit)

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel, .resizable],
                        backing: .buffered, defer: false)
        super.init()

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.aspectRatio = NSSize(width: max(isz.width, 1), height: max(isz.height, 1))
        panel.minSize = NSSize(width: 120, height: 80)

        let root = WindowDragView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        root.layer?.cornerRadius = 8
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.25).cgColor

        let iv = WindowDragImageView(frame: root.bounds)
        iv.autoresizingMask = [.width, .height]
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        root.addSubview(iv)

        let close = NSButton(title: "✕", target: self, action: #selector(closePressed))
        close.bezelStyle = .circular
        close.controlSize = .small
        close.font = .systemFont(ofSize: 10)
        close.frame = NSRect(x: w - 26, y: h - 26, width: 20, height: 20)
        close.autoresizingMask = [.minXMargin, .minYMargin]
        close.toolTip = "Close pinned screenshot"
        root.addSubview(close)

        panel.contentView = root

        // Center of the main screen, slightly offset per pin so stacks fan out.
        let offset = CGFloat(Self.pins.count % 5) * 24
        panel.setFrameOrigin(NSPoint(x: vis.midX - w / 2 + offset,
                                     y: vis.midY - h / 2 - offset))
        panel.orderFrontRegardless()
    }

    @objc private func closePressed() {
        panel.orderOut(nil)
        Self.pins.removeAll { $0 === self }
    }
}

/// Views that let a click-drag anywhere move the borderless pinned window.
/// (NSImageView normally swallows mouse-downs, blocking window dragging.)
private final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

private final class WindowDragImageView: NSImageView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
