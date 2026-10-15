import XCTest
@testable import WatchtowerCore

final class PlanUsageNoticePolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_058_400) // 2026-10-15T10:00:00Z

    func lim(_ key: String, _ pct: Double, _ state: String, resetIn: TimeInterval = 3600) -> PlanUsageLimit {
        PlanUsageLimit(key: key, label: key, group: key == "session" ? "session" : "weekly", percent: pct,
                       resetsAt: now.addingTimeInterval(resetIn), severity: nil,
                       projection: PlanUsageProjection(state: state, hitAt: state == "will_hit" ? now.addingTimeInterval(1800) : nil, ratePerHour: 1))
    }
    func st(_ l: [PlanUsageLimit], state: String = "ok") -> PlanUsageStatus {
        PlanUsageStatus(state: state, reason: "", plan: "max", fetchedAt: now, lastError: "", limits: l, breakdown: [])
    }

    func testPlanUsage03_OneNoticePerWindow() {
        let s = st([lim("weekly_all", 60, "will_hit")])
        let first = PlanUsageNoticePolicy.evaluate(s, sent: [], now: now)
        XCTAssertEqual(first.notices.count, 1)
        let second = PlanUsageNoticePolicy.evaluate(s, sent: first.sent, now: now)
        XCTAssertTrue(second.notices.isEmpty)
    }

    func testNinetyPercentIsSeparateFromWillHit() {
        let s = st([lim("session", 92, "will_hit")])
        XCTAssertEqual(PlanUsageNoticePolicy.evaluate(s, sent: [], now: now).notices.count, 2)
    }

    func testScopedOnlyAtNinety() {
        XCTAssertTrue(PlanUsageNoticePolicy.evaluate(st([lim("weekly_scoped:fable", 50, "will_hit")]), sent: [], now: now).notices.isEmpty)
        XCTAssertEqual(PlanUsageNoticePolicy.evaluate(st([lim("weekly_scoped:fable", 91, "safe")]), sent: [], now: now).notices.count, 1)
    }

    func testStaleOrNotOkNeverNotifies() {
        XCTAssertTrue(PlanUsageNoticePolicy.evaluate(st([lim("session", 95, "hit")], state: "error"), sent: [], now: now).notices.isEmpty)
    }

    func testPrunesPastWindows() {
        let old = "p90|session|2026-10-14T00:00:00Z"
        let out = PlanUsageNoticePolicy.evaluate(st([lim("session", 10, "safe")]), sent: [old], now: now)
        XCTAssertFalse(out.sent.contains(old))
    }

    func testReachedLimitBody() {
        let n = PlanUsageNoticePolicy.evaluate(st([lim("session", 100, "hit")]), sent: [], now: now).notices
        XCTAssertTrue(n.first?.body.hasPrefix("Limit reached. Resets") == true)
    }

    func testResetJitterAcrossSecondBoundaryKeepsOneKey() {
        func status(_ jitter: TimeInterval) -> PlanUsageStatus {
            st([lim("session", 92, "safe", resetIn: 3600 + jitter)])
        }
        let first = PlanUsageNoticePolicy.evaluate(status(-0.4), sent: [], now: now)
        XCTAssertEqual(first.notices.count, 1)
        let second = PlanUsageNoticePolicy.evaluate(status(0.6), sent: first.sent, now: now)
        XCTAssertTrue(second.notices.isEmpty)
    }

    func testWindowPastItsResetNeverRenotifies() {
        // Notified during the window; the row still carries it 10 s after the reset.
        let during = PlanUsageNoticePolicy.evaluate(st([lim("session", 92, "will_hit", resetIn: 20)]), sent: [], now: now)
        XCTAssertEqual(during.notices.count, 2)
        let after = PlanUsageNoticePolicy.evaluate(
            st([lim("session", 92, "will_hit", resetIn: 20)]), sent: during.sent, now: now.addingTimeInterval(30))
        XCTAssertTrue(after.notices.isEmpty)
    }

    func testRoundedKeyOutlivesAnEarlierRoundedTime() {
        // Reset at :25 s rounds the key down to :00; 10 s before the real reset
        // the key must still be held.
        let s = st([lim("session", 92, "safe", resetIn: 25)])
        let first = PlanUsageNoticePolicy.evaluate(s, sent: [], now: now)
        XCTAssertEqual(first.notices.count, 1)
        XCTAssertTrue(PlanUsageNoticePolicy.evaluate(s, sent: first.sent, now: now.addingTimeInterval(15)).notices.isEmpty)
    }
}
