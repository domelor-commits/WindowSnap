import Foundation

/// Evaluates a Command Palette query as arithmetic ("1920*0.6+10"), a unit
/// conversion ("10 km to miles", "72 f to c"), or a currency conversion
/// ("100 usd to sgd"). Returns a formatted result string, or nil if the query
/// isn't computable. All parsing is hand-rolled (no NSExpression) so malformed
/// input can never raise an uncatchable exception.
enum Calculator {

    static func evaluate(_ raw: String) -> String? {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return nil }
        if let c = conversion(q) { return c }
        if let m = arithmetic(q) { return m }
        return nil
    }

    // MARK: Arithmetic

    private static func arithmetic(_ q: String) -> String? {
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/%^() ")
        guard q.rangeOfCharacter(from: allowed.inverted) == nil else { return nil }
        // Require at least one operator so a bare number isn't shown as a result.
        guard q.rangeOfCharacter(from: CharacterSet(charactersIn: "+*/%^")) != nil
            || q.dropFirst().rangeOfCharacter(from: CharacterSet(charactersIn: "-")) != nil else { return nil }
        var p = ExprEval(q)
        guard let v = p.parse(), v.isFinite else { return nil }
        return format(v)
    }

    // MARK: Conversions

    private static func conversion(_ q: String) -> String? {
        let lower = q.lowercased()
        var parts: [String]?
        for sep in [" to ", " in ", " as "] where lower.contains(sep) {
            parts = lower.components(separatedBy: sep); break
        }
        guard let p = parts, p.count == 2 else { return nil }
        guard let (amount, fromUnit) = splitNumberUnit(p[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let toUnit = p[1].trimmingCharacters(in: .whitespaces)

        // Currency (3-letter codes, live rates).
        if fromUnit.count == 3, toUnit.count == 3,
           let v = CurrencyRates.convert(amount, from: fromUnit, to: toUnit) {
            return "\(format(v)) \(toUnit.uppercased())"
        }
        // Physical units (offline, via Foundation Measurement).
        guard let (fromDim, cat1) = unitTable[fromUnit],
              let (toDim, cat2) = unitTable[toUnit], cat1 == cat2 else { return nil }
        let result = Measurement(value: amount, unit: fromDim).converted(to: toDim)
        return "\(format(result.value)) \(toDim.symbol)"
    }

    /// Split "10.5 km" into (10.5, "km").
    private static func splitNumberUnit(_ s: String) -> (Double, String)? {
        let cleaned = s.replacingOccurrences(of: ",", with: "")
        guard let r = cleaned.range(of: "^[0-9]*\\.?[0-9]+", options: .regularExpression) else { return nil }
        guard let n = Double(cleaned[r]) else { return nil }
        let unit = cleaned[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return (n, unit)
    }

    // MARK: Formatting

    private static func format(_ v: Double) -> String {
        if v.rounded() == v, abs(v) < 1e15 {
            return NumberFormatter.localizedString(from: NSNumber(value: Int(v)), number: .decimal)
        }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 6
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    // MARK: Unit table

    private static let unitTable: [String: (Dimension, String)] = {
        var t: [String: (Dimension, String)] = [:]
        func reg(_ dim: Dimension, _ cat: String, _ names: [String]) { for n in names { t[n] = (dim, cat) } }
        reg(UnitLength.meters, "length", ["m", "meter", "meters", "metre", "metres"])
        reg(UnitLength.kilometers, "length", ["km", "kilometer", "kilometers", "kilometre", "kilometres"])
        reg(UnitLength.centimeters, "length", ["cm", "centimeter", "centimeters"])
        reg(UnitLength.millimeters, "length", ["mm", "millimeter", "millimeters"])
        reg(UnitLength.inches, "length", ["in", "inch", "inches"])
        reg(UnitLength.feet, "length", ["ft", "foot", "feet"])
        reg(UnitLength.yards, "length", ["yd", "yard", "yards"])
        reg(UnitLength.miles, "length", ["mi", "mile", "miles"])
        reg(UnitMass.kilograms, "mass", ["kg", "kilo", "kilos", "kilogram", "kilograms"])
        reg(UnitMass.grams, "mass", ["g", "gram", "grams"])
        reg(UnitMass.milligrams, "mass", ["mg", "milligram", "milligrams"])
        reg(UnitMass.pounds, "mass", ["lb", "lbs", "pound", "pounds"])
        reg(UnitMass.ounces, "mass", ["oz", "ounce", "ounces"])
        reg(UnitMass.stones, "mass", ["st", "stone", "stones"])
        reg(UnitTemperature.celsius, "temp", ["c", "celsius", "centigrade"])
        reg(UnitTemperature.fahrenheit, "temp", ["f", "fahrenheit"])
        reg(UnitTemperature.kelvin, "temp", ["k", "kelvin"])
        reg(UnitVolume.liters, "volume", ["l", "liter", "liters", "litre", "litres"])
        reg(UnitVolume.milliliters, "volume", ["ml", "milliliter", "milliliters"])
        reg(UnitVolume.gallons, "volume", ["gal", "gallon", "gallons"])
        reg(UnitVolume.quarts, "volume", ["qt", "quart", "quarts"])
        reg(UnitVolume.pints, "volume", ["pt", "pint", "pints"])
        reg(UnitVolume.cups, "volume", ["cup", "cups"])
        reg(UnitInformationStorage.bytes, "data", ["byte", "bytes"])
        reg(UnitInformationStorage.kilobytes, "data", ["kb", "kilobyte", "kilobytes"])
        reg(UnitInformationStorage.megabytes, "data", ["mb", "megabyte", "megabytes"])
        reg(UnitInformationStorage.gigabytes, "data", ["gb", "gigabyte", "gigabytes"])
        reg(UnitInformationStorage.terabytes, "data", ["tb", "terabyte", "terabytes"])
        reg(UnitSpeed.kilometersPerHour, "speed", ["kmh", "kph"])
        reg(UnitSpeed.milesPerHour, "speed", ["mph"])
        reg(UnitSpeed.metersPerSecond, "speed", ["mps"])
        reg(UnitSpeed.knots, "speed", ["kn", "knot", "knots"])
        reg(UnitDuration.seconds, "time", ["sec", "secs", "second", "seconds"])
        reg(UnitDuration.minutes, "time", ["min", "mins", "minute", "minutes"])
        reg(UnitDuration.hours, "time", ["hr", "hrs", "hour", "hours"])
        reg(UnitAngle.degrees, "angle", ["deg", "degree", "degrees"])
        reg(UnitAngle.radians, "angle", ["rad", "radian", "radians"])
        return t
    }()
}

/// Tiny recursive-descent arithmetic evaluator (+ - * / % ^, parentheses, unary
/// minus). Returns nil on any parse error — never throws.
private struct ExprEval {
    private let s: [Character]
    private var i = 0
    init(_ str: String) { s = Array(str.replacingOccurrences(of: " ", with: "")) }

    mutating func parse() -> Double? {
        guard let v = expr() else { return nil }
        return i == s.count ? v : nil     // must consume the whole string
    }
    private mutating func expr() -> Double? {
        guard var v = term() else { return nil }
        while i < s.count, s[i] == "+" || s[i] == "-" {
            let op = s[i]; i += 1
            guard let r = term() else { return nil }
            v = (op == "+") ? v + r : v - r
        }
        return v
    }
    private mutating func term() -> Double? {
        guard var v = power() else { return nil }
        while i < s.count, s[i] == "*" || s[i] == "/" || s[i] == "%" {
            let op = s[i]; i += 1
            guard let r = power() else { return nil }
            if op == "*" { v *= r }
            else if op == "/" { if r == 0 { return nil }; v /= r }
            else { if r == 0 { return nil }; v = v.truncatingRemainder(dividingBy: r) }
        }
        return v
    }
    private mutating func power() -> Double? {
        guard let base = unary() else { return nil }
        if i < s.count, s[i] == "^" {
            i += 1
            guard let e = power() else { return nil }   // right-associative
            return pow(base, e)
        }
        return base
    }
    private mutating func unary() -> Double? {
        if i < s.count, s[i] == "-" { i += 1; return unary().map { -$0 } }
        if i < s.count, s[i] == "+" { i += 1; return unary() }
        return primary()
    }
    private mutating func primary() -> Double? {
        if i < s.count, s[i] == "(" {
            i += 1
            guard let v = expr(), i < s.count, s[i] == ")" else { return nil }
            i += 1
            return v
        }
        var str = ""
        while i < s.count, s[i].isNumber || s[i] == "." { str.append(s[i]); i += 1 }
        return Double(str)
    }
}

/// Live currency rates (base USD) from a free, key-less endpoint. Fetched when
/// the palette opens and cached for a few hours; conversions read the cache
/// synchronously, so currency results only appear once rates have loaded.
enum CurrencyRates {
    private(set) static var rates: [String: Double] = [:]     // code → units per 1 USD
    private(set) static var lastUpdated: Date?

    /// Posted on the main thread whenever fresh rates arrive.
    static let didUpdate = Notification.Name("windowSnapCurrencyRatesUpdated")

    /// All available currency codes, sorted.
    static var codes: [String] { rates.keys.sorted() }

    static func prefetch(force: Bool = false) {
        if !force, let last = lastUpdated, Date().timeIntervalSince(last) < 6 * 3600, !rates.isEmpty { return }
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let r = obj["rates"] as? [String: Double] else { return }
            DispatchQueue.main.async {
                rates = r; lastUpdated = Date()
                NotificationCenter.default.post(name: didUpdate, object: nil)
            }
        }.resume()
    }

    static func convert(_ amount: Double, from: String, to: String) -> Double? {
        guard let rf = rates[from.uppercased()], let rt = rates[to.uppercased()], rf != 0 else { return nil }
        return amount / rf * rt
    }
}
