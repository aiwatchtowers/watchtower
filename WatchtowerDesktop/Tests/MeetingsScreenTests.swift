import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore

/// Pins `CalendarEventsView.entry(for:in:)` — the selection-resolution hinge
/// that replaced the deleted `RecordingsView.selectedID` external-binding
/// hinge once the unified Meetings screen collapsed `mode` +
/// `expandedEventID` + `selectedEventID` + `selectedRecordingID` into a
/// single `selectedMeeting: MeetingSelection?` resolved purely against the
/// built `sections` (no external binding concept survives the rewiring —
/// deep links now write `selectedMeeting` directly, see `openLinkedEvent`).
final class MeetingsScreenTests: XCTestCase {
    private func makeEventEntry(id: String, recordingCount: Int = 0) -> MeetingListEntry {
        let event = CalendarEvent(row: Row([
            "id": id,
            "calendar_id": "cal1",
            "title": "Event \(id)",
            "start_time": "2026-07-31T10:00:00Z",
            "end_time": "2026-07-31T10:30:00Z"
        ]))
        return MeetingListEntry(
            kind: .event(event, recordings: []), id: .event(id),
            sortDate: event.startDate, recordingCount: recordingCount)
    }

    private func makeRecordingEntry(id: Int64) -> MeetingListEntry {
        let item = RecordingListItem(
            id: id, eventID: nil, eventTitle: nil, title: "Rec \(id)", durationSec: 60,
            langStats: "{}", createdAt: "2026-07-31T10:00:00Z",
            hasRecap: false, hasNotes: false, snippet: "")
        return MeetingListEntry(
            kind: .recording(item), id: .recording(id),
            sortDate: item.createdDate ?? .distantPast, recordingCount: 1)
    }

    // MARK: - entry(for:in:) resolution

    func test_entryResolvesEventSelection() {
        let entry = makeEventEntry(id: "e1")
        let sections = [MeetingDaySection(id: Date(), label: "Today", entries: [entry])]

        XCTAssertEqual(CalendarEventsView.entry(for: .event("e1"), in: sections)?.id, .event("e1"))
    }

    func test_entryResolvesRecordingSelection() {
        let entry = makeRecordingEntry(id: 7)
        let sections = [MeetingDaySection(id: Date(), label: "Today", entries: [entry])]

        XCTAssertEqual(CalendarEventsView.entry(for: .recording(7), in: sections)?.id, .recording(7))
    }

    func test_entrySearchesAcrossMultipleSections() {
        let sections = [
            MeetingDaySection(
                id: Date(timeIntervalSince1970: 0), label: "A", entries: [makeEventEntry(id: "e1")]),
            MeetingDaySection(
                id: Date(timeIntervalSince1970: 86400), label: "B", entries: [makeRecordingEntry(id: 9)])
        ]

        XCTAssertEqual(CalendarEventsView.entry(for: .recording(9), in: sections)?.id, .recording(9))
        XCTAssertEqual(CalendarEventsView.entry(for: .event("e1"), in: sections)?.id, .event("e1"))
    }

    /// A stale deep-link/selection target (row scrolled out of the rebuilt
    /// window, or the recording was deleted) must resolve to nil rather than
    /// crash or return a stale entry — the detail pane then simply doesn't
    /// render (see `meetingsSplitView`'s `if let entry = ...` gate).
    func test_entryReturnsNilForUnknownSelection() {
        let sections = [MeetingDaySection(id: Date(), label: "Today", entries: [makeEventEntry(id: "e1")])]

        XCTAssertNil(CalendarEventsView.entry(for: .event("missing"), in: sections))
        XCTAssertNil(CalendarEventsView.entry(for: .recording(999), in: sections))
    }

    func test_entryReturnsNilForEmptySections() {
        XCTAssertNil(CalendarEventsView.entry(for: .event("e1"), in: []))
    }
}
