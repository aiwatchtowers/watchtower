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

    /// CalendarEvent has only init(row:) — build fixtures from a minimal
    /// dictionary Row (init defaults every other column), start relative to
    /// `now` (no hardcoded dates), end = start + 30 min.
    private func makeEvent(id: String, startsIn: TimeInterval) -> CalendarEvent {
        let start = now.addingTimeInterval(startsIn)
        let row: Row = [
            "id": id,
            "start_time": Self.iso.string(from: start),
            "end_time": Self.iso.string(from: start.addingTimeInterval(1800))
        ]
        return CalendarEvent(row: row)
    }

    /// Event whose `start_time` is not a parseable date — `startDate` falls
    /// back to `Date.distantPast`.
    private func makeMalformedEvent(id: String) -> CalendarEvent {
        let row: Row = [
            "id": id,
            "start_time": "not-a-date",
            "end_time": "not-a-date"
        ]
        return CalendarEvent(row: row)
    }

    private func rowIDs(_ rows: [NowLine.TodayRow]) -> [String] {
        rows.map(\.id)
    }

    // MARK: - nowLineIndex

    func testEmptyListInsertsAtZero() {
        XCTAssertEqual(NowLine.nowLineIndex(events: [], now: now), 0)
    }

    func testAllEventsPastInsertsAfterLast() {
        let events = [
            makeEvent(id: "a", startsIn: -7200),
            makeEvent(id: "b", startsIn: -3600)
        ]
        XCTAssertEqual(NowLine.nowLineIndex(events: events, now: now), 2)
    }

    func testAllEventsFutureInsertsAtZero() {
        let events = [
            makeEvent(id: "a", startsIn: 1800),
            makeEvent(id: "b", startsIn: 7200)
        ]
        XCTAssertEqual(NowLine.nowLineIndex(events: events, now: now), 0)
    }

    func testOngoingEventStaysAboveLine() {
        let events = [
            makeEvent(id: "past", startsIn: -7200),
            makeEvent(id: "ongoing", startsIn: -1800),
            makeEvent(id: "future", startsIn: 3600)
        ]
        XCTAssertEqual(NowLine.nowLineIndex(events: events, now: now), 2)
    }

    func testEventStartingExactlyAtNowCountsAsStarted() {
        let events = [
            makeEvent(id: "at-now", startsIn: 0),
            makeEvent(id: "future", startsIn: 3600)
        ]
        XCTAssertEqual(NowLine.nowLineIndex(events: events, now: now), 1)
    }

    // MARK: - rows

    func testRowsInsertsMarkerExactlyOnce() {
        let cases: [(events: [CalendarEvent], expectedIDs: [String])] = [
            // All future → marker at start.
            ([makeEvent(id: "a", startsIn: 1800), makeEvent(id: "b", startsIn: 3600)],
             [NowLine.nowLineID, "a", "b"]),
            // Past + future → marker in the middle.
            ([makeEvent(id: "past", startsIn: -3600), makeEvent(id: "future", startsIn: 3600)],
             ["past", NowLine.nowLineID, "future"]),
            // All past → marker at end.
            ([makeEvent(id: "a", startsIn: -7200), makeEvent(id: "b", startsIn: -3600)],
             ["a", "b", NowLine.nowLineID]),
            // Empty list → marker alone.
            ([], [NowLine.nowLineID])
        ]

        // Each expected sequence contains nowLineID exactly once, so the
        // exact-order assertion also pins the exactly-one-marker property.
        for (events, expectedIDs) in cases {
            XCTAssertEqual(rowIDs(NowLine.rows(events: events, now: now)), expectedIDs)
        }
    }

    func testMalformedStartTimeCountsAsStarted() {
        // startDate falls back to Date.distantPast on an unparseable
        // start_time, so the malformed event never itself becomes the
        // insertion point (here, seeded first, it renders above the line).
        let events = [
            makeMalformedEvent(id: "broken"),
            makeEvent(id: "future", startsIn: 3600)
        ]
        XCTAssertEqual(NowLine.nowLineIndex(events: events, now: now), 1)
        XCTAssertEqual(
            rowIDs(NowLine.rows(events: events, now: now)),
            ["broken", NowLine.nowLineID, "future"]
        )
    }

    // MARK: - visibility

    func testVisibilityNilFrameReturnsNil() {
        XCTAssertNil(NowLine.visibility(frame: nil, viewportHeight: 500))
    }

    func testVisibilityZeroViewportReturnsNil() {
        let frame = CGRect(x: 0, y: 100, width: 300, height: 20)
        XCTAssertNil(NowLine.visibility(frame: frame, viewportHeight: 0))
    }

    func testVisibilityAboveViewport() {
        // Fully scrolled off the top: maxY <= 0.
        let frame = CGRect(x: 0, y: -50, width: 300, height: 20)
        XCTAssertEqual(NowLine.visibility(frame: frame, viewportHeight: 500), .above)
        // Boundary: maxY exactly 0 still counts as above.
        let atTop = CGRect(x: 0, y: -20, width: 300, height: 20)
        XCTAssertEqual(NowLine.visibility(frame: atTop, viewportHeight: 500), .above)
    }

    func testVisibilityBelowViewport() {
        // Fully below the bottom edge: minY >= viewportHeight.
        let frame = CGRect(x: 0, y: 600, width: 300, height: 20)
        XCTAssertEqual(NowLine.visibility(frame: frame, viewportHeight: 500), .below)
        // Boundary: minY exactly at viewportHeight still counts as below.
        let atBottom = CGRect(x: 0, y: 500, width: 300, height: 20)
        XCTAssertEqual(NowLine.visibility(frame: atBottom, viewportHeight: 500), .below)
    }

    func testJumpArrowSymbolMatchesDirection() {
        XCTAssertEqual(NowLine.Visibility.above.jumpArrowSymbol, "arrow.up")
        XCTAssertEqual(NowLine.Visibility.below.jumpArrowSymbol, "arrow.down")
        XCTAssertNil(NowLine.Visibility.visible.jumpArrowSymbol)
    }

    func testVisibilityOnScreenFrames() {
        // Fully on-screen.
        let inside = CGRect(x: 0, y: 100, width: 300, height: 20)
        XCTAssertEqual(NowLine.visibility(frame: inside, viewportHeight: 500), .visible)
        // Straddling the top edge (maxY > 0, minY < 0).
        let straddlingTop = CGRect(x: 0, y: -10, width: 300, height: 20)
        XCTAssertEqual(NowLine.visibility(frame: straddlingTop, viewportHeight: 500), .visible)
        // Straddling the bottom edge (minY < viewportHeight < maxY).
        let straddlingBottom = CGRect(x: 0, y: 490, width: 300, height: 20)
        XCTAssertEqual(NowLine.visibility(frame: straddlingBottom, viewportHeight: 500), .visible)
    }
}
