import XCTest
@testable import WatchtowerCore

final class PlanUsagePresentationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_058_400) // 2026-10-15T10:00:00Z

    func limit(
        _ key: String, _ pct: Double, state: String = "safe", hitAt: Date? = nil, resetsIn: TimeInterval? = 3 * 3600
    ) -> PlanUsageLimit {
        PlanUsageLimit(key: key, label: key == "session" ? "5-hour" : "Weekly", group: key == "session" ? "session" : "weekly",
                       percent: pct, resetsAt: resetsIn.map { now.addingTimeInterval($0) }, severity: "normal",
                       projection: PlanUsageProjection(state: state, hitAt: hitAt, ratePerHour: 0))
    }

    func status(_ limits: [PlanUsageLimit], state: String = "ok", fetchedAgo: TimeInterval = 60) -> PlanUsageStatus {
        PlanUsageStatus(
            state: state, reason: "", plan: "max", fetchedAt: now.addingTimeInterval(-fetchedAgo),
            lastError: "", limits: limits, breakdown: []
        )
    }

    func testMenuBarText() {
        let s = status([limit("session", 4.4), limit("weekly_all", 59), limit("weekly_scoped:fable", 4)])
        XCTAssertEqual(PlanUsagePresentation.menuBarText(s), "5h 4% · 7d 59%")
        XCTAssertNil(PlanUsagePresentation.menuBarText(nil))
        XCTAssertNil(PlanUsagePresentation.menuBarText(status([], state: "unavailable")))
        XCTAssertNil(PlanUsagePresentation.menuBarText(status([limit("session", 4)], state: "disabled")))
    }

    func testTone() {
        XCTAssertEqual(PlanUsagePresentation.tone(limit("session", 69)), .normal)
        XCTAssertEqual(PlanUsagePresentation.tone(limit("session", 70)), .warning)
        XCTAssertEqual(PlanUsagePresentation.tone(limit("session", 10, state: "will_hit", hitAt: now)), .warning)
        XCTAssertEqual(PlanUsagePresentation.tone(limit("session", 90)), .critical)
        XCTAssertEqual(PlanUsagePresentation.tone(limit("session", 100, state: "hit")), .critical)
    }

    func testStaleWhenFetchedLongAgo() {
        XCTAssertFalse(PlanUsagePresentation.isStale(status([limit("session", 4)], fetchedAgo: 60), now: now))
        XCTAssertTrue(PlanUsagePresentation.isStale(status([limit("session", 4)], fetchedAgo: 16 * 60), now: now))
        XCTAssertTrue(PlanUsagePresentation.isStale(status([limit("session", 4)], state: "error"), now: now))
        XCTAssertFalse(PlanUsagePresentation.menuBarWarning(status([limit("session", 95)], fetchedAgo: 3600), now: now), "stale never warns")
        XCTAssertTrue(PlanUsagePresentation.menuBarWarning(status([limit("session", 95)]), now: now))
    }

    func testProjectionText() {
        let hit = now.addingTimeInterval(90 * 60)
        XCTAssertTrue(PlanUsagePresentation.projectionText(limit("session", 70, state: "will_hit", hitAt: hit), now: now)
            .hasPrefix("At this pace you hit it at "))
        XCTAssertEqual(PlanUsagePresentation.projectionText(limit("session", 10), now: now), "You won't hit it before the reset")
        XCTAssertEqual(PlanUsagePresentation.projectionText(limit("session", 10, state: "collecting"), now: now), "Collecting data…")
        XCTAssertEqual(PlanUsagePresentation.projectionText(limit("session", 100, state: "hit"), now: now), "Limit reached")
        XCTAssertEqual(PlanUsagePresentation.projectionText(limit("session", 0, state: "idle", resetsIn: nil), now: now), "Window not started")
    }

    func testResetText() {
        XCTAssertEqual(PlanUsagePresentation.resetText(limit("session", 4, resetsIn: 3 * 3600 + 12 * 60), now: now).prefix(19), "Resets in 3 h 12 m ")
        XCTAssertEqual(PlanUsagePresentation.resetText(limit("session", 0, resetsIn: nil), now: now), "Not started")
    }

    func testDatesParseNineDigitFraction() {
        let a = PlanUsageDates.parse("2026-10-15T10:00:00.123456789Z")
        XCTAssertEqual(a, now)
        XCTAssertEqual(PlanUsageDates.parse("2026-10-15T10:00:00Z"), now)
        XCTAssertNil(PlanUsageDates.parse(""))
        XCTAssertNil(PlanUsageDates.parse(nil))
        XCTAssertNil(PlanUsageDates.parse("garbage"))
    }
}
