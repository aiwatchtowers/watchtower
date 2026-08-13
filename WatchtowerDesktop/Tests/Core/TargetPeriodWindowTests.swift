import XCTest
@testable import WatchtowerCore

/// `Target.periodWindow(for:anchoredOn:)` expands a target's period to the natural
/// bounds of a horizon level, anchored on the existing `period_start` so the
/// target keeps its "when" while the period reflects the new granularity.
final class TargetPeriodWindowTests: XCTestCase {

    // 2026-06-27 is a Saturday, in June 2026, in Q2 (Apr–Jun).
    private let anchor = "2026-06-27"

    func testDay_isTheAnchorDayItself() {
        let window = Target.periodWindow(for: "day", anchoredOn: anchor)
        XCTAssertEqual(window?.start, "2026-06-27")
        XCTAssertEqual(window?.end, "2026-06-27")
    }

    func testWeek_isMondayToSundayContainingTheAnchor() {
        let window = Target.periodWindow(for: "week", anchoredOn: anchor)
        XCTAssertEqual(window?.start, "2026-06-22", "Monday of the anchor's week")
        XCTAssertEqual(window?.end, "2026-06-28", "Sunday of the anchor's week")
    }

    func testMonth_isFirstToLastDayOfTheAnchorMonth() {
        let window = Target.periodWindow(for: "month", anchoredOn: anchor)
        XCTAssertEqual(window?.start, "2026-06-01")
        XCTAssertEqual(window?.end, "2026-06-30")
    }

    func testQuarter_isFirstToLastDayOfTheAnchorQuarter() {
        let window = Target.periodWindow(for: "quarter", anchoredOn: anchor)
        XCTAssertEqual(window?.start, "2026-04-01")
        XCTAssertEqual(window?.end, "2026-06-30")
    }

    func testQuarter_year_endBoundary() {
        let window = Target.periodWindow(for: "quarter", anchoredOn: "2026-12-31")
        XCTAssertEqual(window?.start, "2026-10-01", "Q4 start")
        XCTAssertEqual(window?.end, "2026-12-31", "Q4 end")
    }

    /// The window is anchored on the existing period_start, NOT on today — a
    /// future-dated target keeps its future "when" instead of snapping to now.
    func testAnchorsOnExistingPeriodStart_notToday() {
        let window = Target.periodWindow(for: "month", anchoredOn: "2026-08-15")
        XCTAssertEqual(window?.start, "2026-08-01")
        XCTAssertEqual(window?.end, "2026-08-31")
    }

    func testCustom_returnsNil_soPeriodIsLeftUntouched() {
        XCTAssertNil(Target.periodWindow(for: "custom", anchoredOn: anchor))
    }

    func testUnknownLevel_returnsNil() {
        XCTAssertNil(Target.periodWindow(for: "decade", anchoredOn: anchor))
    }

    func testMalformedAnchor_returnsNil() {
        XCTAssertNil(Target.periodWindow(for: "week", anchoredOn: "not-a-date"))
    }
}
