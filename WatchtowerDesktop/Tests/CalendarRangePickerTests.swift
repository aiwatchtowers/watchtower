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

    func testNormalizedClampsTodayToNow() {
        // Degenerate-but-valid input: today, when noon may still be ahead.
        let normalized = CalendarRangePicker.normalized(Date(), calendar: .current)
        XCTAssertLessThanOrEqual(normalized, Date())
    }

    func testMonthStart() throws {
        let cal = try gregorian(firstWeekday: 2)
        let start = CalendarRangePicker.monthStart(of: try date(2026, 8, 21, calendar: cal), calendar: cal)
        XCTAssertEqual(start, try date(2026, 8, 1, calendar: cal))
    }
}
