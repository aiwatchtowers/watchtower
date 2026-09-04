import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class AgentActionFeedTests: XCTestCase {
    private func makePool() throws -> (DatabasePool, String) { try TestDatabase.createPool() }

    /// Wait for the observation to deliver `count` rows (ValueObservation is
    /// asynchronous; poll on the main actor with a bounded budget).
    private func waitForRows(_ feed: AgentActionFeed, count: Int) async {
        for _ in 0..<50 where feed.rows.count != count {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testStartObservesConversationRows() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try TestDatabase.insertAgentAction(db, conversationID: 1, turnID: "a")
            try TestDatabase.insertAgentAction(db, conversationID: 2, turnID: "b")
        }
        let feed = AgentActionFeed(dbPool: pool, cliRunner: FakeCLIRunner())
        feed.start(conversationID: 1)
        await waitForRows(feed, count: 1)
        XCTAssertEqual(feed.rows.map(\.turnID), ["a"])
        XCTAssertEqual(feed.cards(forTurn: "a").count, 1)
        XCTAssertTrue(feed.cards(forTurn: "zzz").isEmpty)
        XCTAssertEqual(feed.pendingCount, 1)

        try await pool.write { db in try TestDatabase.insertAgentAction(db, conversationID: 1, turnID: "a2") }
        await waitForRows(feed, count: 2)
        XCTAssertEqual(feed.rows.count, 2)
        feed.stop()
    }

    func testApproveRunsCLIWithJSONAndTracksInFlight() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in try TestDatabase.insertAgentAction(db) }
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"applied_ok":true,"error":"","action":{"id":1,"status":"applied"}}"#.utf8))
        let feed = AgentActionFeed(dbPool: pool, cliRunner: runner)
        feed.start(conversationID: 1)
        await waitForRows(feed, count: 1)

        await feed.approve(1)
        XCTAssertEqual(runner.invocations, [["actions", "approve", "1", "--json"]])
        XCTAssertTrue(feed.inFlight.isEmpty)
        XCTAssertNil(feed.lastError)

        await feed.reject(1)
        await feed.retry(1)
        XCTAssertEqual(runner.invocations.count, 3)
        XCTAssertEqual(runner.invocations[1], ["actions", "reject", "1", "--json"])
        XCTAssertEqual(runner.invocations[2], ["actions", "apply", "1", "--json"])
    }

    func testApproveSurfacesExecutionErrorFromEnvelope() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in try TestDatabase.insertAgentAction(db) }
        let json = #"{"ok":true,"applied_ok":false,"error":"issuetype: invalid","action":{"id":1,"status":"failed"}}"#
        let runner = FakeCLIRunner(stdout: Data(json.utf8))
        let feed = AgentActionFeed(dbPool: pool, cliRunner: runner)
        await feed.approve(1)
        XCTAssertEqual(feed.lastError, "issuetype: invalid")
    }

    func testApproveSurfacesProcessFailure() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        struct Boom: Error {}
        let feed = AgentActionFeed(dbPool: pool, cliRunner: FakeCLIRunner(error: Boom()))
        await feed.approve(1)
        XCTAssertNotNil(feed.lastError)
        XCTAssertTrue(feed.inFlight.isEmpty)
    }

    func testApproveAllPendingForTurn() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try TestDatabase.insertAgentAction(db, turnID: "t")
            try TestDatabase.insertAgentAction(db, turnID: "t", status: "applied")
            try TestDatabase.insertAgentAction(db, turnID: "t")
            try TestDatabase.insertAgentAction(db, turnID: "other")
        }
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"applied_ok":true,"error":"","action":{"id":1,"status":"applied"}}"#.utf8))
        let feed = AgentActionFeed(dbPool: pool, cliRunner: runner)
        feed.start(conversationID: 1)
        await waitForRows(feed, count: 4)
        await feed.approveAllPending(forTurn: "t")
        XCTAssertEqual(runner.invocations.map { $0[2] }.sorted(), ["1", "3"])
    }

    // MARK: - Cross-process writes

    /// Every `agent_actions` row is written by a `watchtower` SUBPROCESS — the
    /// chat-mode MCP server inserts proposals, `watchtower actions …` transitions
    /// them. GRDB `ValueObservation` only fires on writes made through the app's
    /// own writer connection, so the observation alone leaves the feed blind to
    /// exactly the writes that matter. A second `DatabasePool` on the same file
    /// stands in for that subprocess.
    func testObservationIsBlindToAnotherConnectionUntilRefresh() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        // Seed through the app's own pool and wait for it: the observation is
        // then provably live, so what follows measures the observation, not a
        // race with its first fetch.
        try await pool.write { db in try TestDatabase.insertAgentAction(db, conversationID: 1, turnID: "seed") }
        let feed = AgentActionFeed(dbPool: pool, cliRunner: FakeCLIRunner())
        feed.start(conversationID: 1)
        await waitForRows(feed, count: 1)

        let otherPool = try DatabasePool(path: path)
        try await otherPool.write { db in try TestDatabase.insertAgentAction(db, conversationID: 1, turnID: "cli") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(feed.rows.map(\.turnID), ["seed"], "ValueObservation cannot see another connection's write")

        feed.refresh()
        XCTAssertEqual(feed.rows.map(\.turnID), ["seed", "cli"])
        feed.stop()
    }

    /// The `TargetWatchesViewModel.refreshEvents` precedent: the CLI just wrote
    /// on another connection, so refetch when it returns instead of waiting for
    /// an observation that will never fire.
    func testApproveRefreshesRowsAfterCLI() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        let id = try await pool.write { db in try TestDatabase.insertAgentAction(db, conversationID: 1) }
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"applied_ok":true,"error":""}"#.utf8))
        let feed = AgentActionFeed(dbPool: pool, cliRunner: runner)
        feed.start(conversationID: 1)
        await waitForRows(feed, count: 1)
        XCTAssertEqual(feed.rows.first?.status, "pending")

        // What `watchtower actions approve` does, from its own connection.
        let otherPool = try DatabasePool(path: path)
        try await otherPool.write { db in
            try db.execute(sql: "UPDATE agent_actions SET status = 'applied' WHERE id = ?", arguments: [id])
        }
        await feed.approve(id)
        XCTAssertEqual(feed.rows.first?.status, "applied", "the card must reflect what the CLI wrote")
        XCTAssertNil(feed.lastError)
        feed.stop()
    }

    /// A proposal is inserted mid-turn by the chat-mode MCP subprocess, with no
    /// CLI call of ours to hang a refetch on — the poll is what surfaces it
    /// (`IdeasViewModel.startPolling`'s safety-net poll).
    func testPollSurfacesRowsWrittenByAnotherConnection() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in try TestDatabase.insertAgentAction(db, conversationID: 1, turnID: "seed") }
        let feed = AgentActionFeed(dbPool: pool, cliRunner: FakeCLIRunner(), pollInterval: .milliseconds(50))
        feed.start(conversationID: 1)
        await waitForRows(feed, count: 1)

        let otherPool = try DatabasePool(path: path)
        try await otherPool.write { db in try TestDatabase.insertAgentAction(db, conversationID: 1, turnID: "mcp") }
        for _ in 0..<60 where feed.rows.count < 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(feed.rows.map(\.turnID), ["seed", "mcp"], "the poll must surface the subprocess's insert")

        feed.stop()
        XCTAssertTrue(feed.rows.isEmpty)
        try await otherPool.write { db in try TestDatabase.insertAgentAction(db, conversationID: 1, turnID: "after-stop") }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(feed.rows.isEmpty, "stop() must cancel the poll")
    }

    /// Minor 22: a per-row failure inside `approveAllPending` must survive the
    /// next row's run — the batch clears the error once, up front.
    func testApproveAllPendingKeepsTheFirstFailuresError() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try TestDatabase.insertAgentAction(db, turnID: "t")
            try TestDatabase.insertAgentAction(db, turnID: "t")
        }
        let runner = FailingOnceCLIRunner()
        let feed = AgentActionFeed(dbPool: pool, cliRunner: runner)
        feed.start(conversationID: 1)
        await waitForRows(feed, count: 2)

        await feed.approveAllPending(forTurn: "t")
        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(feed.lastError, "boom", "the failure must not be cleared by the next row's run")
    }

    func testOutcomesBlockUsesTimestampFloor() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try TestDatabase.insertAgentAction(db, status: "applied", resultJSON: #"{"target_id":9}"#, appliedAt: "2026-09-04T10:05:00Z")
            try TestDatabase.insertAgentAction(db, status: "rejected", decidedAt: "2026-09-04T09:00:00Z")
        }
        let feed = AgentActionFeed(dbPool: pool, cliRunner: FakeCLIRunner())
        feed.start(conversationID: 1)
        let after = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-04T10:00:00Z"))
        let block = try XCTUnwrap(feed.outcomesBlock(after: after))
        XCTAssertTrue(block.contains("#1 create_target: applied"))
        XCTAssertFalse(block.contains("#2"))
        XCTAssertNil(feed.outcomesBlock(after: nil), "no previous owner message → nothing to report")
        XCTAssertEqual(AgentActionFeed.timestampString(after), "2026-09-04T10:00:00Z")
    }
}

/// Fails only its first invocation — models one row of a batch approve failing
/// while the rest succeed.
private final class FailingOnceCLIRunner: CLIRunnerProtocol, @unchecked Sendable {
    private struct Boom: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    private let lock = NSLock()
    private var _invocations: [[String]] = []
    var invocations: [[String]] { lock.withLock { _invocations } }

    func run(args: [String]) async throws -> Data {
        let call = lock.withLock { () -> Int in
            _invocations.append(args)
            return _invocations.count
        }
        if call == 1 { throw Boom() }
        return Data(#"{"ok":true,"applied_ok":true,"error":""}"#.utf8)
    }
}
