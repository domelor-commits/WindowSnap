import Cocoa

/// One item stashed on the shelf. `url` is what gets dragged out (a real file, or
/// a temp file we wrote for dropped images/text).
final class ShelfItem {
    let url: URL
    let thumbnail: NSImage
    let title: String
    let isTemp: Bool
    init(url: URL, thumbnail: NSImage, title: String, isTemp: Bool) {
        self.url = url; self.thumbnail = thumbnail; self.title = title; self.isTemp = isTemp
    }
}

/// Shared shelf contents, so the floating shelf panel and the in-window Shelf tab
/// show and edit the same items. Session-only.
final class ShelfStore {
    static let shared = ShelfStore()
    private(set) var items: [ShelfItem] = []

    func addFile(_ u: URL) {
        items.append(ShelfItem(url: u, thumbnail: NSWorkspace.shared.icon(forFile: u.path),
                               title: u.lastPathComponent, isTemp: false))
        changed()
    }
    func addImage(_ img: NSImage) {
        let url = Self.tempURL(ext: "png")
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        items.append(ShelfItem(url: url, thumbnail: img, title: "Image", isTemp: true))
        changed()
    }
    func addText(_ s: String) {
        let url = Self.tempURL(ext: "txt")
        try? s.data(using: .utf8)?.write(to: url)
        let glyph = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) ?? NSImage()
        items.append(ShelfItem(url: url, thumbnail: glyph, title: "Text", isTemp: true))
        changed()
    }
    func remove(_ item: ShelfItem) {
        items.removeAll { $0 === item }
        if item.isTemp { try? FileManager.default.removeItem(at: item.url) }
        changed()
    }
    func clearAll() {
        items.forEach { if $0.isTemp { try? FileManager.default.removeItem(at: $0.url) } }
        items.removeAll()
        changed()
    }

    private func changed() { NotificationCenter.default.post(name: .windowSnapShelfChanged, object: nil) }

    private static func tempURL(ext: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WindowSnapShelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }
}

/// Dropover/Yoink-style floating shelf window. The content is a `ShelfDropView`,
/// which is also embedded in the Shelf tab — both reflect `ShelfStore.shared`.
final class ShelfController: NSObject, NSWindowDelegate {
    static let shared = ShelfController()
    private var panel: NSPanel?

    func toggle() {
        if let p = panel { p.close(); return }
        let w: CGFloat = 420, h: CGFloat = 150
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        p.title = "Shelf"
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        let view = ShelfDropView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        view.autoresizingMask = [.width, .height]
        p.contentView = view

        let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: w, height: h)
        p.setFrameOrigin(NSPoint(x: vis.midX - w / 2, y: vis.maxY - h - 40))
        panel = p
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { panel = nil }
}

/// A drop destination that lays out `ShelfStore.shared` items in a row and lets
/// each be dragged back out. Used by both the floating panel and the Shelf tab.
final class ShelfDropView: NSView {
    private let stack = NSStackView()
    private let hint = NSTextField(labelWithString: "Drag files, images, or text here")
    private let countLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL, .png, .tiff, .string])

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearAll))
        clear.bezelStyle = .rounded; clear.controlSize = .small
        clear.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .systemFont(ofSize: 11); countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal; stack.spacing = 8; stack.alignment = .top
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.hasHorizontalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = NSView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack); scroll.documentView = doc

        hint.font = .systemFont(ofSize: 12); hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        addSubview(countLabel); addSubview(clear); addSubview(scroll); addSubview(hint)
        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            countLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            clear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            clear.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: doc.heightAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.heightAnchor),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild),
                                               name: .windowSnapShelfChanged, object: nil)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        layer?.borderColor = NSColor.controlAccentColor.cgColor; layer?.borderWidth = 2; return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { layer?.borderWidth = 0 }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            urls.forEach { ShelfStore.shared.addFile($0) }; return true
        } else if let img = NSImage(pasteboard: pb) {
            ShelfStore.shared.addImage(img); return true
        } else if let s = pb.string(forType: .string), !s.isEmpty {
            ShelfStore.shared.addText(s); return true
        }
        return false
    }

    @objc private func clearAll() { ShelfStore.shared.clearAll() }

    @objc private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items = ShelfStore.shared.items
        for item in items { stack.addArrangedSubview(ShelfItemView(item: item)) }
        hint.isHidden = !items.isEmpty
        countLabel.stringValue = items.isEmpty ? "" : "\(items.count) item\(items.count == 1 ? "" : "s")"
    }
}

/// A single shelf tile: shows a thumbnail, drags the underlying file out, and has
/// a small remove button.
final class ShelfItemView: NSView, NSDraggingSource {
    private let item: ShelfItem

    init(item: ShelfItem) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: 64, height: 82))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 64).isActive = true
        heightAnchor.constraint(equalToConstant: 82).isActive = true
        toolTip = item.title

        let iv = NSImageView(); iv.image = item.thumbnail; iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: item.title)
        label.font = .systemFont(ofSize: 9); label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle; label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        let close = NSButton(title: "✕", target: self, action: #selector(removeSelf))
        close.isBordered = false; close.font = .systemFont(ofSize: 10)
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iv); addSubview(label); addSubview(close)
        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            iv.centerXAnchor.constraint(equalTo: centerXAnchor),
            iv.widthAnchor.constraint(equalToConstant: 52), iv.heightAnchor.constraint(equalToConstant: 52),
            label.topAnchor.constraint(equalTo: iv.bottomAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            close.topAnchor.constraint(equalTo: topAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func removeSelf() { ShelfStore.shared.remove(item) }

    override func mouseDragged(with event: NSEvent) {
        let di = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        di.setDraggingFrame(bounds, contents: item.thumbnail)
        beginDraggingSession(with: [di], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
