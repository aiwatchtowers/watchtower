import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// After the owner decides an automation run's proposal, the Desktop wakes
/// the daemon's automations loop so the waiting run resumes now instead of
/// on its next poll (spec §7.4).
@MainActor
final class AgentActionFeedAutomationWakeTests: XCTestCase {
    private struct WakeFailed: Error {}

    private final class WakeSpy {
        var calls = 0
        var failure: Error?
    }

    private static let okEnvelope = Data(#"{"ok":true,"applied_ok":true,"error":""}"#.utf8)

    private func makeFeed(_ pool: DatabasePool, spy: WakeSpy, runner: FakeCLIRunner) -> AgentActionFeed {
        AgentActionFeed(dbPool: pool, cliRunner: runner) {
            spy.calls += 1
            if let failure = spy.failure { throw failure }
        }
    }

    private func insertAutomationRow(_ pool: DatabasePool) async throws -> Int64 {
        try await pool.write { db in
            try TestDatabase.insertAgentAction(
                db, surface: "automation", conversationID: 0, contextType: "automation_run", contextID: "7"
            )
        }
    }

    func testApproveOfAutomationRowWakes() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let id = try await insertAutomationRow(pool)
        let spy = WakeSpy()
        let feed = makeFeed(pool, spy: spy, runner: FakeCLIRunner(stdout: Self.okEnvelope))

        await feed.approve(id, shownArgs: "{}")

        XCTAssertEqual(spy.calls, 1)
        XCTAssertNil(feed.rowErrors[id])
    }

    func testRejectOfAutomationRowWakes() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let id = try await insertAutomationRow(pool)
        let spy = WakeSpy()
        let feed = makeFeed(pool, spy: spy, runner: FakeCLIRunner(stdout: Self.okEnvelope))

        await feed.reject(id)
        XCTAssertEqual(spy.calls, 1)

        await feed.retry(id)
        XCTAssertEqual(spy.calls, 2, "a retry is a decision too")
    }

    func testMainChatRowDoesNotWake() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let id = try await pool.write { db in try TestDatabase.insertAgentAction(db) }
        let spy = WakeSpy()
        let feed = makeFeed(pool, spy: spy, runner: FakeCLIRunner(stdout: Self.okEnvelope))

        await feed.approve(id, shownArgs: "{}")
        await feed.reject(id)

        XCTAssertEqual(spy.calls, 0)
    }

    func testFailedCLICallDoesNotWake() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let id = try await insertAutomationRow(pool)
        let spy = WakeSpy()
        let feed = makeFeed(pool, spy: spy, runner: FakeCLIRunner(error: CLIRunnerError.binaryNotFound))

        await feed.approve(id, shownArgs: "{}")

        XCTAssertEqual(spy.calls, 0)
        XCTAssertNotNil(feed.rowErrors[id])
    }

    func testWakeFailureDoesNotFailApprove() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let id = try await insertAutomationRow(pool)
        let spy = WakeSpy()
        spy.failure = WakeFailed()
        let feed = makeFeed(pool, spy: spy, runner: FakeCLIRunner(stdout: Self.okEnvelope))

        await feed.approve(id, shownArgs: "{}")

        XCTAssertEqual(spy.calls, 1)
        XCTAssertNil(feed.rowErrors[id])
        XCTAssertNil(feed.lastError)
        XCTAssertTrue(feed.inFlight.isEmpty)
    }
}
