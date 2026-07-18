import Cocoa
import EventKit

/// Ordered catalog of physical-unit categories for the Conversion tab.
enum UnitCatalog {
    struct Entry { let name: String; let unit: Dimension }
    struct Category { let name: String; let entries: [Entry] }

    private static let day = UnitDuration(symbol: "day", converter: UnitConverterLinear(coefficient: 86_400))
    private static let week = UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800))

    static let categories: [Category] = [
        Category(name: "Length", entries: [
            .init(name: "Millimeter", unit: UnitLength.millimeters),
            .init(name: "Centimeter", unit: UnitLength.centimeters),
            .init(name: "Meter", unit: UnitLength.meters),
            .init(name: "Kilometer", unit: UnitLength.kilometers),
            .init(name: "Inch", unit: UnitLength.inches),
            .init(name: "Foot", unit: UnitLength.feet),
            .init(name: "Yard", unit: UnitLength.yards),
            .init(name: "Mile", unit: UnitLength.miles),
            .init(name: "Nautical mile", unit: UnitLength.nauticalMiles),
        ]),
        Category(name: "Mass", entries: [
            .init(name: "Milligram", unit: UnitMass.milligrams),
            .init(name: "Gram", unit: UnitMass.grams),
            .init(name: "Kilogram", unit: UnitMass.kilograms),
            .init(name: "Tonne", unit: UnitMass.metricTons),
            .init(name: "Ounce", unit: UnitMass.ounces),
            .init(name: "Pound", unit: UnitMass.pounds),
            .init(name: "Stone", unit: UnitMass.stones),
        ]),
        Category(name: "Temperature", entries: [
            .init(name: "Celsius", unit: UnitTemperature.celsius),
            .init(name: "Fahrenheit", unit: UnitTemperature.fahrenheit),
            .init(name: "Kelvin", unit: UnitTemperature.kelvin),
        ]),
        Category(name: "Volume", entries: [
            .init(name: "Milliliter", unit: UnitVolume.milliliters),
            .init(name: "Liter", unit: UnitVolume.liters),
            .init(name: "Teaspoon", unit: UnitVolume.teaspoons),
            .init(name: "Tablespoon", unit: UnitVolume.tablespoons),
            .init(name: "Cup", unit: UnitVolume.cups),
            .init(name: "Pint", unit: UnitVolume.pints),
            .init(name: "Quart", unit: UnitVolume.quarts),
            .init(name: "Gallon", unit: UnitVolume.gallons),
        ]),
        Category(name: "Data", entries: [
            .init(name: "Byte", unit: UnitInformationStorage.bytes),
            .init(name: "Kilobyte", unit: UnitInformationStorage.kilobytes),
            .init(name: "Megabyte", unit: UnitInformationStorage.megabytes),
            .init(name: "Gigabyte", unit: UnitInformationStorage.gigabytes),
            .init(name: "Terabyte", unit: UnitInformationStorage.terabytes),
            .init(name: "Mebibyte", unit: UnitInformationStorage.mebibytes),
            .init(name: "Gibibyte", unit: UnitInformationStorage.gibibytes),
        ]),
        Category(name: "Speed", entries: [
            .init(name: "Meters / second", unit: UnitSpeed.metersPerSecond),
            .init(name: "Kilometers / hour", unit: UnitSpeed.kilometersPerHour),
            .init(name: "Miles / hour", unit: UnitSpeed.milesPerHour),
            .init(name: "Knots", unit: UnitSpeed.knots),
        ]),
        Category(name: "Time", entries: [
            .init(name: "Second", unit: UnitDuration.seconds),
            .init(name: "Minute", unit: UnitDuration.minutes),
            .init(name: "Hour", unit: UnitDuration.hours),
            .init(name: "Day", unit: day),
            .init(name: "Week", unit: week),
        ]),
        Category(name: "Area", entries: [
            .init(name: "Sq. meter", unit: UnitArea.squareMeters),
            .init(name: "Sq. kilometer", unit: UnitArea.squareKilometers),
            .init(name: "Sq. foot", unit: UnitArea.squareFeet),
            .init(name: "Sq. mile", unit: UnitArea.squareMiles),
            .init(name: "Hectare", unit: UnitArea.hectares),
            .init(name: "Acre", unit: UnitArea.acres),
        ]),
        Category(name: "Angle", entries: [
            .init(name: "Degree", unit: UnitAngle.degrees),
            .init(name: "Radian", unit: UnitAngle.radians),
            .init(name: "Gradian", unit: UnitAngle.gradians),
        ]),
    ]

    /// Time zones grouped by region, in the order shown in the pickers:
    /// Asia/Pacific, Europe, US/Americas, Middle East, Africa.
    static let zoneGroups: [(region: String, zones: [(label: String, id: String)])] = [
        ("Asia / Pacific", [
            ("Singapore", "Asia/Singapore"),
            ("Kuala Lumpur, Malaysia", "Asia/Kuala_Lumpur"),
            ("Bangkok, Thailand", "Asia/Bangkok"),
            ("Jakarta, Indonesia", "Asia/Jakarta"),
            ("Manila, Philippines", "Asia/Manila"),
            ("Ho Chi Minh, Vietnam", "Asia/Ho_Chi_Minh"),
            ("Hong Kong", "Asia/Hong_Kong"),
            ("Shanghai, China", "Asia/Shanghai"),
            ("Taipei, Taiwan", "Asia/Taipei"),
            ("Tokyo, Japan", "Asia/Tokyo"),
            ("Seoul, South Korea", "Asia/Seoul"),
            ("Mumbai, India", "Asia/Kolkata"),
            ("Sydney, Australia", "Australia/Sydney"),
            ("Auckland, New Zealand", "Pacific/Auckland"),
        ]),
        ("Europe", [
            ("London, UK", "Europe/London"),
            ("Paris, France", "Europe/Paris"),
            ("Berlin, Germany", "Europe/Berlin"),
            ("Madrid, Spain", "Europe/Madrid"),
            ("Rome, Italy", "Europe/Rome"),
            ("Amsterdam, Netherlands", "Europe/Amsterdam"),
            ("Moscow, Russia", "Europe/Moscow"),
            ("Istanbul, Türkiye", "Europe/Istanbul"),
        ]),
        ("US / Americas", [
            ("New York, USA", "America/New_York"),
            ("Chicago, USA", "America/Chicago"),
            ("Denver, USA", "America/Denver"),
            ("Los Angeles, USA", "America/Los_Angeles"),
            ("Honolulu, USA", "Pacific/Honolulu"),
            ("Toronto, Canada", "America/Toronto"),
            ("Mexico City, Mexico", "America/Mexico_City"),
            ("São Paulo, Brazil", "America/Sao_Paulo"),
        ]),
        ("Middle East", [
            ("Dubai, UAE", "Asia/Dubai"),
            ("Riyadh, Saudi Arabia", "Asia/Riyadh"),
            ("Tehran, Iran", "Asia/Tehran"),
            ("Jerusalem, Israel", "Asia/Jerusalem"),
        ]),
        ("Africa", [
            ("Johannesburg, South Africa", "Africa/Johannesburg"),
            ("Cairo, Egypt", "Africa/Cairo"),
            ("Lagos, Nigeria", "Africa/Lagos"),
            ("Nairobi, Kenya", "Africa/Nairobi"),
        ]),
    ]

    /// Flat list of all zones (for id → label lookups).
    static let zones: [(label: String, id: String)] = zoneGroups.flatMap { $0.zones }
}

