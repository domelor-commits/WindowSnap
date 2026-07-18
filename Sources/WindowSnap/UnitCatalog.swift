import Cocoa

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

