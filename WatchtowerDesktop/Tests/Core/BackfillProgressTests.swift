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

    func testTotalsSumOverRunningAndPausedRowsOnly() {
        let rows = [row("running", loaded: 10, of: 28), row("paused", loaded: 4, of: 23), row("done", loaded: 30, of: 30)]
        XCTAssertEqual(BackfillProgress.line(rows), "Loading history: 14 of 51 days")
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

    /// A finished row's stale wait never counts.
    func testPlanLimitOnADoneRowIsIgnored() {
        let rows = [row("running", loaded: 1, of: 30), row("done", loaded: 30, of: 30, waiting: "plan_limit")]
        XCTAssertEqual(BackfillProgress.line(rows), "Loading history: 1 of 30 days")
    }
}