// MARK: - World Time (vertical column view, worldtimebuddy-style)

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
            // zone. The rest are the regions we actually coordinate with day to day.
            selectDefault(cityPopups[0], preferred: TimeZone.current.identifier, fallback: "Asia/Singapore")
            selectDefault(cityPopups[1], preferred: "Asia/Bangkok")
            selectDefault(cityPopups[2], preferred: "Asia/Jakarta")
            selectDefault(cityPopups[3], preferred: "Asia/Ho_Chi_Minh")
            selectDefault(cityPopups[4], preferred: "Asia/Kolkata")   // Mumbai
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

    @objc private func citiesChanged() { rebuild() }
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

// MARK: - Conversion tab

/// The Conversion tab: Currency (live rates + country + pin/hide), World Time
/// (aligned hour grid), or a physical measure — converting to every unit at once.
final class ConversionPane: NSView, NSTableViewDataSource, NSTableViewDelegate,
                            NSTextFieldDelegate, NSMenuDelegate {
    private struct Row { let name: String; let country: String; let continent: String; let value: String; let inverse: String; let isSource: Bool; let code: String }

    private let categoryPopup = NSPopUpButton()
    private let amountLabel = NSTextField(labelWithString: "Amount:")
    private let amountField = NSTextField()
    private let fromLabel = NSTextField(labelWithString: "From:")
    private let fromPopup = NSPopUpButton()
    private let infoLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let worldClock = WorldClockView()
    private let eventButton = NSButton()
    /// Backing store for the selected World Time day (never shown; the arrow
    /// stepper below drives it). Kept as an NSDatePicker so the rest of the pane
    /// can keep reading `datePicker.dateValue`.
    private let datePicker = NSDatePicker()
    private var dateStepper: NSStackView!
    private let dateLabel = NSButton()   // center pill; click to jump back to today
    private let decimalsLabel = NSTextField(labelWithString: "Decimals:")
    private let decimalsPopup = NSPopUpButton()
    private let eventStore = EKEventStore()
    private var valueControls: NSStackView!
    private var rows: [Row] = []

    private var categoryIndex: Int { categoryPopup.indexOfSelectedItem }
    private var isWorldTime: Bool { categoryIndex == 0 }
    private var isCurrency: Bool { categoryIndex == 1 }

    private static let commonCurrencies = ["USD", "EUR", "GBP", "JPY", "CNY", "SGD", "AUD", "CAD", "CHF", "HKD", "INR", "THB", "MYR"]

    /// ISO region code → continent, built from grouped code lists.
    static let regionContinent: [String: String] = {
        let groups: [String: [String]] = [
            "Africa": ["DZ","AO","BJ","BW","BF","BI","CV","CM","CF","TD","KM","CG","CD","CI","DJ","EG","GQ","ER","SZ","ET","GA","GM","GH","GN","GW","KE","LS","LR","LY","MG","MW","ML","MR","MU","MA","MZ","NA","NE","NG","RW","ST","SN","SC","SL","SO","ZA","SS","SD","TZ","TG","TN","UG","ZM","ZW","EH"],
            "Europe": ["AL","AD","AT","BY","BE","BA","BG","HR","CY","CZ","DK","EE","FI","FR","DE","GR","HU","IS","IE","IT","XK","LV","LI","LT","LU","MT","MD","MC","ME","NL","MK","NO","PL","PT","RO","RU","SM","RS","SK","SI","ES","SE","CH","UA","GB","VA","GI","FO","IM","JE","GG"],
            "Asia": ["AF","AM","AZ","BD","BT","BN","KH","CN","GE","HK","IN","ID","JP","KZ","KG","LA","MO","MY","MV","MN","MM","NP","KP","PK","PH","SG","KR","LK","TW","TJ","TH","TL","TR","TM","UZ","VN"],
            "Middle East": ["BH","IR","IQ","IL","JO","KW","LB","OM","PS","QA","SA","SY","AE","YE"],
            "North America": ["AG","BS","BB","BZ","CA","CR","CU","DM","DO","SV","GD","GT","HT","HN","JM","MX","NI","PA","KN","LC","VC","TT","US","PR","AW","CW","SX","BM","KY","GL","AI","VG","VI","TC","MS"],
            "South America": ["AR","BO","BR","CL","CO","EC","GY","PY","PE","SR","UY","VE","FK"],
            "Oceania": ["AU","FJ","KI","MH","FM","NR","NZ","PW","PG","WS","SB","TO","TV","VU","NC","PF","GU","AS","CK"],
        ]
        var m: [String: String] = [:]
        for (cont, codes) in groups { for c in codes { m[c] = cont } }
        return m
    }()

    /// Currency code → (country name, continent), from ISO data with overrides.
    static let currencyInfo: [String: (country: String, continent: String)] = {
        var map: [String: (String, String)] = [:]
        if #available(macOS 13.0, *) {
            for region in Locale.Region.isoRegions {
                var comps = Locale.Components(identifier: "")
                comps.region = region
                guard let cur = Locale(components: comps).currency?.identifier.uppercased() else { continue }
                if map[cur] == nil {
                    let name = Locale.current.localizedString(forRegionCode: region.identifier) ?? region.identifier
                    let cont = regionContinent[region.identifier.uppercased()] ?? "Other"
                    map[cur] = (name, cont)
                }
            }
        }
        let overrides: [String: (String, String)] = [
            "USD": ("United States", "North America"), "EUR": ("Euro area", "Europe"),
            "GBP": ("United Kingdom", "Europe"), "CHF": ("Switzerland", "Europe"),
            "AUD": ("Australia", "Oceania"), "CAD": ("Canada", "North America"),
            "CNY": ("China", "Asia"), "JPY": ("Japan", "Asia"), "HKD": ("Hong Kong", "Asia"),
            "SGD": ("Singapore", "Asia"), "INR": ("India", "Asia"), "NZD": ("New Zealand", "Oceania"),
            "ZAR": ("South Africa", "Africa"), "XOF": ("West Africa", "Africa"), "XAF": ("Central Africa", "Africa"),
        ]
        for (k, v) in overrides { map[k] = v }
        return map
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        rebuildFromPopup()
        recompute()
        updateMode()
        CurrencyRates.prefetch()
        NotificationCenter.default.addObserver(self, selector: #selector(ratesUpdated),
                                               name: CurrencyRates.didUpdate, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        categoryPopup.addItem(withTitle: "World Time")
        categoryPopup.addItem(withTitle: "Currency")
        for c in UnitCatalog.categories { categoryPopup.addItem(withTitle: c.name) }
        categoryPopup.target = self; categoryPopup.action = #selector(categoryChanged)

        amountField.stringValue = "1"
        amountField.target = self; amountField.action = #selector(inputChanged)
        amountField.delegate = self
        amountField.translatesAutoresizingMaskIntoConstraints = false
        amountField.widthAnchor.constraint(equalToConstant: 110).isActive = true

        fromPopup.target = self; fromPopup.action = #selector(inputChanged)
        refreshButton.title = "Refresh rates"
        refreshButton.bezelStyle = .rounded; refreshButton.controlSize = .small
        refreshButton.target = self; refreshButton.action = #selector(refreshRates)

        // Decimal-places picker (currency only).
        decimalsLabel.font = .systemFont(ofSize: 12)
        for d in 0...6 { decimalsPopup.addItem(withTitle: "\(d)") }
        decimalsPopup.selectItem(withTitle: "\(Settings.shared.currencyDecimals)")
        decimalsPopup.target = self; decimalsPopup.action = #selector(decimalsChanged)

        valueControls = NSStackView(views: [amountLabel, amountField, fromLabel, fromPopup,
                                            decimalsLabel, decimalsPopup, refreshButton])
        valueControls.orientation = .horizontal; valueControls.spacing = 8

        // Date chooser as an inline arrow stepper: ‹‹ ‹  Jul 11, 2026  › ››
        // (single = ±1 day, double = ±1 month). Center pill jumps back to today.
        datePicker.dateValue = Date()
        dateStepper = buildDateStepper()

        eventButton.title = "＋ Calendar Event"
        eventButton.image = NSImage(systemSymbolName: "calendar.badge.plus", accessibilityDescription: "New event")
        eventButton.imagePosition = .imageLeading
        eventButton.bezelStyle = .rounded; eventButton.controlSize = .small
        eventButton.target = self; eventButton.action = #selector(createCalendarEvent)
        eventButton.toolTip = "Create a Calendar event at the selected World Time."

        let controls = NSStackView(views: [label("Category:"), categoryPopup, dateStepper,
                                           eventButton, valueControls])
        controls.orientation = .horizontal; controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        infoLabel.font = .systemFont(ofSize: 11); infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail
        infoLabel.translatesAutoresizingMaskIntoConstraints = false

        func col(_ ident: String, _ title: String, _ w: CGFloat, _ minW: CGFloat) -> NSTableColumn {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ident))
            c.title = title; c.width = w; c.minWidth = minW; c.maxWidth = 400
            return c
        }
        let unitCol = col("unit", "Unit", 90, 70)
        let countryCol = col("country", "Country", 150, 90)
        let continentCol = col("continent", "Continent", 100, 80)
        let valCol = col("value", "Value", 130, 100)
        let invCol = col("inverse", "Inverse", 130, 100)
        table.addTableColumn(unitCol); table.addTableColumn(countryCol)
        table.addTableColumn(continentCol); table.addTableColumn(valCol); table.addTableColumn(invCol)
        table.usesAlternatingRowBackgroundColors = true
        // Grow the first (name) column so the fixed-width value columns keep their
        // space instead of the Value column being squeezed under Inverse.
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 26
        table.allowsMultipleSelection = true
        table.dataSource = self; table.delegate = self
        table.doubleAction = #selector(copyRow); table.target = self
        table.menu = NSMenu(); table.menu?.delegate = self
        // Drag currency rows up/down to reorder.
        table.registerForDraggedTypes([.string])
        table.setDraggingSourceOperationMask(.move, forLocal: true)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        worldClock.translatesAutoresizingMaskIntoConstraints = false

        addSubview(controls); addSubview(infoLabel); addSubview(scroll); addSubview(worldClock)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            infoLabel.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            infoLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            infoLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            worldClock.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 4),
            worldClock.leadingAnchor.constraint(equalTo: leadingAnchor),
            worldClock.trailingAnchor.constraint(equalTo: trailingAnchor),
            worldClock.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: 12); return l
    }

    // MARK: Mode switching

    private func updateMode() {
        valueControls.isHidden = isWorldTime
        eventButton.isHidden = !isWorldTime
        dateStepper.isHidden = !isWorldTime
        infoLabel.isHidden = isWorldTime
        scroll.isHidden = isWorldTime
        worldClock.isHidden = !isWorldTime
        // Decimals picker only makes sense for currency.
        decimalsLabel.isHidden = !isCurrency
        decimalsPopup.isHidden = !isCurrency
        configureColumns()
        if isWorldTime { worldClock.setDate(datePicker.dateValue); worldClock.reload() }
    }

    /// Country/Continent/Inverse columns are shown only for currency; the first
    /// column's title switches between "Currency" and "Unit".
    private func configureColumns() {
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("country"))?.isHidden = !isCurrency
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("continent"))?.isHidden = !isCurrency
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("inverse"))?.isHidden = !isCurrency
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("unit"))?.title = isCurrency ? "Currency" : "Unit"
    }

    // MARK: Date popover & decimals

    /// Builds the inline date stepper: ‹‹ ‹  Jul 11, 2026  › ››
    private func buildDateStepper() -> NSStackView {
        func arrow(_ title: String, _ tip: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded; b.controlSize = .small
            b.font = .systemFont(ofSize: 12, weight: .medium)
            b.toolTip = tip
            return b
        }
        dateLabel.bezelStyle = .rounded; dateLabel.controlSize = .small
        dateLabel.setButtonType(.momentaryPushIn)
        dateLabel.target = self; dateLabel.action = #selector(dateJumpToday)
        dateLabel.toolTip = "Jump to today"
        let stack = NSStackView(views: [
            arrow("«", "Back one month", #selector(datePrevMonth)),
            arrow("‹", "Back one day", #selector(datePrevDay)),
            dateLabel,
            arrow("›", "Forward one day", #selector(dateNextDay)),
            arrow("»", "Forward one month", #selector(dateNextMonth)),
        ])
        stack.orientation = .horizontal; stack.spacing = 2
        updateDateButtonTitle()
        return stack
    }

    private func stepDate(day: Int = 0, month: Int = 0) {
        var comps = DateComponents(); comps.day = day; comps.month = month
        if let d = Calendar.current.date(byAdding: comps, to: datePicker.dateValue) {
            datePicker.dateValue = d
            dateChanged()
        }
    }
    @objc private func datePrevMonth() { stepDate(month: -1) }
    @objc private func dateNextMonth() { stepDate(month: 1) }
    @objc private func datePrevDay()   { stepDate(day: -1) }
    @objc private func dateNextDay()   { stepDate(day: 1) }
    @objc private func dateJumpToday() { datePicker.dateValue = Date(); dateChanged() }

    private func updateDateButtonTitle() {
        let f = DateFormatter(); f.dateStyle = .medium
        dateLabel.title = f.string(from: datePicker.dateValue)
    }
    @objc private func decimalsChanged() {
        Settings.shared.currencyDecimals = decimalsPopup.indexOfSelectedItem
        Settings.shared.save()
        recompute()
    }

    @objc private func hideSelected() {
        for r in table.selectedRowIndexes where r < rows.count {
            let code = rows[r].code
            if !Settings.shared.currencyHidden.contains(code) { Settings.shared.currencyHidden.append(code) }
            Settings.shared.currencyFavorites.removeAll { $0 == code }
        }
        persistAndRefresh()
    }

    // MARK: Drag currency rows to reorder

    func tableView(_ t: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard isCurrency else { return nil }
        let item = NSPasteboardItem(); item.setString(String(row), forType: .string); return item
    }
    func tableView(_ t: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        (isCurrency && op == .above) ? .move : []
    }
    func tableView(_ t: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation op: NSTableView.DropOperation) -> Bool {
        guard isCurrency,
              let s = info.draggingPasteboard.pasteboardItems?.first?.string(forType: .string),
              let from = Int(s), from < rows.count else { return false }
        var order = rows.map { $0.code }
        let code = order.remove(at: from)
        var dest = row
        if from < row { dest -= 1 }
        dest = max(0, min(order.count, dest))
        order.insert(code, at: dest)
        Settings.shared.currencyFavorites = order   // freeze into a custom order
        Settings.shared.save()
        recompute()
        return true
    }

    @objc private func dateChanged() { updateDateButtonTitle(); worldClock.setDate(datePicker.dateValue) }

    /// Create an event at the World Time currently selected in the grid.
    /// Prefers Microsoft Outlook when it's installed (that's where most people's
    /// work calendar lives); otherwise falls back to the system Calendar.
    @objc private func createCalendarEvent() {
        let start = worldClock.selectedInstant
        let notes = worldClock.selectionSummary
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Outlook") != nil {
            createOutlookEvent(start: start, notes: notes)
        } else {
            createAppleCalendarEvent(start: start, notes: notes)
        }
    }

    /// Ask Microsoft Outlook (via AppleScript) to create the event in its default
    /// calendar and open it for review. The first call triggers a one-time
    /// Automation permission prompt; if scripting fails or is denied, we fall
    /// back to the system Calendar so an event is always created somewhere.
    private func createOutlookEvent(start: Date, notes: String) {
        let end = start.addingTimeInterval(3600)
        let src = """
        \(appleScriptDate(from: start, varName: "s"))
        \(appleScriptDate(from: end, varName: "e"))
        tell application "Microsoft Outlook"
            set newEvent to make new calendar event with properties {subject:"Event", start time:s, end time:e, content:"\(appleScriptEscape(notes))"}
            open newEvent
            activate
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if err != nil {
            Logger.log("Outlook event failed; falling back to system Calendar")
            createAppleCalendarEvent(start: start, notes: notes)
        } else {
            LayoutManager.notify("Event added to Outlook", notes)
        }
    }

    /// Emit AppleScript assigning `varName` a `date` equal to `date` (local time).
    /// Sets day to 1 first so setting month/day mid-way never overflows.
    private func appleScriptDate(from date: Date, varName: String) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return """
        set \(varName) to current date
        set day of \(varName) to 1
        set year of \(varName) to \(c.year ?? 2025)
        set month of \(varName) to \(c.month ?? 1)
        set day of \(varName) to \(c.day ?? 1)
        set hours of \(varName) to \(c.hour ?? 9)
        set minutes of \(varName) to \(c.minute ?? 0)
        set seconds of \(varName) to 0
        """
    }

    /// Escape a string for safe embedding inside an AppleScript "..." literal.
    private func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
    }

    /// Create the event in the system Calendar via EventKit (the fallback path).
    private func createAppleCalendarEvent(start: Date, notes: String) {
        let make: (Bool) -> Void = { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard granted else {
                    LayoutManager.notify("Calendar access needed",
                        "Enable WindowSnap under System Settings → Privacy & Security → Calendars.")
                    return
                }
                let ev = EKEvent(eventStore: self.eventStore)
                ev.title = "Event"
                ev.startDate = start
                ev.endDate = start.addingTimeInterval(3600)
                ev.notes = notes
                ev.calendar = self.eventStore.defaultCalendarForNewEvents
                do {
                    try self.eventStore.save(ev, span: .thisEvent)
                    LayoutManager.notify("Event added to Calendar", notes)
                    // Open Calendar in Week view at the event, with its editor shown.
                    self.openCalendar(at: start, eventIdentifier: ev.eventIdentifier)
                } catch {
                    LayoutManager.notify("Couldn’t create event", error.localizedDescription)
                }
            }
        }
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { granted, _ in make(granted) }
        } else {
            eventStore.requestAccess(to: .event) { granted, _ in make(granted) }
        }
    }

    /// Bring Calendar to the front in Week view at `date`, then deep-link to the
    /// just-created event (ical://ekevent) so its editor pops open right away.
    /// Falls back to just launching Calendar if scripting is unavailable.
    private func openCalendar(at date: Date, eventIdentifier: String? = nil) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let src = """
        set d to current date
        set day of d to 1
        set year of d to \(c.year ?? 2025)
        set month of d to \(c.month ?? 1)
        set day of d to \(c.day ?? 1)
        set hours of d to \(c.hour ?? 9)
        set minutes of d to \(c.minute ?? 0)
        set seconds of d to 0
        tell application "Calendar"
            activate
            switch view to week view
            view calendar at d
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if err != nil {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        }
        // Once the week view is up, open the event itself via Calendar's own
        // deep-link scheme — this selects it and shows its edit popover.
        if let id = eventIdentifier,
           let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(enc)?method=show&options=more") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func categoryChanged() { updateMode(); if !isWorldTime { rebuildFromPopup(); recompute() } }
    @objc private func inputChanged() { recompute() }
    @objc private func refreshRates() { CurrencyRates.prefetch(force: true); infoLabel.stringValue = "Refreshing exchange rates…" }
    @objc private func ratesUpdated() { if isCurrency { rebuildFromPopup(preservingSelection: true); recompute() } }
    func controlTextDidChange(_ obj: Notification) { recompute() }

    private static let continentOrder = ["Asia", "Middle East", "Europe", "North America", "South America", "Oceania", "Africa", "Other"]

    /// Order: the user's custom/pinned order first, then the rest grouped by
    /// continent. Hidden currencies are excluded.
    private func currencyList() -> [String] {
        let hidden = Set(Settings.shared.currencyHidden)
        let all = CurrencyRates.codes.isEmpty ? Self.commonCurrencies : CurrencyRates.codes
        let allSet = Set(all)
        let favs = Settings.shared.currencyFavorites.filter { allSet.contains($0) && !hidden.contains($0) }
        let favSet = Set(favs)
        let rest = all.filter { !favSet.contains($0) && !hidden.contains($0) }.sorted { a, b in
            let ia = Self.continentOrder.firstIndex(of: Self.currencyInfo[a]?.continent ?? "Other") ?? 99
            let ib = Self.continentOrder.firstIndex(of: Self.currencyInfo[b]?.continent ?? "Other") ?? 99
            return ia != ib ? ia < ib : a < b
        }
        return favs + rest
    }

    private func rebuildFromPopup(preservingSelection: Bool = false) {
        let prev = fromPopup.selectedItem?.representedObject as? String
        fromPopup.removeAllItems()
        if isCurrency {
            let list = currencyList()
            for code in list { fromPopup.addItem(withTitle: code); fromPopup.lastItem?.representedObject = code }
            // Default the From currency to the first row in the table.
            select(fromPopup, code: (preservingSelection ? prev : nil) ?? list.first ?? "USD")
        } else if !isWorldTime {
            let entries = UnitCatalog.categories[categoryIndex - 2].entries
            fromPopup.addItems(withTitles: entries.map { $0.name })
            fromPopup.selectItem(at: 0)
        }
        refreshButton.isHidden = !isCurrency
    }

    private func select(_ popup: NSPopUpButton, code: String) {
        for item in popup.itemArray where (item.representedObject as? String) == code { popup.select(item); return }
        if popup.numberOfItems > 0 { popup.selectItem(at: 0) }
    }

    private func recompute() {
        guard !isWorldTime else { return }
        rows.removeAll()
        if isCurrency { currencyRecompute() } else { unitRecompute() }
        table.reloadData()
    }

    private func currencyRecompute() {
        let amount = Double(amountField.stringValue.replacingOccurrences(of: ",", with: "")) ?? 0
        let from = fromPopup.selectedItem?.representedObject as? String ?? "USD"
        guard !CurrencyRates.rates.isEmpty else { infoLabel.stringValue = "Loading exchange rates…"; return }
        let updated = CurrencyRates.lastUpdated.map { Self.relative($0) } ?? "just now"
        infoLabel.stringValue = "Live rates · base USD · updated \(updated) · right-click to pin/hide · double-click to copy"
        for code in currencyList() {
            let v = CurrencyRates.convert(amount, from: from, to: code)          // amount FROM → CODE
            let inv = CurrencyRates.convert(amount, from: code, to: from)        // amount CODE → FROM
            let info = Self.currencyInfo[code]
            rows.append(Row(name: code, country: info?.country ?? "", continent: info?.continent ?? "",
                            value: v.map { fmt($0, currency: true) } ?? "—",
                            inverse: inv.map { fmt($0, currency: true) } ?? "—",
                            isSource: code == from, code: code))
        }
    }

    private func unitRecompute() {
        let amount = Double(amountField.stringValue.replacingOccurrences(of: ",", with: "")) ?? 0
        let cat = UnitCatalog.categories[categoryIndex - 2]
        infoLabel.stringValue = "\(cat.name) · double-click a row to copy the value"
        guard fromPopup.indexOfSelectedItem >= 0 else { return }
        let fromUnit = cat.entries[fromPopup.indexOfSelectedItem].unit
        for e in cat.entries {
            let v = Measurement(value: amount, unit: fromUnit).converted(to: e.unit).value
            rows.append(Row(name: e.name, country: "", continent: "",
                            value: "\(fmt(v, currency: false)) \(e.unit.symbol)", inverse: "",
                            isSource: e.name == fromPopup.titleOfSelectedItem, code: ""))
        }
    }

    private func fmt(_ v: Double, currency: Bool) -> String {
        guard v.isFinite else { return "—" }
        let f = NumberFormatter()
        f.numberStyle = .decimal; f.usesGroupingSeparator = true
        let dp = currency ? Settings.shared.currencyDecimals : 6
        f.maximumFractionDigits = dp
        f.minimumFractionDigits = currency ? dp : 0
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
    private static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    @objc private func copyRow() {
        let r = table.selectedRow
        guard r >= 0, r < rows.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rows[r].value, forType: .string)
    }

    // MARK: Right-click pin / hide (currency)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard isCurrency else { return }
        let clicked = table.clickedRow
        let sel = table.selectedRowIndexes
        if sel.count > 1, sel.contains(clicked) {
            // Bulk-hide the multi-selection.
            let item = menu.addItem(withTitle: "Hide \(sel.count) currencies", action: #selector(hideSelected), keyEquivalent: "")
            item.target = self
        } else if clicked >= 0, clicked < rows.count {
            let code = rows[clicked].code
            let isFav = Settings.shared.currencyFavorites.contains(code)
            add(menu, isFav ? "Unpin \(code)" : "Pin \(code) to top", #selector(togglePin(_:)), code)
            add(menu, "Hide \(code)", #selector(hideCurrency(_:)), code)
        }
        let hidden = Settings.shared.currencyHidden
        if !hidden.isEmpty {
            menu.addItem(.separator())
            let parent = menu.addItem(withTitle: "Show Hidden Currency", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for code in hidden.sorted() { add(sub, code, #selector(unhideCurrency(_:)), code) }
            sub.addItem(.separator())
            add(sub, "Show All", #selector(unhideAll(_:)), "")
            menu.setSubmenu(sub, for: parent)
        }
    }
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ code: String) {
        let it = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        it.target = self; it.representedObject = code
    }
    @objc private func togglePin(_ s: NSMenuItem) {
        guard let code = s.representedObject as? String else { return }
        if let i = Settings.shared.currencyFavorites.firstIndex(of: code) { Settings.shared.currencyFavorites.remove(at: i) }
        else { Settings.shared.currencyFavorites.append(code); Settings.shared.currencyHidden.removeAll { $0 == code } }
        persistAndRefresh()
    }
    @objc private func hideCurrency(_ s: NSMenuItem) {
        guard let code = s.representedObject as? String else { return }
        if !Settings.shared.currencyHidden.contains(code) { Settings.shared.currencyHidden.append(code) }
        Settings.shared.currencyFavorites.removeAll { $0 == code }
        persistAndRefresh()
    }
    @objc private func unhideCurrency(_ s: NSMenuItem) {
        guard let code = s.representedObject as? String else { return }
        Settings.shared.currencyHidden.removeAll { $0 == code }; persistAndRefresh()
    }
    @objc private func unhideAll(_ s: NSMenuItem) { Settings.shared.currencyHidden.removeAll(); persistAndRefresh() }
    private func persistAndRefresh() { Settings.shared.save(); rebuildFromPopup(preservingSelection: true); recompute() }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let id = col?.identifier.rawValue ?? "unit"
        let text: String
        switch id {
        case "value": text = r.value
        case "inverse": text = r.inverse
        case "country": text = r.country
        case "continent": text = r.continent
        default: text = r.name
        }
        let mono = (id == "value" || id == "inverse")
        let field = NSTextField(labelWithString: text)
        field.font = mono
            ? .monospacedDigitSystemFont(ofSize: 13, weight: r.isSource ? .semibold : .regular)
            : .systemFont(ofSize: 13, weight: r.isSource ? .semibold : .regular)
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
