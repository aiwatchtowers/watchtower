import XCTest
@testable import WatchtowerDesktop

/// Logic-level tests for `CalendarEventsView`'s pure static helpers (the
/// `MeetingDetailViewTests` pattern) rather than mounting the view.
final class CalendarEventsViewTests: XCTestCase {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? cal.timeZone
        return cal
    }()

    /// All fixture dates derive from a fixed now — never hardcoded calendar
    /// dates that age into test bombs.
    private let now = Date()

    private func day(_ offset: Int, from start: Date) throws -> Date {
        try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: start))
    }

    private func section(_ id: Date) -> MeetingDaySection {
        MeetingDaySection(id: id, label: "day", entries: [])
    }

    // MARK: - todayScrollTarget

    /// The habitual case: history above, Today present — land on Today.
    func test_todayScrollTarget_picksTodaySection() throws {
        let today = calendar.startOfDay(for: now)
        let sections = [
            section(try day(-2, from: today)), section(try day(-1, from: today)),
            section(today), section(try day(1, from: today))
        ]
        XCTAssertEqual(CalendarEventsView.todayScrollTarget(in: sections, today: today), today)
    }

    /// No entries today → the first future day is the landing target.
    func test_todayScrollTarget_fallsForwardToFirstFutureDay() throws {
        let today = calendar.startOfDay(for: now)
        let plus2 = try day(2, from: today)
        let sections = [section(try day(-1, from: today)), section(plus2), section(try day(3, from: today))]
        XCTAssertEqual(CalendarEventsView.todayScrollTarget(in: sections, today: today), plus2)
    }

    /// History-only window (weekend open: zero events today..ahead, nothing
    /// recorded today): the target is the LAST — most recent — past section,
    /// never a silent bail that leaves the list resting on the oldest day.
    func test_todayScrollTarget_historyOnlyLandsOnMostRecentPastDay() throws {
        let today = calendar.startOfDay(for: now)
        let minus1 = try day(-1, from: today)
        let sections = [section(try day(-3, from: today)), section(try day(-2, from: today)), section(minus1)]
        XCTAssertEqual(CalendarEventsView.todayScrollTarget(in: sections, today: today), minus1)
    }

    /// Nothing to scroll to at all.
    func test_todayScrollTarget_nilForEmptySections() {
        XCTAssertNil(CalendarEventsView.todayScrollTarget(in: [], today: calendar.startOfDay(for: now)))
    }

    // MARK: - initialScrollTarget (the one-shot landing decision)

    /// Today present → the landing is the now-line marker, not the day top
    /// (`NowLine.rows` always inserts the marker in a today section, even
    /// with zero timed entries).
    func test_initialScrollTarget_todayPresentLandsOnNowLine() throws {
        let today = calendar.startOfDay(for: now)
        let sections = [
            section(try day(-1, from: today)), section(today), section(try day(1, from: today))
        ]
        XCTAssertEqual(CalendarEventsView.initialScrollTarget(in: sections, today: today), .nowLine)
    }

    /// No today section → the `todayScrollTarget` fallback day, top-anchored.
    func test_initialScrollTarget_fallsBackToFirstFutureDay() throws {
        let today = calendar.startOfDay(for: now)
        let plus2 = try day(2, from: today)
        let sections = [section(try day(-1, from: today)), section(plus2)]
        XCTAssertEqual(CalendarEventsView.initialScrollTarget(in: sections, today: today), .day(plus2))
    }

    /// History-only window → the most recent past day, same as the fallback.
    func test_initialScrollTarget_historyOnlyLandsOnMostRecentPastDay() throws {
        let today = calendar.startOfDay(for: now)
        let minus1 = try day(-1, from: today)
        let sections = [section(try day(-2, from: today)), section(minus1)]
        XCTAssertEqual(CalendarEventsView.initialScrollTarget(in: sections, today: today), .day(minus1))
    }

    func test_initialScrollTarget_nilForEmptySections() {
        XCTAssertNil(CalendarEventsView.initialScrollTarget(in: [], today: calendar.startOfDay(for: now)))
    }

    // MARK: - toggledSelection (row tap → select / deselect)

    func test_toggledSelection_selectsWhenNothingSelected() {
        XCTAssertEqual(
            CalendarEventsView.toggledSelection(current: nil, tapped: .event("e1")),
            .event("e1"))
    }

    func test_toggledSelection_switchesToAnotherRow() {
        XCTAssertEqual(
            CalendarEventsView.toggledSelection(current: .event("e1"), tapped: .recording(7)),
            .recording(7))
    }

    /// Tapping the already-selected row closes the detail pane.
    func test_toggledSelection_tapOnSelectedRowDeselects() {
        XCTAssertNil(CalendarEventsView.toggledSelection(current: .event("e1"), tapped: .event("e1")))
        XCTAssertNil(CalendarEventsView.toggledSelection(current: .recording(7), tapped: .recording(7)))
    }
}
