import XCTest
@testable import WatchtowerDesktop

final class CalendarRangePickerTests: XCTestCase {
    /// Fixed calendar so the grid math is asserted against known months, not
    /// the machine's locale.
    private func gregorian(firstWeekday: Int) throws -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = firstWeekday
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: y, month: m, day: d)))
    }

    func testGridDaysLeadingOffsetMondayFirst() throws {
        let cal = try gregorian(firstWeekday: 2) // Monday
        // August 2026 starts on a Saturday → 5 leading blanks under a
        // Monday-first week, 31 days total.
        let cells = CalendarRangePicker.gridDays(month: try date(2026, 8, 15, calendar: cal), calendar: cal)
        XCTAssertEqual(cells.count, 5 + 31)
        XCTAssertEqual(cells.prefix(5).compactMap { $0 }.count, 0)
        let firstDay = try XCTUnwrap(cells[5])
        let lastDay = try XCTUnwrap(try XCTUnwrap(cells.last))
        XCTAssertEqual(cal.component(.day, from: firstDay), 1)
        XCTAssertEqual(cal.component(.day, from: lastDay), 31)
    }

    func testGridDaysLeadingOffsetSundayFirst() throws {
        let cal = try gregorian(firstWeekday: 1) // Sunday
        // February 2026 starts on a Sunday → zero leading blanks, 28 days.
        let cells = CalendarRangePicker.gridDays(month: try date(2026, 2, 10, calendar: cal), calendar: cal)
        XCTAssertEqual(cells.count, 28)
        let firstDay = try XCTUnwrap(try XCTUnwrap(cells.first))
        XCTAssertEqual(cal.component(.day, from: firstDay), 1)
    }

    func testOrderedWeekdaySymbolsRotateToFirstWeekday() throws {
        let sunday = try gregorian(firstWeekday: 1)
        let monday = try gregorian(firstWeekday: 2)
        let sundaySymbols = CalendarRangePicker.orderedWeekdaySymbols(calendar: sunday)
        let mondaySymbols = CalendarRangePicker.orderedWeekdaySymbols(calendar: monday)
        XCTAssertEqual(sundaySymbols.count, 7)
        // Monday-first is Sunday-first rotated by one.
        XCTAssertEqual(mondaySymbols, Array(sundaySymbols[1...] + sundaySymbols[..<1]))
    }

    func testNormalizedAnchorsPastDayToNoon() throws {
        let cal = try gregorian(firstWeekday: 2)
        let day = try date(2026, 8, 3, calendar: cal)
        let normalized = CalendarRangePicker.normalized(day, calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: normalized), 12)
        XCTAssertTrue(cal.isDate(normalized, inSameDayAs: day))
    }

    /// Today picked before local noon must still anchor to noon — clamping
    /// to now would roll the UTC-formatted day backwards in positive-offset
    /// zones (the formatter is UTC-pinned and day-granular, so a same-day
    /// instant a few hours ahead of now is harmless).
    func testNormalizedAnchorsTodayToNoonEvenBeforeNoon() {
        let cal = Calendar.current
        let normalized = CalendarRangePicker.normalized(Date(), calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: normalized), 12)
        XCTAssertTrue(cal.isDate(normalized, inSameDayAs: Date()))
    }

    func testCommitRangeOrdersEitherClickOrder() throws {
        let cal = try gregorian(firstWeekday: 2)
        let early = try date(2026, 8, 3, calendar: cal)
        let late = try date(2026, 8, 9, calendar: cal)
        let forward = CalendarRangePicker.commitRange(anchor: early, day: late, calendar: cal)
        let reverse = CalendarRangePicker.commitRange(anchor: late, day: early, calendar: cal)
        XCTAssertEqual(forward.from, reverse.from)
        XCTAssertEqual(forward.to, reverse.to)
        XCTAssertTrue(cal.isDate(forward.from, inSameDayAs: early))
        XCTAssertTrue(cal.isDate(forward.to, inSameDayAs: late))
        XCTAssertLessThanOrEqual(forward.from, forward.to)
    }

    func testCommitRangeSingleDayPick() throws {
        // Degenerate-but-valid: both clicks on the same day → a one-day range.
        let cal = try gregorian(firstWeekday: 2)
        let day = try date(2026, 8, 5, calendar: cal)
        let range = CalendarRangePicker.commitRange(anchor: day, day: day, calendar: cal)
        XCTAssertEqual(range.from, range.to)
    }

    func testMonthSnapStaysWhenAnEndpointIsVisible() throws {
        let cal = try gregorian(firstWeekday: 2)
        let displayed = try date(2026, 8, 1, calendar: cal)
        // to-endpoint in the displayed month → no jump.
        XCTAssertNil(CalendarRangePicker.monthSnap(
            displayed: displayed,
            from: try date(2026, 7, 10, calendar: cal),
            to: try date(2026, 8, 9, calendar: cal),
            calendar: cal))
    }

    func testMonthSnapJumpsToRangeEndWhenBothEndpointsOffScreen() throws {
        let cal = try gregorian(firstWeekday: 2)
        let displayed = try date(2026, 4, 1, calendar: cal)
        let snapped = CalendarRangePicker.monthSnap(
            displayed: displayed,
            from: try date(2026, 7, 10, calendar: cal),
            to: try date(2026, 8, 9, calendar: cal),
            calendar: cal)
        XCTAssertEqual(snapped, try date(2026, 8, 1, calendar: cal))
    }

    func testMonthStart() throws {
        let cal = try gregorian(firstWeekday: 2)
        let start = CalendarRangePicker.monthStart(of: try date(2026, 8, 21, calendar: cal), calendar: cal)
        XCTAssertEqual(start, try date(2026, 8, 1, calendar: cal))
    }
}
