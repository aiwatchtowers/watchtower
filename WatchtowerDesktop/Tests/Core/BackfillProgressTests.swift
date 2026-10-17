import XCTest
@testable import WatchtowerCore

final class BackfillProgressTests: XCTestCase {
    private let day = 86_400.0
    private let upper = 1_800_000_000.0

    /// A backfill over `total` days that has loaded `loaded` of them (counting back from `upper`).
    private func row(_ status: String, loaded: Double, of total: Double, waiting: String = "") -> BackfillRow {
        BackfillRow(status: status, waiting: waiting, floorTS: upper - total * day,
                    upperTS: upper, reachedTS: upper - loaded * day)
    }

    func testNoRowsIsNil() {
        XCTAssertNil(BackfillProgress.line([]))
    }

    func testAllDoneOrOffIsNil() {
        XCTAssertNil(BackfillProgress.line([row("done", loaded: 30, of: 30), row("off", loaded: 3, of: 30)]))
    }

    func testOneRunning() {
        XCTAssertEqual(BackfillProgress.line([row("running", loaded: 12, of: 30)]), "Loading history: 12 of 30 days")
    }

    /// R22: a paused (revoked) row is not loading, so only running rows count.
    func testTotalsSumOverRunningRowsOnly() {
        let rows = [row("running", loaded: 10, of: 28), row("running", loaded: 2, of: 5),
                    row("paused", loaded: 4, of: 23), row("done", loaded: 30, of: 30)]
        XCTAssertEqual(BackfillProgress.line(rows), "Loading history: 12 of 33 days")
    }

    /// R22: every considered row paused for a revoked account.
    func testAllPausedAsksToReconnect() {
        let rows = [row("paused", loaded: 4, of: 23), row("paused", loaded: 1, of: 30), row("done", loaded: 30, of: 30)]
        XCTAssertEqual(BackfillProgress.line(rows), "Loading history paused — reconnect the account")
    }

    /// R22: rows all paused, one of them still waiting on the plan limit.
    func testAllPausedWithPlanLimitShowsThePlanCopy() {
        let rows = [row("paused", loaded: 4, of: 23, waiting: "plan_limit"), row("paused", loaded: 1, of: 30)]
        XCTAssertEqual(BackfillProgress.line(rows), "Loading history paused — Claude plan limit")
    }

    /// Partial days round to the nearest whole day.
    func testDaysRound() {
        let partial = BackfillRow(status: "running", waiting: "", floorTS: upper - 29.6 * day,
                                  upperTS: upper, reachedTS: upper - 0.4 * day)
        XCTAssertEqual(BackfillProgress.line([partial]), "Loading history: 0 of 30 days")
    }

    func testAnyPlanLimitShowsThePausedCopy() {
        let rows = [row("running", loaded: 10, of: 28), row("paused", loaded: 4, of: 23, waiting: "plan_limit")]
        XCTAssertEqual(BackfillProgress.line(rows), "Loading history paused — Claude plan limit")
    }

    /// #580: every running row held by a transient failure says it retries;
    /// with rows still loading, the day count names the waiting sources.
    func testHeldRowsAreShownAsWaiting() {
        XCTAssertEqual(BackfillProgress.line([row("running", loaded: 2, of: 30, waiting: "held")]),
                       "Loading history waits — offline or a service is down, retrying")
        let one = [row("running", loaded: 2, of: 30, waiting: "held"), row("running", loaded: 4, of: 10)]
        XCTAssertEqual(BackfillProgress.line(one), "Loading history: 6 of 40 days, 1 source waiting")
        let two = one + [row("running", loaded: 0, of: 5, waiting: "held")]
        XCTAssertEqual(BackfillProgress.line(two), "Loading history: 6 of 45 days, 2 sources waiting")
    }

    /// A finished row's stale wait never counts.
    func testPlanLimitOnADoneRowIsIgnored() {
        let rows = [row("running", loaded: 1, of: 30), row("done", loaded: 30, of: 30, waiting: "plan_limit")]
        XCTAssertEqual(BackfillProgress.line(rows), "Loading history: 1 of 30 days")
    }
}
