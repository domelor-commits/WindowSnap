import Cocoa
import Vision

// MARK: - Canvas

/// Shows the screenshot at its native size inside a scroll view and lets the
/// user draw, select, move, resize, and crop. The base screenshot is itself the
/// first (selectable, resizable) element, so it can be scaled and repositioned
/// like any dropped-in image.
final class AnnotationCanvas: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var tool: AnnoTool = .arrow { didSet { commitTextEditor() } }
    /// When on, clicks select / move / resize elements (including the base
    /// screenshot) instead of drawing.
    var selectMode = false
    var color: NSColor = .systemRed
    var strokeWidth: CGFloat = 3
    var defaultFontName: String = ""
    var cropMode = false { didSet { needsDisplay = true } }
    /// When on, drag a rectangle to recognize (OCR) the text under it.
    var ocrMode = false { didSet { needsDisplay = true } }
    var onChanged: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onCanvasResized: (() -> Void)?
    /// Called with recognized text (empty if none found) after an OCR drag.
    var onOCR: ((String) -> Void)?

    private(set) var shapes: [AnnoShape] = []      // shapes[0] is the base image
    private var draft: AnnoShape?
    private var baseImage: NSImage?
    private var canvasSize: CGSize = .zero         // in base pixels
    private var displayScale: CGFloat = 1          // points per pixel (retina < 1)
    private var textEditor: NSTextField?
    private var pendingTextPoint: CGPoint = .zero
    private var editingIndex: Int?

    private(set) var selectedIndex: Int? {
        didSet { needsDisplay = true; onSelectionChanged?() }
    }
    private enum DragMode {
        case none, draw, move, resize(Int), crop(Int), ocr
        var isCrop: Bool { if case .crop = self { return true }; return false }
        var isOCR: Bool { if case .ocr = self { return true }; return false }
    }
    private var dragMode: DragMode = .none
    private var dragStart: CGPoint = .zero
    private var origShape: AnnoShape?
    private var liveCrop: CGRect = .zero
    private var liveOCR: CGRect = .zero

    var selectedShape: AnnoShape? {
        selectedIndex.flatMap { shapes.indices.contains($0) ? shapes[$0] : nil }
    }

    /// Number of user annotations (excludes the base image).
    var annotationCount: Int { max(0, shapes.count - (baseImage != nil ? 1 : 0)) }

    // MARK: Image / canvas

    var image: NSImage? {
        get { baseImage }
        set {
            commitTextEditor(discard: true)
            undoStack = []; redoStack = []
            selectedIndex = nil; editingIndex = nil
            installBase(newValue)
            onChanged?()
        }
    }

    /// Sets the base screenshot (as shapes[0]) and canvas size WITHOUT touching
    /// undo history — used both by `image` and by the rotate/flip bake.
    private func installBase(_ img: NSImage?) {
        baseImage = img
        draft = nil
        if let img = img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            canvasSize = CGSize(width: cg.width, height: cg.height)
            displayScale = img.size.width > 0 ? img.size.width / CGFloat(cg.width) : 1
            var base = AnnoShape(tool: .box, a: .zero, b: CGPoint(x: cg.width, y: cg.height),
                                 color: .clear, width: 1)
            base.image = img; base.isBase = true
            shapes = [base]
        } else {
            canvasSize = .zero; displayScale = 1; shapes = []
        }
        selectedIndex = nil
        invalidateIntrinsicContentSize()
        needsDisplay = true
        onCanvasResized?()
    }

    // MARK: Rotate / flip the whole capture

    func rotateCanvas(clockwise: Bool) {
        guard let flat = renderFlattened()?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        pushUndoSnapshot()
        let scale = displayScale
        let rc = Self.rotate90(flat, clockwise: clockwise)
        installBase(NSImage(cgImage: rc, size: NSSize(width: CGFloat(rc.width) * scale,
                                                      height: CGFloat(rc.height) * scale)))
        onChanged?()
    }
    func flipCanvas(horizontal: Bool) {
        guard let flat = renderFlattened()?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        pushUndoSnapshot()
        let scale = displayScale
        let fc = Self.flip(flat, horizontal: horizontal)
        installBase(NSImage(cgImage: fc, size: NSSize(width: CGFloat(fc.width) * scale,
                                                     height: CGFloat(fc.height) * scale)))
        onChanged?()
    }

    private static func rgba(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    static func rotate90(_ cg: CGImage, clockwise: Bool) -> CGImage {
        let w = cg.width, h = cg.height
        guard let ctx = rgba(h, w) else { return cg }
        ctx.translateBy(x: CGFloat(h) / 2, y: CGFloat(w) / 2)
        ctx.rotate(by: clockwise ? -.pi / 2 : .pi / 2)
        ctx.draw(cg, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage() ?? cg
    }
    static func flip(_ cg: CGImage, horizontal: Bool) -> CGImage {
        let w = cg.width, h = cg.height
        guard let ctx = rgba(w, h) else { return cg }
        if horizontal { ctx.translateBy(x: CGFloat(w), y: 0); ctx.scaleBy(x: -1, y: 1) }
        else { ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1) }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? cg
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(1, canvasSize.width * displayScale),
               height: max(1, canvasSize.height * displayScale))
    }

    private func viewToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / displayScale, y: p.y / displayScale)
    }
    private func imageToView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * displayScale, y: p.y * displayScale)
    }
    /// Canvas pixels per view point (for hit tolerances, handle sizes).
    private var imageScale: CGFloat { 1 / displayScale }

    private func effectiveWidth(slider v: CGFloat) -> CGFloat {
        max(1, v * max(canvasSize.width, canvasSize.height) / 500)
    }
    func sliderValue(for shape: AnnoShape) -> Double {
        let dim = max(canvasSize.width, canvasSize.height, 1)
        return Double(shape.width * 500 / dim)
    }

    private func normRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: Text metrics

    private func font(for s: AnnoShape) -> NSFont {
        let size = max(10, s.width * 5)
        if s.fontName.isEmpty { return .boldSystemFont(ofSize: size) }
        return NSFont(name: s.fontName, size: size) ?? .boldSystemFont(ofSize: size)
    }
    private func textBounds(_ s: AnnoShape) -> CGRect {
        let size = NSAttributedString(string: s.text, attributes: [.font: font(for: s)]).size()
        return CGRect(origin: s.a, size: size)
    }

    // MARK: Hit testing / handles

    private func boundingRect(_ s: AnnoShape) -> CGRect {
        switch s.tool {
        case .box, .oval, .blur:   return normRect(s.a, s.b)
        case .line, .arrow:        return normRect(s.a, s.b)
        case .text:                return textBounds(s)
        case .pen, .highlight:
            guard let first = s.points.first else { return .zero }
            var r = CGRect(origin: first, size: .zero)
            for p in s.points { r = r.union(CGRect(origin: p, size: .zero)) }
            return r
        }
    }

    private func distToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private func shapeHit(at p: CGPoint, includeBase: Bool = true) -> Int? {
        let tol = 8 * imageScale
        for i in shapes.indices.reversed() {
            if i == 0 && shapes[i].isBase && !includeBase { continue }
            let s = shapes[i]
            if s.isImage {
                if normRect(s.a, s.b).insetBy(dx: -tol, dy: -tol).contains(p) { return i }
                continue
            }
            switch s.tool {
            case .box, .oval, .blur:
                if normRect(s.a, s.b).insetBy(dx: -tol, dy: -tol).contains(p) { return i }
            case .text:
                if textBounds(s).insetBy(dx: -tol, dy: -tol).contains(p) { return i }
            case .line, .arrow:
                if distToSegment(p, s.a, s.b) < max(s.width, tol) { return i }
            case .pen, .highlight:
                for j in 1..<max(1, s.points.count) where j < s.points.count {
                    if distToSegment(p, s.points[j - 1], s.points[j]) < max(s.width * 1.5, tol) { return i }
                }
            }
        }
        return nil
    }

    private func handles(for s: AnnoShape) -> [CGPoint] {
        if s.isImage {
            let r = normRect(s.a, s.b)
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        }
        switch s.tool {
        case .box, .oval, .blur:
            let r = normRect(s.a, s.b)
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        case .line, .arrow: return [s.a, s.b]
        case .text:
            let r = textBounds(s); return [CGPoint(x: r.maxX, y: r.maxY)]
        case .pen, .highlight: return []
        }
    }

    private func handleHit(_ p: CGPoint, shape: AnnoShape) -> Int? {
        let tol = 11 * imageScale
        for (i, h) in handles(for: shape).enumerated() where hypot(p.x - h.x, p.y - h.y) < tol {
            return i
        }
        return nil
    }

    /// 8 crop handles (corners + edge midpoints) around the canvas rect.
    private func cropHandlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.midY),                                CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard baseImage != nil else { return }
        window?.makeFirstResponder(self)
        let vp = convert(event.locationInWindow, from: nil)
        commitTextEditor()
        let ip = viewToImage(vp)

        if cropMode {
            liveCrop = CGRect(origin: .zero, size: canvasSize)
            if let h = cropHandleHit(ip) { dragMode = .crop(h); dragStart = ip }
            return
        }
        if ocrMode {
            dragMode = .ocr; dragStart = ip; liveOCR = CGRect(origin: ip, size: .zero); return
        }

        if event.clickCount == 2, let i = shapeHit(at: ip), shapes[i].tool == .text {
            selectedIndex = i
            beginTextEditor(atView: imageToView(shapes[i].a), image: shapes[i].a,
                            editing: i, prefill: shapes[i].text)
            return
        }
        // ✕ delete badge of the selection.
        if let sel = selectedIndex, shapes.indices.contains(sel) {
            let c = deleteBadgeCenter(for: shapes[sel])
            if hypot(ip.x - c.x, ip.y - c.y) < 11 * imageScale { deleteSelected(); return }
        }
        if let sel = selectedIndex, shapes.indices.contains(sel),
           let h = handleHit(ip, shape: shapes[sel]) {
            dragMode = .resize(h); origShape = shapes[sel]; dragStart = ip; return
        }
        // In select mode any element (incl. the base screenshot) can be grabbed;
        // while drawing, only existing annotations can, so drawing works over it.
        if let i = shapeHit(at: ip, includeBase: selectMode) {
            selectedIndex = i; dragMode = .move; origShape = shapes[i]; dragStart = ip; return
        }
        selectedIndex = nil
        if selectMode { return }
        if tool == .text { beginTextEditor(atView: vp, image: ip, editing: nil, prefill: ""); return }
        pushUndoSnapshot()
        draft = AnnoShape(tool: tool, a: ip, b: ip, points: [ip],
                          color: color, width: effectiveWidth(slider: strokeWidth),
                          fontName: defaultFontName)
        dragMode = .draw; needsDisplay = true
    }

    private func cropHandleHit(_ p: CGPoint) -> Int? {
        let tol = 12 * imageScale
        for (i, h) in cropHandlePoints(CGRect(origin: .zero, size: canvasSize)).enumerated()
        where hypot(p.x - h.x, p.y - h.y) < tol { return i }
        return nil
    }

    override func mouseDragged(with event: NSEvent) {
        let ip = viewToImage(convert(event.locationInWindow, from: nil))
        switch dragMode {
        case .draw:
            guard var d = draft else { return }
            d.b = ip
            if d.tool == .pen || d.tool == .highlight { d.points.append(ip) }
            draft = d; needsDisplay = true
        case .move:
            guard let o = origShape, let i = selectedIndex, shapes.indices.contains(i) else { return }
            let dx = ip.x - dragStart.x, dy = ip.y - dragStart.y
            var m = o
            m.a = CGPoint(x: o.a.x + dx, y: o.a.y + dy)
            m.b = CGPoint(x: o.b.x + dx, y: o.b.y + dy)
            m.points = o.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            shapes[i] = m; needsDisplay = true
        case .resize(let h):
            guard let o = origShape, let i = selectedIndex, shapes.indices.contains(i) else { return }
            shapes[i] = resized(o, handle: h, to: ip); needsDisplay = true
        case .crop(let h):
            liveCrop = cropAdjust(CGRect(origin: .zero, size: canvasSize), handle: h, to: ip)
            needsDisplay = true
        case .ocr:
            liveOCR = normRect(dragStart, ip); needsDisplay = true
        case .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragMode = .none; origShape = nil }
        switch dragMode {
        case .draw:
            guard var d = draft else { return }
            draft = nil
            let r = normRect(d.a, d.b)
            if d.tool != .pen, d.tool != .highlight, r.width < 3, r.height < 3 { needsDisplay = true; return }
            if d.tool == .blur { d.pixelated = pixelatedPatch(rect: r) }
            shapes.append(d); selectedIndex = shapes.count - 1; needsDisplay = true; onChanged?()
        case .move, .resize:
            if let i = selectedIndex, shapes.indices.contains(i), shapes[i].tool == .blur {
                shapes[i].pixelated = pixelatedPatch(rect: normRect(shapes[i].a, shapes[i].b))
            }
            needsDisplay = true; onChanged?()
        case .crop:
            applyCrop(liveCrop)
        case .ocr:
            runOCR(rect: liveOCR); liveOCR = .zero; needsDisplay = true
        case .none: break
        }
    }

    /// Recognizes text in a canvas-space rect of the flattened image and reports
    /// it via onOCR (so the pane can copy it to the clipboard).
    private func runOCR(rect: CGRect) {
        guard rect.width > 6, rect.height > 6, let flat = flattenCurrent() else { onOCR?(""); return }
        let bounds = CGRect(x: 0, y: 0, width: flat.width, height: flat.height)
        let r = rect.intersection(bounds).integral
        guard r.width > 4, r.height > 4, let crop = flat.cropping(to: r) else { onOCR?(""); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([req])
            let text = (req.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            DispatchQueue.main.async { self?.onOCR?(text) }
        }
    }

    private func resized(_ o: AnnoShape, handle h: Int, to ip: CGPoint) -> AnnoShape {
        var s = o
        if o.isImage || o.tool == .box || o.tool == .oval || o.tool == .blur {
            let r = normRect(o.a, o.b)
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                           CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
            let opposite = corners[3 - h]
            s.a = opposite; s.b = ip
        } else if o.tool == .line || o.tool == .arrow {
            if h == 0 { s.a = ip } else { s.b = ip }
        } else if o.tool == .text {
            let origW = max(20, textBounds(o).width)
            s.width = max(1, o.width * max(0.2, (ip.x - o.a.x) / origW))
        }
        return s
    }

    // MARK: Crop / resize canvas

    private func cropAdjust(_ r: CGRect, handle h: Int, to ip: CGPoint) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch h {
        case 0: minX = ip.x; minY = ip.y
        case 1: minY = ip.y
        case 2: maxX = ip.x; minY = ip.y
        case 3: minX = ip.x
        case 4: maxX = ip.x
        case 5: minX = ip.x; maxY = ip.y
        case 6: maxY = ip.y
        case 7: maxX = ip.x; maxY = ip.y
        default: break
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: abs(maxX - minX), height: abs(maxY - minY))
    }

    /// Applies a crop/expand rect (canvas coords, may extend past the current
    /// canvas to add blank space). Shifts all shapes and resizes the canvas.
    private func applyCrop(_ rect: CGRect) {
        guard rect.width > 20, rect.height > 20 else { needsDisplay = true; return }
        pushUndoSnapshot()
        let dx = -rect.minX, dy = -rect.minY
        for i in shapes.indices {
            shapes[i].a = CGPoint(x: shapes[i].a.x + dx, y: shapes[i].a.y + dy)
            shapes[i].b = CGPoint(x: shapes[i].b.x + dx, y: shapes[i].b.y + dy)
            shapes[i].points = shapes[i].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        }
        canvasSize = CGSize(width: rect.width, height: rect.height)
        invalidateIntrinsicContentSize()
        needsDisplay = true
        onCanvasResized?(); onChanged?()
    }

    /// Grows the canvas so `rect` (canvas coords) fits, returning the shift that
    /// was applied to existing content.
    @discardableResult
    private func growCanvasToInclude(_ rect: CGRect) -> CGPoint {
        let originX = min(0, rect.minX), originY = min(0, rect.minY)
        let farX = max(canvasSize.width, rect.maxX), farY = max(canvasSize.height, rect.maxY)
        let dx = -originX, dy = -originY
        if dx > 0 || dy > 0 {
            for i in shapes.indices {
                shapes[i].a = CGPoint(x: shapes[i].a.x + dx, y: shapes[i].a.y + dy)
                shapes[i].b = CGPoint(x: shapes[i].b.x + dx, y: shapes[i].b.y + dy)
                shapes[i].points = shapes[i].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            }
        }
        canvasSize = CGSize(width: farX + dx, height: farY + dy)
        invalidateIntrinsicContentSize()
        onCanvasResized?()
        return CGPoint(x: dx, y: dy)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: if selectedIndex != nil { deleteSelected() } else { super.keyDown(with: event) }
        case 53: if cropMode { cropMode = false } else { selectedIndex = nil }
        default: super.keyDown(with: event)
        }
    }

    // MARK: Drag-in images

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { registerForDraggedTypes([.fileURL, .tiff, .png]) }
    }
    private func imageFromDrag(_ sender: NSDraggingInfo) -> NSImage? {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let u = urls.first, let img = NSImage(contentsOf: u) { return img }
        return NSImage(pasteboard: pb)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageFromDrag(sender) != nil ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let img = imageFromDrag(sender) else { return false }
        addDroppedImage(img, atView: convert(sender.draggingLocation, from: nil))
        return true
    }

    /// Adds a dropped image by making room for it: the canvas (background) grows
    /// to the right and the new capture is placed in that fresh blank space,
    /// scaled to the current canvas height so it combines side-by-side without
    /// covering existing edits. It's a normal element afterwards, so you can drag
    /// it wherever you like.
    func addDroppedImage(_ img: NSImage, atView vp: CGPoint) {
        guard baseImage != nil else { image = img; return }
        window?.makeFirstResponder(self)
        pushUndoSnapshot()
        let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let iw = CGFloat(cg?.width ?? Int(img.size.width))
        let ih = CGFloat(cg?.height ?? Int(img.size.height))

        // Match the new capture's height to the current canvas so they line up,
        // keeping its aspect ratio.
        let targetH = canvasSize.height
        let scale = targetH / max(ih, 1)
        let w = max(20, iw * scale), h = max(20, targetH)
        let gap = max(12, canvasSize.width * 0.02)
        let rect = CGRect(x: canvasSize.width + gap, y: 0, width: w, height: h)

        growCanvasToInclude(rect)   // extend background to the right to fit it
        var s = AnnoShape(tool: .box, a: rect.origin,
                          b: CGPoint(x: rect.maxX, y: rect.maxY), color: .clear, width: 1)
        s.image = img
        shapes.append(s)
        selectedIndex = shapes.count - 1
        needsDisplay = true; onChanged?()
    }

    // MARK: Text tool

    private func beginTextEditor(atView vp: CGPoint, image ip: CGPoint, editing: Int?, prefill: String) {
        pendingTextPoint = ip
        editingIndex = editing
        let field = NSTextField(frame: NSRect(x: vp.x, y: vp.y, width: 220, height: 24))
        field.placeholderString = "Type, then press Return"
        field.stringValue = prefill
        field.font = .systemFont(ofSize: 13)
        field.target = self; field.action = #selector(textCommitted(_:))
        addSubview(field); window?.makeFirstResponder(field); textEditor = field
    }
    @objc private func textCommitted(_ f: NSTextField) {
        let str = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        f.removeFromSuperview(); textEditor = nil
        if let i = editingIndex, shapes.indices.contains(i) {
            editingIndex = nil
            if str.isEmpty { shapes.remove(at: i); selectedIndex = nil } else { shapes[i].text = str }
            needsDisplay = true; onChanged?(); return
        }
        editingIndex = nil
        guard !str.isEmpty else { needsDisplay = true; return }
        pushUndoSnapshot()
        var sh = AnnoShape(tool: .text, a: pendingTextPoint, b: pendingTextPoint,
                           color: color, width: effectiveWidth(slider: strokeWidth), fontName: defaultFontName)
        sh.text = str
        shapes.append(sh); selectedIndex = shapes.count - 1; needsDisplay = true; onChanged?()
    }
    private func commitTextEditor(discard: Bool = false) {
        guard let f = textEditor else { return }
        if discard { f.removeFromSuperview(); textEditor = nil; editingIndex = nil; return }
        textCommitted(f)
    }

    // MARK: Selection edits

    func applyColor(_ c: NSColor) {
        color = c
        if let i = selectedIndex, shapes.indices.contains(i), !shapes[i].isImage {
            shapes[i].color = c; needsDisplay = true; onChanged?()
        }
    }
    func applyWidth(sliderValue v: CGFloat) {
        strokeWidth = v
        if let i = selectedIndex, shapes.indices.contains(i), !shapes[i].isImage {
            shapes[i].width = effectiveWidth(slider: v); needsDisplay = true; onChanged?()
        }
    }
    func applyFont(_ name: String) {
        defaultFontName = name
        if let i = selectedIndex, shapes.indices.contains(i), shapes[i].tool == .text {
            shapes[i].fontName = name; needsDisplay = true; onChanged?()
        }
    }
    func deleteSelected() {
        guard let i = selectedIndex, shapes.indices.contains(i) else { return }
        pushUndoSnapshot()
        shapes.remove(at: i); selectedIndex = nil; needsDisplay = true; onChanged?()
    }

    // MARK: Undo / redo (full-state snapshots: shapes + canvas size + base image,
    // so draw/move/resize/crop/rotate/flip all restore correctly)

    private struct CanvasState {
        var shapes: [AnnoShape]; var canvasSize: CGSize; var displayScale: CGFloat; var baseImage: NSImage?
    }
    private var undoStack: [CanvasState] = []
    private var redoStack: [CanvasState] = []

    private func snapshotState() -> CanvasState {
        CanvasState(shapes: shapes, canvasSize: canvasSize, displayScale: displayScale, baseImage: baseImage)
    }
    private func applyState(_ st: CanvasState) {
        shapes = st.shapes; canvasSize = st.canvasSize; displayScale = st.displayScale; baseImage = st.baseImage
        selectedIndex = nil
        invalidateIntrinsicContentSize(); needsDisplay = true; onCanvasResized?(); onChanged?()
    }
    private func pushUndoSnapshot() {
        redoStack = []; undoStack.append(snapshotState())
        if undoStack.count > 40 { undoStack.removeFirst(undoStack.count - 40) }
    }
    func undoShape() {
        commitTextEditor()
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(snapshotState()); applyState(prev)
    }
    func redoShape() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshotState()); applyState(next)
    }
    func clearShapes() {
        commitTextEditor(discard: true)
        guard shapes.count > 1 else { return }   // keep the base image
        pushUndoSnapshot()
        shapes = Array(shapes.prefix(1)); selectedIndex = nil; needsDisplay = true; onChanged?()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Nothing drawn when empty (no dark box, no placeholder text).
        guard baseImage != nil, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: displayScale, y: displayScale)
        NSBezierPath(rect: CGRect(origin: .zero, size: canvasSize)).addClip()
        NSColor.white.setFill()
        CGRect(origin: .zero, size: canvasSize).fill()
        for sh in shapes { drawShape(sh) }
        if let d = draft { drawShape(d) }
        if !cropMode, !ocrMode, let sel = selectedShape { drawSelectionOverlay(sel) }
        if cropMode { drawCropOverlay() }
        if ocrMode, dragMode.isOCR, liveOCR.width > 1 {
            NSColor.systemGreen.setStroke()
            let p = NSBezierPath(rect: liveOCR); p.lineWidth = 2 * imageScale
            p.setLineDash([5 * imageScale, 4 * imageScale], count: 2, phase: 0); p.stroke()
        }
        ctx.restoreGState()
    }

    private func drawCropOverlay() {
        let r = (dragMode.isCrop ? liveCrop : CGRect(origin: .zero, size: canvasSize))
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: r); outline.lineWidth = 2 * imageScale; outline.stroke()
        let hs = 9 * imageScale
        NSColor.controlAccentColor.setFill()
        for h in cropHandlePoints(r) {
            NSBezierPath(rect: CGRect(x: h.x - hs / 2, y: h.y - hs / 2, width: hs, height: hs)).fill()
        }
    }

    private func drawSelectionOverlay(_ s: AnnoShape) {
        let r = boundingRect(s).insetBy(dx: -4 * imageScale, dy: -4 * imageScale)
        let outline = NSBezierPath(rect: r)
        outline.lineWidth = 1.5 * imageScale
        outline.setLineDash([4 * imageScale, 3 * imageScale], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke(); outline.stroke()
        let hs = 7 * imageScale
        NSColor.controlAccentColor.setFill()
        for h in handles(for: s) {
            NSBezierPath(rect: CGRect(x: h.x - hs / 2, y: h.y - hs / 2, width: hs, height: hs)).fill()
        }
        let c = deleteBadgeCenter(for: s), br = 9 * imageScale
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: CGRect(x: c.x - br, y: c.y - br, width: br * 2, height: br * 2)).fill()
        let cross = NSBezierPath(); let e = br * 0.45
        cross.move(to: CGPoint(x: c.x - e, y: c.y - e)); cross.line(to: CGPoint(x: c.x + e, y: c.y + e))
        cross.move(to: CGPoint(x: c.x + e, y: c.y - e)); cross.line(to: CGPoint(x: c.x - e, y: c.y + e))
        cross.lineWidth = 2 * imageScale; cross.lineCapStyle = .round
        NSColor.white.setStroke(); cross.stroke()
    }

    private func deleteBadgeCenter(for s: AnnoShape) -> CGPoint {
        let r = boundingRect(s).insetBy(dx: -4 * imageScale, dy: -4 * imageScale)
        return CGPoint(x: r.maxX + 10 * imageScale, y: r.minY - 10 * imageScale)
    }

    private func drawShape(_ s: AnnoShape) {
        // Use the simple draw(in:) so images render upright in this flipped view
        // (the from:operation:fraction: variant draws upside-down when flipped).
        if let im = s.image { im.draw(in: normRect(s.a, s.b)); return }
        s.color.setStroke(); s.color.setFill()
        func stroked(_ path: NSBezierPath, width: CGFloat) {
            path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
        }
        switch s.tool {
        case .arrow:
            let path = NSBezierPath(); path.move(to: s.a); path.line(to: s.b)
            stroked(path, width: s.width)
            let angle = atan2(s.b.y - s.a.y, s.b.x - s.a.x), head = max(s.width * 4, 10)
            let p1 = CGPoint(x: s.b.x - head * cos(angle - 0.45), y: s.b.y - head * sin(angle - 0.45))
            let p2 = CGPoint(x: s.b.x - head * cos(angle + 0.45), y: s.b.y - head * sin(angle + 0.45))
            let tri = NSBezierPath(); tri.move(to: s.b); tri.line(to: p1); tri.line(to: p2); tri.close(); tri.fill()
        case .box:
            stroked(NSBezierPath(roundedRect: normRect(s.a, s.b), xRadius: s.width, yRadius: s.width), width: s.width)
        case .oval:
            stroked(NSBezierPath(ovalIn: normRect(s.a, s.b)), width: s.width)
        case .line:
            let path = NSBezierPath(); path.move(to: s.a); path.line(to: s.b); stroked(path, width: s.width)
        case .pen, .highlight:
            guard s.points.count > 1 else { break }
            let path = NSBezierPath(); path.move(to: s.points[0])
            for p in s.points.dropFirst() { path.line(to: p) }
            if s.tool == .highlight { s.color.withAlphaComponent(0.4).setStroke(); stroked(path, width: s.width * 3) }
            else { stroked(path, width: s.width) }
        case .text:
            NSAttributedString(string: s.text, attributes: [.font: font(for: s), .foregroundColor: s.color]).draw(at: s.a)
        case .blur:
            let r = normRect(s.a, s.b)
            if let patch = s.pixelated { patch.draw(in: r) }
            else {
                let path = NSBezierPath(rect: r)
                path.setLineDash([s.width * 2, s.width * 2], count: 2, phase: 0)
                stroked(path, width: max(1, s.width / 2))
            }
        }
    }

    // MARK: Pixelate

    private func rgbaContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Flatten all current (non-draft) shapes to a canvas-resolution image, so
    /// the blur tool samples whatever is beneath it (base + earlier shapes).
    private func flattenCurrent() -> CGImage? {
        let w = Int(canvasSize.width), h = Int(canvasSize.height)
        guard w > 0, h > 0, let ctx = rgbaContext(width: w, height: h) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        let g = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
        NSColor.white.setFill(); CGRect(x: 0, y: 0, width: w, height: h).fill()
        for s in shapes where s.tool != .blur || s.pixelated != nil { drawShape(s) }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private func pixelatedPatch(rect: CGRect) -> NSImage? {
        guard let flat = flattenCurrent() else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: flat.width, height: flat.height)
        let r = rect.intersection(bounds).integral
        guard r.width >= 2, r.height >= 2, let crop = flat.cropping(to: r) else { return nil }
        let block = max(8, r.width / 24)
        let sw = max(1, Int(r.width / block)), sh = max(1, Int(r.height / block))
        guard let small = rgbaContext(width: sw, height: sh) else { return nil }
        small.interpolationQuality = .low
        small.draw(crop, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let smallImg = small.makeImage(),
              let big = rgbaContext(width: Int(r.width), height: Int(r.height)) else { return nil }
        big.interpolationQuality = .none
        big.draw(smallImg, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        return big.makeImage().map { NSImage(cgImage: $0, size: r.size) }
    }

    // MARK: Export

    func renderFlattened() -> NSImage? {
        commitTextEditor()
        let sel = selectedIndex; selectedIndex = nil
        defer { selectedIndex = sel }
        guard let out = flattenCurrent() else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
    }
}

