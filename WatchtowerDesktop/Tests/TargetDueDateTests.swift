import XCTest
@testable import WatchtowerDesktop

/// `targets.due_date` is stored as a UTC wall-time string ("YYYY-MM-DDTHH:MM"
/// or "YYYY-MM-DD") — the Go side writes `t.UTC()` and compares against
/// `now.UTC()` (cmd/remind.go, NotifyDueTargets). Swift must therefore parse
/// and format the stored string as UTC, never as local wall time, or due dates
/// drift by the machine's UTC offset between the two sides.
final class TargetDueDateTests: XCTestCase {

    private let iso: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    func testParseDueDate_DatetimeIsReadAsUTCInstant() throws {
        let parsed = try XCTUnwrap(Target.parseDueDate("2026-07-04T15:00"))
        XCTAssertEqual(parsed, iso.date(from: "2026-07-04T15:00:00Z"))
    }

    func testParseDueDate_DateOnlyIsUTCMidnight() throws {
        let parsed = try XCTUnwrap(Target.parseDueDate("2026-07-04"))
        XCTAssertEqual(parsed, iso.date(from: "2026-07-04T00:00:00Z"))
    }

    func testFormatDueDate_RendersUTCWallTime() throws {
        let instant = try XCTUnwrap(iso.date(from: "2026-01-15T09:30:00Z"))
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
}
