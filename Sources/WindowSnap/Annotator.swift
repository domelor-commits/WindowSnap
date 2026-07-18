import Cocoa
import Vision

// MARK: - Annotator pane (toolbar + scrollable canvas)

/// The Annotate tab: screenshot picker, icon tool bar, style controls, a
/// full-size scrollable canvas, and export actions.
final class AnnotatorPane: NSView {

    private let canvas = AnnotationCanvas()
    private let scroll = NSScrollView()
    private let colorWell = NSColorWell()
    private let fontPopup = NSPopUpButton()
    private let widthSlider = NSSlider(value: 3, minValue: 1, maxValue: 12, target: nil, action: nil)
    private var toolButtons: [NSButton] = []
    private var selectButton: NSButton!
    private var cropButton: NSButton!
    private var ocrButton: NSButton!
    private var deleteButton: NSButton!
    private let statusLabel = NSTextField(labelWithString: "")
    private var currentPath: String?

    private static let fontChoices: [(title: String, name: String)] = [
        ("System Bold", ""), ("Helvetica Neue", "HelveticaNeue"), ("Arial", "ArialMT"),
        ("Georgia", "Georgia"), ("Menlo", "Menlo-Regular"), ("Impact", "Impact"),
        ("Marker Felt", "MarkerFelt-Wide"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func iconButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton()
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        img?.isTemplate = true
        b.image = img
        b.imageScaling = .scaleProportionallyDown
        // Borderless (like the tab menu) so contentTintColor is honored — grey by
        // default, blue only when active.
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.setButtonType(.momentaryChange)
        b.target = self; b.action = action
        b.toolTip = tip
        b.contentTintColor = .secondaryLabelColor
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 34).isActive = true
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }

