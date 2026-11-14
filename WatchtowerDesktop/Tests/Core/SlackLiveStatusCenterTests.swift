import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class SlackLiveStatusCenterTests: XCTestCase {
    private func makeCenter(_ runner: FakeCLIRunner) throws -> SlackLiveStatusCenter {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        return SlackLiveStatusCenter(dbPool: pool, runner: runner)
    }

    func testRefreshIfStaleSkipsWhileRunning() async throws {
        let runner = FakeCLIRunner()
        let center = try makeCenter(runner)
        center.refreshIfStale()
        center.refreshIfStale()
        center.checkAgain()
        await center.inFlight?.value
        XCTAssertEqual(runner.invocations.count, 2, "one pass = one call per provider, never a second pass")
        XCTAssertEqual(runner.invocations.map { $0[4] }, ["claude", "codex"], "one provider at a time, in order")
        XCTAssertFalse(center.isRunning)
        center.refreshIfStale()
        await center.inFlight?.value
        XCTAssertEqual(runner.invocations.count, 2, "a pass within maxAge is not repeated")
    }

    func testCheckAgainPassesNoIfOlder() async throws {
        let runner = FakeCLIRunner()
        let center = try makeCenter(runner)
        center.checkAgain()
        await center.inFlight?.value
        XCTAssertEqual(runner.invocations.count, 2)
        for args in runner.invocations {
            XCTAssertFalse(args.contains("--if-older"))
            XCTAssertEqual(Array(args.prefix(3)), ["slack", "live", "probe"])
        }

        center.refreshIfStale(maxAge: 0)
        await center.inFlight?.value
        XCTAssertTrue(runner.invocations.suffix(2).allSatisfy { $0.contains("--if-older") })
    }

    func testReloadReadsRowsNewestFirst() async throws {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO slack_live_status (team_id, provider, status, error_class, connector_id, checked_at) VALUES
                ('', 'claude', 'ok', '', '', '2026-11-14T10:00:00.000000000Z'),
                ('', 'codex', 'not_connected', 'no_connector', '', '2026-11-14T11:00:00.000000000Z')
                """)
        }
        let center = SlackLiveStatusCenter(dbPool: pool, runner: nil)
        await center.reload()
        XCTAssertEqual(center.statuses.map(\.provider), ["codex", "claude"])
        XCTAssertEqual(center.statuses.first?.errorClass, "no_connector")
    }
}
