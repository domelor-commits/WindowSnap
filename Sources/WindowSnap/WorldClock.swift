import Cocoa

/// A clickable hour row spanning the city columns; selecting it outlines the
/// aligned instant across all columns.
final class TimeRowView: NSStackView {
    let rowIndex: Int
    var onClick: ((Int) -> Void)?
    init(rowIndex: Int) {
        self.rowIndex = rowIndex
        super.init(frame: .zero)
        orientation = .horizontal; spacing = 6; alignment = .centerY
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tapped)))
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func tapped() { onClick?(rowIndex) }
}

/// A flipped container so the rows stack fills the scroll view from the top down.
final class FlippedClip: NSView { override var isFlipped: Bool { true } }

/// World Time as vertical city columns (like worldtimebuddy's converter): up to
/// four cities, each headed by a full-width dropdown and a column of 24 hours
/// running top→bottom. A green outline aligns the same instant across columns;
/// move it with the vertical slider on the left or by clicking a row. Columns
/// 3 and 4 are optional ("None").
final class WorldClockView: NSView {
    private let cityPopups = [NSPopUpButton(), NSPopUpButton(), NSPopUpButton(), NSPopUpButton(), NSPopUpButton()]
    private let headerRow = NSStackView()
    private let rowsStack = NSStackView()
    private let scroll = NSScrollView()
    private let summary = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let selectionBar = NSView()
    private var barLabels: [NSTextField] = []
    private var barTop: NSLayoutConstraint!

