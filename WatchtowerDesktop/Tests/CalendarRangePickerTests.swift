import XCTest
@testable import WatchtowerDesktop

final class CalendarRangePickerTests: XCTestCase {
    /// Fixed calendar so the grid math is asserted against known months, not
    /// the machine's locale.
    private func gregorian(firstWeekday: Int) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = firstWeekday
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testGridDaysLeadingOffsetMondayFirst() {
        let cal = gregorian(firstWeekday: 2) // Monday
        // August 2026 starts on a Saturday → 5 leading blanks under a
        // Monday-first week, 31 days total.
        let cells = CalendarRangePicker.gridDays(month: date(2026, 8, 15, calendar: cal), calendar: cal)
        XCTAssertEqual(cells.count, 5 + 31)
        XCTAssertEqual(cells.prefix(5).compactMap { $0 }.count, 0)
        XCTAssertEqual(cal.component(.day, from: cells[5]!), 1)
        XCTAssertEqual(cal.component(.day, from: cells.last!!), 31)
    }

    func testGridDaysLeadingOffsetSundayFirst() {
        let cal = gregorian(firstWeekday: 1) // Sunday
        // February 2026 starts on a Sunday → zero leading blanks, 28 days.
        let cells = CalendarRangePicker.gridDays(month: date(2026, 2, 10, calendar: cal), calendar: cal)
        XCTAssertEqual(cells.count, 28)
        XCTAssertEqual(cal.component(.day, from: cells.first!!), 1)
    }

    func testOrderedWeekdaySymbolsRotateToFirstWeekday() {
        let sunday = gregorian(firstWeekday: 1)
        let monday = gregorian(firstWeekday: 2)
        let sundaySymbols = CalendarRangePicker.orderedWeekdaySymbols(calendar: sunday)
        let mondaySymbols = CalendarRangePicker.orderedWeekdaySymbols(calendar: monday)
        XCTAssertEqual(sundaySymbols.count, 7)
        // Monday-first is Sunday-first rotated by one.
        XCTAssertEqual(mondaySymbols, Array(sundaySymbols[1...] + sundaySymbols[..<1]))
    }

    func testNormalizedAnchorsPastDayToNoon() {
        let cal = gregorian(firstWeekday: 2)
        let day = date(2026, 8, 3, calendar: cal)
        let normalized = CalendarRangePicker.normalized(day, calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: normalized), 12)
        XCTAssertTrue(cal.isDate(normalized, inSameDayAs: day))
    }

    func testNormalizedClampsTodayToNow() {
        // Degenerate-but-valid input: today, when noon may still be ahead.
        let normalized = CalendarRangePicker.normalized(Date(), calendar: .current)
        XCTAssertLessThanOrEqual(normalized, Date())
    }

    func testMonthStart() {
        let cal = gregorian(firstWeekday: 2)
        let start = CalendarRangePicker.monthStart(of: date(2026, 8, 21, calendar: cal), calendar: cal)
        XCTAssertEqual(start, date(2026, 8, 1, calendar: cal))
    }
}
