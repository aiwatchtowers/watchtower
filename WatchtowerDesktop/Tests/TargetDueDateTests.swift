import XCTest
import GRDB
@testable import WatchtowerDesktop

/// `targets.due_date` is stored as a UTC wall-time string ("YYYY-MM-DDTHH:MM"
/// or "YYYY-MM-DD") — the Go side writes `t.UTC()` and compares against
/// `now.UTC()` (cmd/remind.go, NotifyDueTargets). Swift must therefore parse
/// and format the stored string as UTC, never as local wall time, or due dates
/// drift by the machine's UTC offset between the two sides.
///
/// Date-only values ("YYYY-MM-DD") mean "due ON that day": the target is due
/// today when the stored day equals today's UTC day, and overdue only once the
/// UTC day has passed — never mid-day just because UTC midnight is behind us.
///
/// Assertions here are derived timezone-independently (UTC calendar components,
/// UTC day strings) so they fail on ANY machine zone if the UTC pin is dropped
/// — comparing against fixed Z instants alone would stay green on a UTC box.
final class TargetDueDateTests: XCTestCase {

    private let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone
        return cal
    }()

    /// "yyyy-MM-dd" in UTC — matches the stored date-only due-date format.
    private let utcDayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt
    }()

    /// Builds a detached Target with the given due date (never persisted).
    private func makeTarget(dueDate: String, status: String = "todo") -> Target {
        let row: Row = ["id": 1, "text": "t", "status": status, "due_date": dueDate]
        return Target(row: row)
    }

    // MARK: - Parsing (UTC pin)

    func testParseDueDate_DatetimeIsReadAsUTCInstant() throws {
        let parsed = try XCTUnwrap(Target.parseDueDate("2026-07-04T15:00"))

        // Machine-zone-independent: check the instant's UTC wall-clock fields.
        let comps = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: parsed)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 7)
        XCTAssertEqual(comps.day, 4)
        XCTAssertEqual(comps.hour, 15)
        XCTAssertEqual(comps.minute, 0)

        // Guard against dropping the UTC pin: the parsed instant must NOT match
        // what a formatter pinned to a non-UTC zone would produce.
        let gmt5 = DateFormatter()
        gmt5.dateFormat = "yyyy-MM-dd'T'HH:mm"
        gmt5.locale = Locale(identifier: "en_US_POSIX")
        gmt5.timeZone = TimeZone(secondsFromGMT: 5 * 3600)
        XCTAssertNotEqual(parsed, gmt5.date(from: "2026-07-04T15:00"),
                          "parseDueDate must read the stored wall time as UTC, not some local zone")
    }

    func testParseDueDate_DateOnlyIsUTCMidnight() throws {
        let parsed = try XCTUnwrap(Target.parseDueDate("2026-07-04"))
        let comps = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: parsed)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 7)
        XCTAssertEqual(comps.day, 4)
        XCTAssertEqual(comps.hour, 0)
        XCTAssertEqual(comps.minute, 0)
    }

    func testFormatDueDate_RendersUTCWallTime() throws {
        // Build the instant from UTC components (not a Z-string literal) so the
        // expectation is independent of the machine zone.
        let instant = try XCTUnwrap(utcCalendar.date(
            from: DateComponents(year: 2026, month: 1, day: 15, hour: 9, minute: 30)))
        XCTAssertEqual(Target.formatDueDate(instant), "2026-01-15T09:30")
    }

    func testDueDate_RoundTripsThroughStorageFormat() throws {
        let stored = "2026-07-04T15:00"
        let parsed = try XCTUnwrap(Target.parseDueDate(stored))
        XCTAssertEqual(Target.formatDueDate(parsed), stored)
    }

    func testParseDueDate_MalformedReturnsNil() {
        XCTAssertNil(Target.parseDueDate("not-a-date"))
        XCTAssertNil(Target.parseDueDate(""))
    }

    // MARK: - Date-only overdue/due-today semantics (UTC calendar days)

    func testDateOnlyDueTodayUTC_IsDueTodayNotOverdue() {
        let today = utcDayFormatter.string(from: Date())
        let target = makeTarget(dueDate: today)
        XCTAssertTrue(target.isDueToday, "date-only due == today's UTC day must be due today")
        XCTAssertFalse(target.isOverdue,
                       "date-only due means due ON the day — not overdue while the UTC day is still running")
    }

    func testDateOnlyDueYesterdayUTC_IsOverdueNotDueToday() {
        let yesterday = utcDayFormatter.string(from: Date(timeIntervalSinceNow: -86_400))
        let target = makeTarget(dueDate: yesterday)
        XCTAssertTrue(target.isOverdue)
        XCTAssertFalse(target.isDueToday)
    }

    func testDateOnlyDueTomorrowUTC_IsNeitherDueTodayNorOverdue() {
        let tomorrow = utcDayFormatter.string(from: Date(timeIntervalSinceNow: 86_400))
        let target = makeTarget(dueDate: tomorrow)
        XCTAssertFalse(target.isOverdue)
        XCTAssertFalse(target.isDueToday)
    }

    func testDateOnlyOverdue_RequiresActiveStatus() {
        let yesterday = utcDayFormatter.string(from: Date(timeIntervalSinceNow: -86_400))
        let target = makeTarget(dueDate: yesterday, status: "done")
        XCTAssertFalse(target.isOverdue)
    }

    func testSubItemDateOnlyDueTodayUTC_IsNotOverdue() {
        let today = utcDayFormatter.string(from: Date())
        let item = TargetSubItem(text: "step", done: false, dueDate: today)
        XCTAssertFalse(item.isOverdue,
                       "sub-item date-only dues follow the same 'due ON the day' semantics")
        let yesterday = utcDayFormatter.string(from: Date(timeIntervalSinceNow: -86_400))
        XCTAssertTrue(TargetSubItem(text: "step", done: false, dueDate: yesterday).isOverdue)
    }

    // MARK: - Display

    func testDueDateFormatted_DateOnlyShowsStoredCalendarDay() throws {
        // "2026-07-04" must render as July 4 everywhere — a local-day shift
        // (July 3 west of UTC) would leave no "4" anywhere in the string.
        let formatted = try XCTUnwrap(makeTarget(dueDate: "2026-07-04").dueDateFormatted)
        XCTAssertTrue(formatted.contains("4"),
                      "date-only due must show the stored UTC calendar day, got: \(formatted)")
    }
}