    private let hourCount = 24
    private let stepsPerDay = 288                 // 5-minute steps (24 × 12)
    private let colWidth: CGFloat = 126
    private let gutter: CGFloat = 30
    private let rowHeight: CGFloat = 22
    private let rowSpacing: CGFloat = 3
    private var rowUnit: CGFloat { rowHeight + rowSpacing }
    private var referenceDate = Date()            // the day the grid is anchored on
    private var selectedStep = 0                  // 0…287 (× 5 min from home midnight)
    private var columnIDs: [String?] = []
    private var homeMidnight = Date()
    private var didSetDefaults = false

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); build() }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        for (i, p) in cityPopups.enumerated() {
            if i >= 2 { p.addItem(withTitle: "None"); p.lastItem?.representedObject = "" }
            p.addItem(withTitle: "UTC"); p.lastItem?.representedObject = "UTC"
            for group in UnitCatalog.zoneGroups {
                p.menu?.addItem(.separator())
                let header = NSMenuItem(title: group.region.uppercased(), action: nil, keyEquivalent: "")
                header.isEnabled = false
                p.menu?.addItem(header)
                for z in group.zones { p.addItem(withTitle: z.label); p.lastItem?.representedObject = z.id }
            }
            p.target = self; p.action = #selector(citiesChanged)
            p.translatesAutoresizingMaskIntoConstraints = false
            p.widthAnchor.constraint(equalToConstant: colWidth).isActive = true
        }

        // Left slider snaps to 5-minute steps (top = first, bottom = last).
        slider.minValue = 0; slider.maxValue = Double(stepsPerDay - 1)
        slider.numberOfTickMarks = hourCount + 1; slider.isVertical = true
        slider.target = self; slider.action = #selector(sliderMoved)
        slider.translatesAutoresizingMaskIntoConstraints = false

        headerRow.orientation = .horizontal; headerRow.spacing = 6; headerRow.alignment = .bottom
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        rowsStack.orientation = .vertical; rowsStack.spacing = rowSpacing; rowsStack.alignment = .leading
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        // Floating selection bar (like 24timezones): drawn over the hourly grid,
        // one time label per column, moved by the slider / drag / click.
        selectionBar.wantsLayer = true
        selectionBar.layer?.cornerRadius = 6
        selectionBar.layer?.borderWidth = 2
        selectionBar.layer?.borderColor = NSColor.systemGreen.cgColor
        selectionBar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        selectionBar.translatesAutoresizingMaskIntoConstraints = false
        selectionBar.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(barDragged(_:))))

        let flip = FlippedClip()
        flip.translatesAutoresizingMaskIntoConstraints = false
        flip.addSubview(slider); flip.addSubview(rowsStack); flip.addSubview(selectionBar)
        barTop = selectionBar.topAnchor.constraint(equalTo: rowsStack.topAnchor, constant: 0)
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: flip.leadingAnchor, constant: 2),
            slider.widthAnchor.constraint(equalToConstant: 18),
            slider.topAnchor.constraint(equalTo: rowsStack.topAnchor),
            slider.bottomAnchor.constraint(equalTo: rowsStack.bottomAnchor),
            rowsStack.topAnchor.constraint(equalTo: flip.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            rowsStack.trailingAnchor.constraint(equalTo: flip.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: flip.bottomAnchor),
            selectionBar.leadingAnchor.constraint(equalTo: rowsStack.leadingAnchor),
            selectionBar.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor),
            selectionBar.heightAnchor.constraint(equalToConstant: rowHeight),
            barTop,
        ])
        scroll.documentView = flip
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        summary.font = .systemFont(ofSize: 12, weight: .medium)
        summary.lineBreakMode = .byTruncatingTail
        summary.translatesAutoresizingMaskIntoConstraints = false

        addSubview(headerRow); addSubview(scroll); addSubview(summary)
        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16 + 26),
            scroll.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: summary.topAnchor, constant: -10),
            summary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            summary.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    func reload() {
        if !didSetDefaults {
            didSetDefaults = true
            // Column 0 is "home" (drives the grid anchor), so it tracks the system
            // zone unless the user saved something else. Remaining columns come
            // from Settings (persisted whenever a popup changes), falling back to
            // the built-in regional defaults on first run.
            let zones = Settings.shared.effectiveWorldClockZones
            let home = zones.first.flatMap { $0.isEmpty ? nil : $0 } ?? TimeZone.current.identifier
            selectDefault(cityPopups[0], preferred: home, fallback: "Asia/Singapore")
            for i in 1..<cityPopups.count {
                let id = i < zones.count ? zones[i] : ""
                if id.isEmpty { cityPopups[i].selectItem(at: 0) }   // "None" (cols 2+)
                else { selectDefault(cityPopups[i], preferred: id) }
            }
        }
        rebuild()
    }

    /// Anchor the grid on a specific day (from the date picker).
    func setDate(_ date: Date) { referenceDate = date; rebuild() }

    /// The absolute instant currently selected (for calendar events).
    var selectedInstant: Date { homeMidnight.addingTimeInterval(TimeInterval(selectedStep * 300)) }
    var selectionSummary: String { summaryString() }

    private func selectDefault(_ popup: NSPopUpButton, preferred: String, fallback: String? = nil) {
        for item in popup.itemArray where (item.representedObject as? String) == preferred { popup.select(item); return }
        if let fb = fallback { for item in popup.itemArray where (item.representedObject as? String) == fb { popup.select(item); return } }
        popup.selectItem(at: 0)
    }

    @objc private func citiesChanged() {
        // Persist so the selection survives relaunch and feeds the menu-bar glance.
        Settings.shared.worldClockZones = cityPopups.map {
            ($0.selectedItem?.representedObject as? String) ?? ""
        }
        Settings.shared.save()
        rebuild()
    }
    @objc private func sliderMoved() {
        selectedStep = (stepsPerDay - 1) - Int(slider.doubleValue.rounded())
        updateSelection(scrollTo: false)
    }
    private func syncSlider() { slider.integerValue = (stepsPerDay - 1) - selectedStep }

    /// Drag the floating bar to any 5-minute position.
    @objc private func barDragged(_ g: NSPanGestureRecognizer) {
        let y = g.location(in: rowsStack).y
        let step = Int((y / rowUnit * 12).rounded())
        selectedStep = max(0, min(stepsPerDay - 1, step))
        updateSelection(scrollTo: false)
    }

    private func rebuild() {
        columnIDs = cityPopups.map { p -> String? in
            let id = p.selectedItem?.representedObject as? String
            return (id?.isEmpty ?? true) ? nil : id
        }
        headerRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        barLabels.forEach { $0.removeFromSuperview() }
        barLabels.removeAll()

        guard let homeID = columnIDs.compactMap({ $0 }).first, let homeTZ = TimeZone(identifier: homeID) else {
            summary.stringValue = ""; return
        }
        var homeCal = Calendar(identifier: .gregorian); homeCal.timeZone = homeTZ
        homeMidnight = homeCal.startOfDay(for: referenceDate)
        let comps = homeCal.dateComponents([.hour, .minute], from: Date())
        selectedStep = (comps.hour ?? 0) * 12 + (comps.minute ?? 0) / 5

        // Header dropdowns + offset.
        for (i, id) in columnIDs.enumerated() {
            let offset = id.flatMap { TimeZone(identifier: $0) }.map { offsetString($0) } ?? " "
            let sub = NSTextField(labelWithString: offset)
            sub.font = .systemFont(ofSize: 10); sub.textColor = .secondaryLabelColor
            let col = NSStackView(views: [cityPopups[i], sub])
            col.orientation = .vertical; col.alignment = .leading; col.spacing = 1
            headerRow.addArrangedSubview(col)
        }

        // Hourly ladder (background).
        for r in 0..<hourCount {
            let row = TimeRowView(rowIndex: r)
            row.onClick = { [weak self] i in self?.selectedStep = i * 12; self?.updateSelection(scrollTo: false) }
            for id in columnIDs {
                if let id = id { row.addArrangedSubview(makeCell(id: id, hour: r)) }
                else {
                    let blank = NSView(); blank.translatesAutoresizingMaskIntoConstraints = false
                    blank.widthAnchor.constraint(equalToConstant: colWidth).isActive = true
                    blank.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
                    row.addArrangedSubview(blank)
                }
            }
            rowsStack.addArrangedSubview(row)
        }

        // Floating bar labels, one per column (spacing matches the rows).
        let barStack = NSStackView(); barStack.orientation = .horizontal; barStack.spacing = 6
        barStack.translatesAutoresizingMaskIntoConstraints = false
        for _ in columnIDs {
            let l = NSTextField(labelWithString: ""); l.alignment = .center
            l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: colWidth).isActive = true
            barLabels.append(l); barStack.addArrangedSubview(l)
        }
        selectionBar.subviews.forEach { $0.removeFromSuperview() }
        selectionBar.addSubview(barStack)
        NSLayoutConstraint.activate([
            barStack.leadingAnchor.constraint(equalTo: selectionBar.leadingAnchor),
            barStack.centerYAnchor.constraint(equalTo: selectionBar.centerYAnchor),
        ])
        updateSelection(scrollTo: true)
    }

    private func makeCell(id: String, hour r: Int) -> NSView {
        let tz = TimeZone(identifier: id) ?? .current
        let inst = homeMidnight.addingTimeInterval(TimeInterval(r * 3600))
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let h = cal.component(.hour, from: inst)
        let past = inst.addingTimeInterval(3600) <= Date()
        let box = NSView(); box.wantsLayer = true; box.layer?.cornerRadius = 5
        box.layer?.backgroundColor = color(h).cgColor
        box.alphaValue = past ? 0.4 : 1.0
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: colWidth).isActive = true
        box.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true

        let text = NSMutableAttributedString()
        if h == 0 {
            let f = DateFormatter(); f.timeZone = tz; f.dateFormat = "EEE"
            text.append(NSAttributedString(string: f.string(from: inst).uppercased() + "  ",
                attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        text.append(NSAttributedString(string: String(format: "%02d:00", h),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                         .foregroundColor: past ? NSColor.tertiaryLabelColor : NSColor.labelColor]))
        let l = NSTextField(labelWithAttributedString: text); l.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(l)
        NSLayoutConstraint.activate([l.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                                     l.centerYAnchor.constraint(equalTo: box.centerYAnchor)])
        return box
    }

    private func color(_ h: Int) -> NSColor {
        let base = NSColor(calibratedRed: 0.36, green: 0.55, blue: 0.92, alpha: 1)
        let a: CGFloat
        switch h { case 0...4, 23: a = 0.55; case 5...7, 20...22: a = 0.34; default: a = 0.14 }
        return base.withAlphaComponent(a)
    }

    private func updateSelection(scrollTo: Bool) {
        // Position the bar at the fractional-hour location of the selected step.
        barTop.constant = CGFloat(selectedStep) / 12.0 * rowUnit
        let inst = selectedInstant
        for (i, id) in columnIDs.compactMap({ $0 }).enumerated() where i < barLabels.count {
            guard let tz = TimeZone(identifier: id) else { continue }
            let f = DateFormatter(); f.timeZone = tz; f.dateFormat = "EEE HH:mm"
            barLabels[i].stringValue = f.string(from: inst)
        }
        syncSlider()
        summary.stringValue = summaryString()
        if scrollTo {
            let y = barTop.constant
            selectionBar.superview?.scrollToVisible(NSRect(x: 0, y: y - 60, width: 1, height: rowHeight + 120))
        }
    }

    private func summaryString() -> String {
        let inst = selectedInstant
        let parts = columnIDs.compactMap { $0 }.compactMap { id -> String? in
            guard let tz = TimeZone(identifier: id) else { return nil }
            var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
            let h = cal.component(.hour, from: inst); let m = cal.component(.minute, from: inst)
            let name = id == "UTC" ? "UTC" : (UnitCatalog.zones.first { $0.id == id }?.label.components(separatedBy: ", ").first ?? id)
            return String(format: "%02d:%02d %@ (%@)", h, m, offsetString(tz), name)
        }
        return parts.joined(separator: "   /   ")
    }

    private func offsetString(_ tz: TimeZone) -> String {
        if tz.identifier == "UTC" { return "UTC" }
        let secs = tz.secondsFromGMT(); let h = secs / 3600; let m = abs(secs / 60 % 60)
        return m == 0 ? String(format: "UTC%+03d", h) : String(format: "UTC%+03d:%02d", h, m)
    }
}

