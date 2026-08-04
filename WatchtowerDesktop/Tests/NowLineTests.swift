import XCTest
import GRDB
@testable import WatchtowerDesktop

final class NowLineTests: XCTestCase {

    // MARK: - Helpers

    /// Second-aligned "now": CalendarEvent round-trips dates through ISO8601
    /// strings (no fractional seconds), so aligning `now` the same way makes
    /// the exactly-at-now boundary case exact instead of sub-second-off.
    private static let iso = ISO8601DateFormatter()
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    /// CalendarEvent has only init(row:) — build fixtures from a dictionary
    /// Row, with start/end relative to `now` (no hardcoded dates).
    private func makeEvent(id: String, startsIn: TimeInterval, endsIn: TimeInterval) -> CalendarEvent {
        let row: Row = [
            "id": id,
            "calendar_id": "cal1",
            "title": id,
            "description": "",
            "location": "",
            "start_time": Self.iso.string(from: now.addingTimeInterval(startsIn)),
            "end_time": Self.iso.string(from: now.addingTimeInterval(endsIn)),
            "organizer_email": "",
            "attendees": "[]",
            "is_recurring": 0,
            "is_all_day": 0,
            "event_status": "confirmed",
            "event_type": "",
            "html_link": "",
            "raw_json": "{}",
            "synced_at": "",
            "updated_at": ""
        ]
        return CalendarEvent(row: row)
    }

    // MARK: - Tests

    func testEmptyListInsertsAtZero() {
        XCTAssertEqual(NowLine.nowLineIndex(events: [], now: now), 0)
    }

    func testAllEventsPastInsertsAfterLast() {
        let events = [
            makeEvent(id: "a", startsIn: -7200, endsIn: -5400),
            makeEvent(id: "b", startsIn: -3600, endsIn: -1800)
        ]
        XCTAssertEqual(NowLine.nowLineIndex(events: events, now: now), 2)
    }

    func testAllEventsFutureInsertsAtZero() {
        let events = [
            makeEvent(id: "a", startsIn: 1800, endsIn: 3600),
            makeEvent(id: "b", startsIn: 7200, endsIn: 9000)
        ]
        XCTAssertEqual(NowLine.nowLineIndex(events: events, now: now), 0)
    }

    func testOngoingEventStaysAboveLine() {
        let events = [
            makeEvent(id: "past", startsIn: -7200, endsIn: -5400),
            makeEvent(id: "ongoing", startsIn: -1800, endsIn: 1800),
            makeEvent(id: "future", startsIn: 3600, endsIn: 5400)
        ]
        XCTAssertEqual(NowLine.nowLineIndex(events: events, now: now), 2)
    }

    func testEventStartingExactlyAtNowCountsAsStarted() {
        let events = [
            makeEvent(id: "at-now", startsIn: 0, endsIn: 1800),
            makeEvent(id: "future", startsIn: 3600, endsIn: 5400)
        ]
        XCTAssertEqual(NowLine.nowLineIndex(events: events, now: now), 1)
    }
}
