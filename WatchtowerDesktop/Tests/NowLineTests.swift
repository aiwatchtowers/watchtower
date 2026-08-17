import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore

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
    private func makeCalendarEvent(id: String, startsIn: TimeInterval) -> CalendarEvent {
        let start = now.addingTimeInterval(startsIn)
        let row: Row = [
            "id": id,
            "start_time": Self.iso.string(from: start),
            "end_time": Self.iso.string(from: start.addingTimeInterval(1800))
        ]
        return CalendarEvent(row: row)
    }

    /// Meetings-list entry for an event starting `startsIn` seconds from now
    /// (the unified list's row unit — `NowLine.rows` inserts over these).
    private func makeEntry(id: String, startsIn: TimeInterval) -> MeetingListEntry {
        let event = makeCalendarEvent(id: id, startsIn: startsIn)
        return MeetingListEntry(
            kind: .event(event, recordings: []),
            id: .event(id),
            sortDate: event.startDate,
            recordingCount: 0
        )
    }

    private func rowIDs(_ rows: [NowLine.TodayRow]) -> [String] {
        rows.map { row in
            switch row {
            case .nowLine:
                return NowLine.nowLineID
            case .entry(let entry):
                guard case .event(let event, _) = entry.kind else { return "recording" }
                return event.id
            }
        }
    }

    // MARK: - nowLineIndex

    func testEmptyListInsertsAtZero() {
        XCTAssertEqual(NowLine.nowLineIndex(starts: [], now: now), 0)
    }

    func testAllStartsPastInsertsAfterLast() {
        let starts = [now.addingTimeInterval(-7200), now.addingTimeInterval(-3600)]
        XCTAssertEqual(NowLine.nowLineIndex(starts: starts, now: now), 2)
    }

    func testAllStartsFutureInsertsAtZero() {
        let starts = [now.addingTimeInterval(1800), now.addingTimeInterval(7200)]
        XCTAssertEqual(NowLine.nowLineIndex(starts: starts, now: now), 0)
    }

    func testOngoingMeetingStaysAboveLine() {
        // Started 30 min ago (still running) → above; the future one → below.
        let starts = [
            now.addingTimeInterval(-7200),
            now.addingTimeInterval(-1800),
            now.addingTimeInterval(3600)
        ]
        XCTAssertEqual(NowLine.nowLineIndex(starts: starts, now: now), 2)
    }

    func testStartExactlyAtNowCountsAsStarted() {
        let starts = [now, now.addingTimeInterval(3600)]
        XCTAssertEqual(NowLine.nowLineIndex(starts: starts, now: now), 1)
    }

    func testDistantPastFallbackCountsAsStarted() {
        // An unparseable start_time upstream becomes Date.distantPast — it
        // never itself becomes the insertion point.
        let starts = [Date.distantPast, now.addingTimeInterval(3600)]
        XCTAssertEqual(NowLine.nowLineIndex(starts: starts, now: now), 1)
    }

    // MARK: - rows

    func testRowsInsertsMarkerExactlyOnce() {
        let cases: [(entries: [MeetingListEntry], expectedIDs: [String])] = [
            // All future → marker at start.
            ([makeEntry(id: "a", startsIn: 1800), makeEntry(id: "b", startsIn: 3600)],
             [NowLine.nowLineID, "a", "b"]),
            // Past + future → marker in the middle.
            ([makeEntry(id: "past", startsIn: -3600), makeEntry(id: "future", startsIn: 3600)],
             ["past", NowLine.nowLineID, "future"]),
            // All past → marker at end.
            ([makeEntry(id: "a", startsIn: -7200), makeEntry(id: "b", startsIn: -3600)],
             ["a", "b", NowLine.nowLineID]),
            // Empty list → marker alone.
            ([], [NowLine.nowLineID])
        ]

        // Each expected sequence contains nowLineID exactly once, so the
        // exact-order assertion also pins the exactly-one-marker property.
        for (entries, expectedIDs) in cases {
            XCTAssertEqual(rowIDs(NowLine.rows(entries: entries, now: now)), expectedIDs)
        }
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

    func testJumpArrowSymbolMatchesDirection() {
        XCTAssertEqual(NowLine.Visibility.above.jumpArrowSymbol, "arrow.up")
        XCTAssertEqual(NowLine.Visibility.below.jumpArrowSymbol, "arrow.down")
        XCTAssertNil(NowLine.Visibility.visible.jumpArrowSymbol)
    }
}
