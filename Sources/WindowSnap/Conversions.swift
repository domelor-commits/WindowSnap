import Cocoa
import EventKit

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
    /// Asks for a title and duration first, then prefers Microsoft Outlook when
    /// it's installed (that's where most people's work calendar lives);
    /// otherwise falls back to the system Calendar.
    @objc private func createCalendarEvent() {
        let start = worldClock.selectedInstant
        let notes = worldClock.selectionSummary
        guard let (title, duration, target) = promptForEventDetails(start: start) else { return }
        switch target {
        case 1:  createOutlookAppEvent(title: title, start: start, duration: duration, notes: notes)
        case 2:  createOutlookWebEvent(title: title, start: start, duration: duration, notes: notes)
        default: createAppleCalendarEvent(title: title, start: start, duration: duration, notes: notes)
        }
    }

    /// Is Microsoft Outlook installed? Only then is it offered as a destination.
    private var outlookInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Outlook") != nil
    }

    /// Is Outlook running in "New Outlook" mode? New Outlook exposes no AppleScript
    /// automation, so the app-save path can't reach it — we only offer the "Outlook
    /// app" destination when classic (scriptable) Outlook is the active mode.
    ///
    /// The flag lives in Outlook's *sandbox container* preferences, not the normal
    /// domain, so `CFPreferencesCopyAppValue("…", "com.microsoft.Outlook")` returns
    /// nil — read the container plist directly instead.
    private var outlookIsNewMode: Bool {
        let path = ("~/Library/Containers/com.microsoft.Outlook/Data/Library/Preferences/com.microsoft.Outlook.plist" as NSString).expandingTildeInPath
        guard let dict = NSDictionary(contentsOfFile: path) else { return false }
        return (dict["IsRunningNewOutlook"] as? Bool) ?? false
    }

    /// True only when the installed Outlook can actually be scripted to save an
    /// event into the app (classic mode). Under New Outlook, use the web composer.
    private var outlookAppScriptable: Bool { outlookInstalled && !outlookIsNewMode }

    /// Small modal asking for the event's title, length and destination calendar.
    /// Destinations: Apple Calendar (always), the installed Outlook app (only when
    /// classic Outlook is present and scriptable), and Outlook on the web (always,
    /// since it works even under New Outlook). The last pick is remembered in
    /// Settings so events never silently land somewhere the user isn't looking.
    /// The `Int` returned is the destination code (see `Settings.eventTarget`).
    /// Returns nil on Cancel.
    private func promptForEventDetails(start: Date)
        -> (title: String, duration: TimeInterval, target: Int)? {
        let alert = NSAlert()
        alert.messageText = "New Calendar Event"
        let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.timeStyle = .short
        alert.informativeText = "Starts \(fmt.string(from: start))."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        // (label, destination code). The "Outlook app" option appears only when
        // classic Outlook is the active mode (New Outlook isn't scriptable); the
        // web composer is always available.
        var targets: [(label: String, code: Int)] = [("Add to: Apple Calendar", 0)]
        if outlookAppScriptable { targets.append(("Add to: Outlook app", 1)) }
        targets.append(("Add to: Outlook (web)", 2))

        let rowH: CGFloat = 30
        let boxH: CGFloat = rowH * 3
        // Rows are laid out top-down; y is measured from the bottom of the box.
        var y = boxH - 24

        let titleField = NSTextField(frame: NSRect(x: 0, y: y, width: 240, height: 24))
        titleField.placeholderString = "Event title"
        y -= rowH

        let durations: [(label: String, secs: TimeInterval)] = [
            ("15 minutes", 900), ("30 minutes", 1800), ("45 minutes", 2700),
            ("1 hour", 3600), ("1.5 hours", 5400), ("2 hours", 7200)]
        let durationPopup = NSPopUpButton(frame: NSRect(x: 0, y: y, width: 240, height: 26))
        durations.forEach { durationPopup.addItem(withTitle: $0.label) }
        durationPopup.selectItem(at: 3)   // 1 hour
        y -= rowH

        let targetPopup = NSPopUpButton(frame: NSRect(x: 0, y: y, width: 240, height: 26))
        targets.forEach { targetPopup.addItem(withTitle: $0.label) }
        // Preselect the remembered destination if it's currently available.
        if let idx = targets.firstIndex(where: { $0.code == Settings.shared.eventTarget }) {
            targetPopup.selectItem(at: idx)
        }

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: boxH))
        box.addSubview(titleField); box.addSubview(durationPopup); box.addSubview(targetPopup)
        alert.accessoryView = box
        alert.window.initialFirstResponder = titleField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespaces)
        let target = targets[max(0, targetPopup.indexOfSelectedItem)].code
        if target != Settings.shared.eventTarget {
            Settings.shared.eventTarget = target
            Settings.shared.save()
        }
        return (title.isEmpty ? "Event" : title,
                durations[max(0, durationPopup.indexOfSelectedItem)].secs,
                target)
    }

    /// Create the event in the **installed Outlook app** via AppleScript, in the
    /// calendar of the first configured mail account. Explicitly targeting an
    /// account-backed calendar matters: Outlook's *default* calendar is often the
    /// local "On My Computer" store, so an untargeted event silently lands
    /// somewhere that never syncs. Only classic Outlook is scriptable — under New
    /// Outlook there are no visible accounts, so we surface that and fall back to
    /// the web composer, which does work with New Outlook.
    ///
    /// The first call triggers a one-time Automation permission prompt.
    private func createOutlookAppEvent(title: String, start: Date, duration: TimeInterval, notes: String) {
        let end = start.addingTimeInterval(duration)
        let src = """
        \(appleScriptDate(from: start, varName: "s"))
        \(appleScriptDate(from: end, varName: "e"))
        tell application "Microsoft Outlook"
            -- Prefer the main "Calendar" of the first mail account; fall back to any
            -- of that account's calendars. Never the local "On My Computer" store.
            set targetCal to missing value
            set fallbackCal to missing value
            try
                set acct to item 1 of exchange accounts
                repeat with c in calendars
                    try
                        if account of c is acct then
                            set fallbackCal to c
                            if (name of c) is "Calendar" then set targetCal to c
                        end if
                    end try
                end repeat
            end try
            if targetCal is missing value then set targetCal to fallbackCal
            if targetCal is missing value then return "NO_ACCOUNT_CALENDAR"
            set newEvent to make new calendar event at targetCal with properties {subject:"\(appleScriptEscape(title))", start time:s, end time:e, content:"\(appleScriptEscape(notes))"}
            open newEvent
            activate
            return "OK"
        end tell
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if err != nil {
            Logger.log("Outlook app scripting failed; using Outlook web composer")
            LayoutManager.notify("Couldn’t reach the Outlook app",
                "Opening the event in Outlook on the web instead.")
            createOutlookWebEvent(title: title, start: start, duration: duration, notes: notes)
        } else if result?.stringValue == "NO_ACCOUNT_CALENDAR" {
            Logger.log("Outlook app has no account calendar (New Outlook?); using web composer")
            LayoutManager.notify("No Outlook account calendar in the app",
                "Opening the event in Outlook on the web instead.")
            createOutlookWebEvent(title: title, start: start, duration: duration, notes: notes)
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

    /// Create the event in Microsoft Outlook via the Outlook-on-the-web deep link
    /// composer. This is the only path that works with **New Outlook** for Mac,
    /// which — unlike classic Outlook — exposes no AppleScript automation at all.
    /// It opens a pre-filled event composer at outlook.office.com for whichever
    /// account you're signed into on the web; you review and save it there.
    /// Requires being signed into Outlook on the web.
    private func createOutlookWebEvent(title: String, start: Date, duration: TimeInterval, notes: String) {
        let end = start.addingTimeInterval(duration)
        // Office 365 deep link. Times are ISO-8601 with the local UTC offset so
        // the composer shows the same wall-clock time the user picked.
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        var comps = URLComponents(string: "https://outlook.office.com/calendar/deeplink/compose")
        comps?.queryItems = [
            URLQueryItem(name: "path", value: "/calendar/action/compose"),
            URLQueryItem(name: "rru", value: "addevent"),
            URLQueryItem(name: "subject", value: title),
            URLQueryItem(name: "startdt", value: iso.string(from: start)),
            URLQueryItem(name: "enddt", value: iso.string(from: end)),
            URLQueryItem(name: "body", value: notes),
        ]
        guard let url = comps?.url else {
            createAppleCalendarEvent(title: title, start: start, duration: duration, notes: notes)
            return
        }
        NSWorkspace.shared.open(url)
        LayoutManager.notify("Opening Outlook event",
            "Review and save the event in Outlook on the web.")
    }

    /// Create the event in the system Calendar via EventKit (the fallback path).
    private func createAppleCalendarEvent(title: String, start: Date, duration: TimeInterval, notes: String) {
        let make: (Bool) -> Void = { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard granted else {
                    LayoutManager.notify("Calendar access needed",
                        "Enable WindowSnap under System Settings → Privacy & Security → Calendars.")
                    return
                }
                let ev = EKEvent(eventStore: self.eventStore)
                ev.title = title
                ev.startDate = start
                ev.endDate = start.addingTimeInterval(duration)
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
