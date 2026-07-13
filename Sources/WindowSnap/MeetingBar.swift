import Cocoa
import EventKit

/// Surfaces your next calendar meeting in the menu-bar menu, with a one-click
/// Join for Zoom / Google Meet / Microsoft Teams / Webex links. Opt-in (needs
/// Calendar permission), so it stays dormant until enabled in Settings.
final class MeetingBar {
    static let shared = MeetingBar()

    private let store = EKEventStore()
    private(set) var authorized = false

    struct Meeting {
        let title: String
        let start: Date
        let joinURL: URL?
    }

    /// Request Calendar access if the feature is enabled. Safe to call repeatedly.
    func requestAccessIfEnabled() {
        guard Settings.shared.meetingBarEnabled else { return }
        let handler: (Bool, Error?) -> Void = { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.authorized = granted
                if !granted { Logger.log("Meeting bar: calendar access denied") }
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: handler)
        } else {
            store.requestAccess(to: .event, completion: handler)
        }
    }

    /// The next timed event that hasn't ended, within the next 12 hours.
    func nextMeeting() -> Meeting? {
        guard Settings.shared.meetingBarEnabled, authorized else { return nil }
        let now = Date()
        let cals = store.calendars(for: .event)
        guard !cals.isEmpty else { return nil }
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-300),
                                            end: now.addingTimeInterval(12 * 3600),
                                            calendars: cals)
        let next = store.events(matching: pred)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .first
        guard let ev = next else { return nil }
        return Meeting(title: ev.title ?? "Untitled", start: ev.startDate, joinURL: Self.joinURL(for: ev))
    }

    /// Extract a known video-conferencing link from the event's url/location/notes.
    static func joinURL(for ev: EKEvent) -> URL? {
        let haystack = [ev.url?.absoluteString, ev.location, ev.notes]
            .compactMap { $0 }.joined(separator: "\n")
        let patterns = [
            "https://[a-zA-Z0-9.-]*zoom\\.us/[^\\s\"'<>]+",
            "https://meet\\.google\\.com/[^\\s\"'<>]+",
            "https://teams\\.microsoft\\.com/[^\\s\"'<>]+",
            "https://[a-zA-Z0-9.-]*webex\\.com/[^\\s\"'<>]+",
        ]
        for p in patterns {
            if let r = haystack.range(of: p, options: .regularExpression) {
                return URL(string: String(haystack[r]))
            }
        }
        return ev.url
    }
}
