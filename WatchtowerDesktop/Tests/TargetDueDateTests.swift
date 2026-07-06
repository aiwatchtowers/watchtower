import XCTest
import GRDB
@testable import WatchtowerDesktop

/// `targets.due_date` is stored as a UTC wall-time string ("YYYY-MM-DDTHH:MM"
/// or "YYYY-MM-DD") — the Go side writes `t.UTC()` and compares against
/// `now.UTC()` (cmd/remind.go, NotifyDueTargets). Swift must therefore parse
/// and format the stored string as UTC, never as local wall time, or due dates
/// drift by the machine's UTC offset between the two sides.
///
/// Date-only values ("YYYY-MM-DD") mean "due ON that day" in the USER'S LOCAL
/// calendar: the target is due today when the stored day equals today's local
/// day, and overdue only once the local day has passed — matching the SQL
/// badge counters (TargetQueries.todayDateString is local) and the user's wall
/// clock. Semantics decided by the owner 2026-07-06 (option A); the parsing
/// tests below still pin UTC for DATETIME values, which the Go reminder path
/// compares as UTC instants.
///
/// Parsing assertions are derived timezone-independently (UTC calendar
/// components) so they fail on ANY machine zone if the UTC pin is dropped.
final class TargetDueDateTests: XCTestCase {

    private let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone
        return cal
    }()

    /// Today ± N days as "yyyy-MM-dd" in the LOCAL calendar — date-only due
    /// dates are compared against the user's local day (see header).
    /// Calendar arithmetic, not 86 400-second offsets: DST days are 23/25 h.
    private func localDayString(offsetDays: Int = 0) -> String {
        let day = Calendar.current.date(byAdding: .day, value: offsetDays, to: Date()) ?? Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: day)
    }

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

    // MARK: - Date-only overdue/due-today semantics (local calendar days)

    func testDateOnlyDueTodayLocal_IsDueTodayNotOverdue() {
        let target = makeTarget(dueDate: localDayString())
        XCTAssertTrue(target.isDueToday, "date-only due == today's local day must be due today")
        XCTAssertFalse(target.isOverdue,
                       "date-only due means due ON the day — not overdue while the local day is still running")
    }

    func testDateOnlyDueYesterdayLocal_IsOverdueNotDueToday() {
        let target = makeTarget(dueDate: localDayString(offsetDays: -1))
        XCTAssertTrue(target.isOverdue)
        XCTAssertFalse(target.isDueToday)
    }

    func testDateOnlyDueTomorrowLocal_IsNeitherDueTodayNorOverdue() {
        let target = makeTarget(dueDate: localDayString(offsetDays: 1))
        XCTAssertFalse(target.isOverdue)
        XCTAssertFalse(target.isDueToday)
    }

    func testDateOnlyOverdue_RequiresActiveStatus() {
        let target = makeTarget(dueDate: localDayString(offsetDays: -1), status: "done")
        XCTAssertFalse(target.isOverdue)
    }

    func testSubItemDateOnlyDueTodayLocal_IsNotOverdue() {
        let item = TargetSubItem(text: "step", done: false, dueDate: localDayString())
        XCTAssertFalse(item.isOverdue,
                       "sub-item date-only dues follow the same 'due ON the day' semantics")
        XCTAssertTrue(TargetSubItem(text: "step", done: false, dueDate: localDayString(offsetDays: -1)).isOverdue)
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
