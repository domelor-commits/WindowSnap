import Foundation

/// A lightweight, persistent activity log. Records layout changes, restores,
/// overwrites, sleep/wake actions, etc. The Log tab reads from here.
enum Logger {
    private static let storeKey = "WindowSnapActivityLog"
    private static let maxEntries = 500
    private static let queue = DispatchQueue(label: "windowsnap.logger")

    struct Entry: Codable {
        let date: Date
        let message: String
    }

    /// Posted whenever a new entry is added, so the Log tab can refresh live.
    static let didLogNotification = Notification.Name("WindowSnapDidLog")

    static func log(_ message: String) {
        queue.sync {
            // Only the current day's activity is kept — prune older entries.
            var entries = loadRaw().filter { Calendar.current.isDateInToday($0.date) }
            entries.append(Entry(date: Date(), message: message))
            // Keep only the most recent maxEntries.
            if entries.count > maxEntries {
                entries.removeFirst(entries.count - maxEntries)
            }
            if let data = try? JSONEncoder().encode(entries) {
                UserDefaults.standard.set(data, forKey: storeKey)
                // Force a synchronous flush. UserDefaults batches writes, which
                // can drop the most recent entry if the Mac suspends right after
                // a sleep-time log call. synchronize() forces it to disk now.
                UserDefaults.standard.synchronize()
            }
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didLogNotification, object: nil)
        }
    }

    static func entries() -> [Entry] {
        queue.sync { loadRaw().filter { Calendar.current.isDateInToday($0.date) } }
    }

    static func clear() {
        queue.sync { UserDefaults.standard.removeObject(forKey: storeKey) }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didLogNotification, object: nil)
        }
    }

    private static func loadRaw() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    /// Formatted "d MMM, HH:mm  message" lines (short, no seconds), newest FIRST.
    static func formattedLines() -> [String] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "d MMM, HH:mm"
        return entries().reversed().map { "\(fmt.string(from: $0.date))   \($0.message)" }
    }
}
