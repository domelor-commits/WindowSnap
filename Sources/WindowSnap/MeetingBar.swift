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

    /// The soonest timed event that hasn't ended, plus every other event that
    /// overlaps its time window — so the menu can offer a choice when invites
    /// collide. Looks 12 hours ahead; sorted by start time. Empty if none.
    func overlappingMeetings() -> [Meeting] {
        guard Settings.shared.meetingBarEnabled, authorized else { return [] }
        let now = Date()
        let cals = store.calendars(for: .event)
        guard !cals.isEmpty else { return [] }
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-300),
                                            end: now.addingTimeInterval(12 * 3600),
                                            calendars: cals)
        let events = store.events(matching: pred)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
        guard let first = events.first else { return [] }
        // Keep the soonest meeting and anything overlapping its window
        // (half-open interval so back-to-back meetings don't count as overlapping).
        return events
            .filter { $0.startDate < first.endDate && $0.endDate > first.startDate }
            .map { Meeting(title: $0.title ?? "Untitled", start: $0.startDate, joinURL: Self.joinURL(for: $0)) }
    }

    /// Convenience for callers that only want the single soonest meeting.
    func nextMeeting() -> Meeting? { overlappingMeetings().first }

    /// Extract a known video-conferencing link from the event's url/location/notes.
    static func joinURL(for ev: EKEvent) -> URL? {
        let haystack = [ev.url?.absoluteString, ev.location, ev.notes]
            .compactMap { $0 }.joined(separator: "\n")
        return joinURL(inText: haystack, fallback: ev.url)
    }

    /// Video-conferencing link patterns, in priority order. Exposed for testing.
    static let joinURLPatterns = [
        "https://[a-zA-Z0-9.-]*zoom\\.us/[^\\s\"'<>]+",
        "https://meet\\.google\\.com/[^\\s\"'<>]+",
        "https://teams\\.microsoft\\.com/[^\\s\"'<>]+",
        "https://[a-zA-Z0-9.-]*webex\\.com/[^\\s\"'<>]+",
    ]

    /// Pure core of `joinURL(for:)`: scan `text` for the first known meeting link,
    /// else return `fallback`. Split out so it can be unit-tested without EventKit.
    static func joinURL(inText text: String, fallback: URL? = nil) -> URL? {
        for p in joinURLPatterns {
            if let r = text.range(of: p, options: .regularExpression) {
                return URL(string: String(text[r]))
            }
        }
        return fallback
    }
}
