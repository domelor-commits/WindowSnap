import Testing
import Foundation
import CoreGraphics
@testable import WindowSnap

// Tests for the two pieces most likely to regress silently and hardest to spot
// by eye: the meeting-link extraction heuristic and the layout bookkeeping logic.

@Suite struct MeetingJoinURLTests {
    @Test func findsZoomLinkAnywhereInText() {
        let notes = "Agenda attached.\nJoin: https://acme.zoom.us/j/9876543210?pwd=abcDEF please be on time"
        #expect(MeetingBar.joinURL(inText: notes)?.absoluteString
                == "https://acme.zoom.us/j/9876543210?pwd=abcDEF")
    }

    @Test func recognizesEachProvider() {
        let cases = [
            "https://meet.google.com/abc-defg-hij",
            "https://teams.microsoft.com/l/meetup-join/xyz",
            "https://company.webex.com/meet/room",
            "https://us02web.zoom.us/j/123",
        ]
        for link in cases {
            #expect(MeetingBar.joinURL(inText: "please join \(link) now")?.absoluteString == link,
                    "should extract \(link)")
        }
    }

    @Test func stopsAtWhitespaceAndQuotes() {
        // The URL must not swallow the trailing word or the closing quote.
        #expect(MeetingBar.joinURL(inText: "\"https://x.zoom.us/j/1\" and more")?.absoluteString
                == "https://x.zoom.us/j/1")
    }

    @Test func fallsBackWhenNoKnownProvider() {
        let fallback = URL(string: "https://example.com/event")!
        #expect(MeetingBar.joinURL(inText: "no video link here", fallback: fallback) == fallback)
        #expect(MeetingBar.joinURL(inText: "nothing at all", fallback: nil) == nil)
    }

    @Test func prefersFirstProviderInPriorityOrder() {
        // Both a Zoom and a Meet link present; Zoom is first in the pattern list.
        let text = "primary https://a.zoom.us/j/1 backup https://meet.google.com/x-y-z"
        #expect(MeetingBar.joinURL(inText: text)?.absoluteString == "https://a.zoom.us/j/1")
    }
}

@Suite struct LayoutManagerLogicTests {
    private func snap(bundle: String, display: String) -> WindowSnapshot {
        WindowSnapshot(appName: bundle, appBundleID: bundle, pid: 1, cgWindowNumber: nil,
                       windowIndex: 0, windowTitle: "w", frame: CGRectCodable(.zero),
                       displayID: display)
    }
    private func display(_ id: String) -> DisplayInfo {
        DisplayInfo(id: id, name: id, frame: CGRectCodable(.zero), isPrimary: id == "A")
    }
    private func layout(displays: [String], windows: [(String, String)]) -> Layout {
        Layout(name: "L", displaySignature: "sig",
               displays: displays.map(display),
               windows: windows.map { snap(bundle: $0.0, display: $0.1) },
               savedAt: Date())
    }

    @Test func pinnedIdentification() {
        #expect(LayoutManager.isPinned(LayoutManager.defaultLayoutID))
        #expect(LayoutManager.isPinned(LayoutManager.presentationLayoutID))
        #expect(!LayoutManager.isPinned("some-random-uuid"))
        #expect(LayoutManager.pinnedName(for: LayoutManager.defaultLayoutID) == "Default")
        #expect(LayoutManager.pinnedName(for: "unknown") == "Layout")
    }

    @Test func autoSavedMatchesCurrentAndLegacyNames() {
        #expect(LayoutManager.isAutoSaved(layout(displays: ["A"], windows: []).with(name: "Saved")))
        #expect(LayoutManager.isAutoSaved(layout(displays: ["A"], windows: []).with(name: "Saved 2026-01-01 09:00")))
        #expect(!LayoutManager.isAutoSaved(layout(displays: ["A"], windows: []).with(name: "My Layout")))
    }

    @Test func windowsCoverAllDisplays() {
        // Both displays have a window → covered.
        let full = layout(displays: ["A", "B"], windows: [("com.a", "A"), ("com.b", "B")])
        #expect(LayoutManager.windowsCoverAllDisplays(full))
        // Display B has no window → not covered.
        let partial = layout(displays: ["A", "B"], windows: [("com.a", "A"), ("com.a", "A")])
        #expect(!LayoutManager.windowsCoverAllDisplays(partial))
        // No displays → not covered.
        #expect(!LayoutManager.windowsCoverAllDisplays(layout(displays: [], windows: [])))
    }
}

private extension Layout {
    func with(name: String) -> Layout { var c = self; c.name = name; return c }
}
