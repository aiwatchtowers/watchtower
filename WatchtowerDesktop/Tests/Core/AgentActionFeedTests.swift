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
