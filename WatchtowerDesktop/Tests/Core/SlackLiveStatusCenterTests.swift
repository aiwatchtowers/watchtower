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

@MainActor
final class SlackLiveStatusCenterErrorTests: XCTestCase {
    /// A probe that fails is kept for display, not swallowed; the rows still load.
    func testProbeFailureIsKept() async throws {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        let runner = FakeCLIRunner()
        runner.shouldThrow = CLIRunnerError.nonZeroExit(code: 1, stderr: "boom")
        let center = SlackLiveStatusCenter(dbPool: pool, runner: runner, providers: ["claude"])
        center.checkAgain()
        await center.inFlight?.value
        XCTAssertEqual(center.lastError?.kind, .probe)
        XCTAssertEqual(center.lastError?.provider, "claude")
        XCTAssertFalse(center.lastError?.message.isEmpty ?? true)
        XCTAssertTrue(center.statuses.isEmpty)
    }

    /// A probe failure of the first provider is not wiped by the next
    /// provider's clean read; the next pass starts clean.
    func testProbeFailureSurvivesThePass() async throws {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        let runner = FakeCLIRunner()
        runner.shouldThrow = CLIRunnerError.nonZeroExit(code: 1, stderr: "boom")
        let center = SlackLiveStatusCenter(dbPool: pool, runner: runner)
        center.checkAgain()
        await center.inFlight?.value
        XCTAssertEqual(center.lastError?.kind, .probe)
        runner.shouldThrow = nil
        center.checkAgain()
        await center.inFlight?.value
        XCTAssertNil(center.lastError)
    }

    /// A failed read is not "no rows": the rows shown stay, the error is kept
    /// as a read error, and a clean read clears it.
    func testReadFailureKeepsRows() async throws {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO slack_live_status (team_id, provider, status, error_class, connector_id, checked_at)
                VALUES ('', 'claude', 'ok', '', '', '2026-11-14T10:00:00.000000000Z')
                """)
        }
        let center = SlackLiveStatusCenter(dbPool: pool, runner: nil)
        await center.reload()
        try await breakStatusTable(pool)
        await center.reload()
        XCTAssertEqual(center.statuses.count, 1, "the last rows stay")
        XCTAssertEqual(center.lastError?.kind, .read)
        XCTAssertTrue(center.hasRead)
        try await restoreStatusTable(pool)
        await center.reload()
        XCTAssertNil(center.lastError)
    }

    /// Probe fails, then its read fails too: the read failure shows while the
    /// rows are stale; once a read recovers, the probe failure shows.
    func testProbeThenReadFailureKeepsBoth() async throws {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        let runner = FakeCLIRunner()
        runner.shouldThrow = CLIRunnerError.nonZeroExit(code: 1, stderr: "boom")
        let center = SlackLiveStatusCenter(dbPool: pool, runner: runner, providers: ["claude"])
        try await breakStatusTable(pool)
        center.checkAgain()
        await center.inFlight?.value
        XCTAssertEqual(center.lastError?.kind, .read)
        XCTAssertEqual(center.probeError?.provider, "claude")
        try await restoreStatusTable(pool)
        await center.reload()
        XCTAssertEqual(center.lastError?.kind, .probe, "the probe failure is not lost")
    }

    /// A read fails first, then a pass whose probe fails reads cleanly: the
    /// probe failure shows.
    func testReadThenProbeFailureShowsProbe() async throws {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        let runner = FakeCLIRunner()
        runner.shouldThrow = CLIRunnerError.nonZeroExit(code: 1, stderr: "boom")
        let center = SlackLiveStatusCenter(dbPool: pool, runner: runner, providers: ["claude"])
        try await breakStatusTable(pool)
        await center.reload()
        XCTAssertEqual(center.lastError?.kind, .read)
        try await restoreStatusTable(pool)
        center.checkAgain()
        await center.inFlight?.value
        XCTAssertNil(center.readError)
        XCTAssertEqual(center.lastError?.kind, .probe)
    }

    /// A status read that genuinely fails: the table is swapped for one
    /// without the row's columns, so the SELECT errors. (A missing table is
    /// a legitimate "no rows" for `SlackLiveStatusRow.fetchAll`, an older
    /// database, so renaming it away no longer forces a failure.)
    private func breakStatusTable(_ pool: DatabasePool) async throws {
        try await pool.write { db in
            try db.execute(sql: "ALTER TABLE slack_live_status RENAME TO slack_live_status_gone")
            try db.execute(sql: "CREATE TABLE slack_live_status (unrelated TEXT)")
        }
    }

    private func restoreStatusTable(_ pool: DatabasePool) async throws {
        try await pool.write { db in
            try db.execute(sql: "DROP TABLE slack_live_status")
            try db.execute(sql: "ALTER TABLE slack_live_status_gone RENAME TO slack_live_status")
        }
    }

    func testCheckAgainWhileRunningIsIgnored() async throws {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        let runner = FakeCLIRunner()
        let center = SlackLiveStatusCenter(dbPool: pool, runner: runner)
        center.checkAgain()
        XCTAssertTrue(center.isRunning)
        let first = center.inFlight
        center.checkAgain()
        XCTAssertTrue(center.inFlight == first, "no second pass starts")
        await center.inFlight?.value
        XCTAssertEqual(runner.invocations.count, 2, "one call per provider, once")
    }

    func testHasRead() async throws {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        let center = SlackLiveStatusCenter(dbPool: pool, runner: nil)
        XCTAssertFalse(center.hasRead)
        await center.reload()
        XCTAssertTrue(center.hasRead)
    }
}