    private func textButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded; b.controlSize = .small; b.font = .systemFont(ofSize: 11)
        return b
    }

    private func build() {
        // Single icon tool bar: crop · select · tools · undo/redo · copy/save.
        cropButton = iconButton("crop", tip: "Crop / resize canvas", action: #selector(cropPressed))
        selectButton = iconButton("cursorarrow", tip: "Select / move / resize (incl. the screenshot)",
                                  action: #selector(selectPressed))
        for t in AnnoTool.allCases {
            let b = iconButton(t.symbol, tip: t.tip, action: #selector(toolButtonPressed(_:)))
            b.tag = t.rawValue
            toolButtons.append(b)
        }
        ocrButton = iconButton("text.viewfinder", tip: "Recognize text: drag over text to copy it",
                               action: #selector(ocrPressed))
        let rotR = iconButton("rotate.right", tip: "Rotate right 90°", action: #selector(rotateRightPressed))
        let flipH = iconButton("arrow.left.and.right", tip: "Flip horizontal", action: #selector(flipHPressed))
        let flipV = iconButton("arrow.up.and.down", tip: "Flip vertical", action: #selector(flipVPressed))
        // Row 1: crop · select · drawing tools · OCR · rotate/flip.
        let toolRow = NSStackView(views:
            [cropButton, selectButton] + toolButtons + [ocrButton, rotR, flipH, flipV, NSView()])
        toolRow.orientation = .horizontal; toolRow.spacing = 4

        // Row 2: undo · redo · copy · save · save-as, left-aligned.
        let undoBtn = iconButton("arrow.uturn.backward", tip: "Undo", action: #selector(undoPressed))
        let redoBtn = iconButton("arrow.uturn.forward", tip: "Redo", action: #selector(redoPressed))
        let copyBtn = iconButton("doc.on.doc", tip: "Copy to clipboard", action: #selector(copyPressed))
        let saveBtn = iconButton("arrow.down.doc", tip: "Save", action: #selector(savePressed))
        let saveAsBtn = iconButton("square.and.arrow.down", tip: "Save As…", action: #selector(saveAsPressed))
        let actionRow = NSStackView(views: [undoBtn, redoBtn, copyBtn, saveBtn, saveAsBtn, NSView()])
        actionRow.orientation = .horizontal; actionRow.spacing = 4

        // Row 3: colour · font · size · delete.
        colorWell.color = .systemRed; colorWell.target = self; colorWell.action = #selector(colorChanged(_:))
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 40).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
        fontPopup.controlSize = .small; fontPopup.font = .systemFont(ofSize: 11)
        fontPopup.target = self; fontPopup.action = #selector(fontChanged(_:))
        for c in Self.fontChoices { fontPopup.addItem(withTitle: c.title); fontPopup.lastItem?.representedObject = c.name }
        fontPopup.translatesAutoresizingMaskIntoConstraints = false
        fontPopup.widthAnchor.constraint(equalToConstant: 118).isActive = true
        widthSlider.target = self; widthSlider.action = #selector(widthChanged(_:))
        widthSlider.controlSize = .small
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let sizeLabel = NSTextField(labelWithString: "Size:"); sizeLabel.font = .systemFont(ofSize: 11)
        deleteButton = textButton("Delete", #selector(deleteSelectedPressed)); deleteButton.isEnabled = false
        let styleRow = NSStackView(views: [colorWell, fontPopup, sizeLabel, widthSlider, deleteButton, NSView()])
        styleRow.orientation = .horizontal; styleRow.spacing = 8

        // Canvas in a scroll view so a full-size screenshot scrolls. No border or
        // dark fill — the empty area just shows the window background.
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        canvas.translatesAutoresizingMaskIntoConstraints = true
        canvas.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        scroll.documentView = canvas
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 10); statusLabel.textColor = .secondaryLabelColor
        canvas.onChanged = { [weak self] in self?.updateStatus() }
        canvas.onSelectionChanged = { [weak self] in self?.syncControlsToSelection() }
        canvas.onCanvasResized = { [weak self] in self?.updateCanvasFrame() }
        canvas.onOCR = { [weak self] text in
            guard let self = self else { return }
            if text.isEmpty { self.status("No text recognized in that area"); return }
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(text, forType: .string)
            self.status("Copied \(text.count) characters of text ✓")
            Logger.log("Annotate OCR: copied \(text.count) chars")
        }

        let stack = NSStackView(views: [toolRow, actionRow, styleRow, scroll, statusLabel])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            toolRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            toolRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            actionRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            actionRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            styleRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            styleRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        updateToolSelection()
    }

    private func updateCanvasFrame() {
        canvas.frame = NSRect(origin: .zero, size: canvas.intrinsicContentSize)
    }

    private func updateToolSelection() {
        // Grey by default (like the tab menu); only the active tool/mode is blue.
        let drawing = !canvas.cropMode && !canvas.selectMode && !canvas.ocrMode
        for b in toolButtons {
            b.contentTintColor = (drawing && b.tag == canvas.tool.rawValue) ? .controlAccentColor : .secondaryLabelColor
        }
        selectButton.contentTintColor = canvas.selectMode ? .controlAccentColor : .secondaryLabelColor
        cropButton.contentTintColor = canvas.cropMode ? .controlAccentColor : .secondaryLabelColor
        ocrButton.contentTintColor = canvas.ocrMode ? .controlAccentColor : .secondaryLabelColor
    }

    private func syncControlsToSelection() {
        guard let s = canvas.selectedShape, s.image == nil else {
            deleteButton.isEnabled = canvas.selectedShape != nil
            return
        }
        deleteButton.isEnabled = true
        colorWell.color = s.color
        widthSlider.doubleValue = min(12, max(1, canvas.sliderValue(for: s)))
        if s.tool == .text, let idx = Self.fontChoices.firstIndex(where: { $0.name == s.fontName }) {
            fontPopup.selectItem(at: idx)
        }
    }

    // MARK: Loading (captures deliver here; no file browser)

    func loadExternal(path: String) {
        if currentPath != path { load(path: path) }
    }
    func loadImage(_ img: NSImage, path: String?) {
        currentPath = path; canvas.image = img; updateCanvasFrame(); updateStatus()
    }
    private func load(path: String) {
        guard let img = NSImage(contentsOfFile: path) else {
            status("Couldn't open \((path as NSString).lastPathComponent)"); return
        }
        currentPath = path; canvas.image = img; updateCanvasFrame(); updateStatus()
    }

    // MARK: Actions

    @objc private func toolButtonPressed(_ sender: NSButton) {
        canvas.cropMode = false; canvas.selectMode = false; canvas.ocrMode = false
        canvas.tool = AnnoTool(rawValue: sender.tag) ?? .arrow
        updateToolSelection()
    }
    @objc private func selectPressed() {
        canvas.selectMode.toggle(); canvas.cropMode = false; canvas.ocrMode = false
        updateToolSelection(); updateStatus()
    }
    @objc private func cropPressed() {
        canvas.cropMode.toggle(); canvas.selectMode = false; canvas.ocrMode = false
        updateToolSelection(); updateStatus()
    }
    @objc private func ocrPressed() {
        canvas.ocrMode.toggle(); canvas.selectMode = false; canvas.cropMode = false
        updateToolSelection(); updateStatus()
    }
    @objc private func colorChanged(_ w: NSColorWell) { canvas.applyColor(w.color) }
    @objc private func widthChanged(_ s: NSSlider) { canvas.applyWidth(sliderValue: CGFloat(s.doubleValue)) }
    @objc private func fontChanged(_ p: NSPopUpButton) { canvas.applyFont((p.selectedItem?.representedObject as? String) ?? "") }
    @objc private func rotateLeftPressed() { canvas.rotateCanvas(clockwise: false) }
    @objc private func rotateRightPressed() { canvas.rotateCanvas(clockwise: true) }
    @objc private func flipHPressed() { canvas.flipCanvas(horizontal: true) }
    @objc private func flipVPressed() { canvas.flipCanvas(horizontal: false) }
    @objc private func deleteSelectedPressed() { canvas.deleteSelected() }
    @objc private func undoPressed() { canvas.undoShape() }
    @objc private func redoPressed() { canvas.redoShape() }

    @objc private func copyPressed() {
        guard let img = canvas.renderFlattened() else { NSSound.beep(); return }
        let pb = NSPasteboard.general; pb.clearContents(); pb.writeObjects([img])
        status("Copied to clipboard ✓"); Logger.log("Annotate: copied")
    }
    @objc private func savePressed() {
        guard let path = currentPath else { saveAsPressed(); return }
        write(to: path)
    }
    @objc private func saveAsPressed() {
        guard currentPath != nil || canvas.image != nil else { NSSound.beep(); return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        let base = (currentPath as NSString?)?.lastPathComponent ?? "Screenshot.png"
        panel.nameFieldStringValue = "Annotated \(base)"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url { write(to: url.path); currentPath = url.path }
    }
    private func write(to path: String) {
        guard let img = canvas.renderFlattened(), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            NSSound.beep(); return
        }
        do { try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            status("Saved \((path as NSString).lastPathComponent) ✓"); Logger.log("Annotate: saved \((path as NSString).lastPathComponent)")
        } catch { status("Save failed: \(error.localizedDescription)") }
    }

    private func status(_ s: String) { statusLabel.stringValue = s }
    private func updateStatus() {
        let name = (currentPath as NSString?)?.lastPathComponent
            ?? (canvas.image != nil ? "Clipboard image (unsaved)" : "—")
        let mode = canvas.cropMode ? "  ·  CROP: drag edges to resize/extend the canvas" :
            "  ·  click an item to select · drag handles to resize · ⌫ deletes · drop an image to combine"
        status("\(name)   ·   \(canvas.annotationCount) annotation\(canvas.annotationCount == 1 ? "" : "s")\(mode)")
    }
}
