import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// A Reply press goes through `watchtower automations reply` (AUTO-09: the
/// CLI records the press and only queues a run); the Desktop writes nothing
/// for it (STRIP-02).
@MainActor
final class InboxReplyPressTests: XCTestCase {
    /// Triage's output 1 with an Open link and a Backlog reply button, and
    /// an agent action (Go's case `desktop_reply_press_card`).
    private func seed(_ pool: DatabasePool) throws -> (id: Int64, tower: FeedCaseTransport) {
        (1, try FeedCaseTransport.seeded("desktop_reply_press_card", pool: pool))
    }

    private func dump(_ pool: DatabasePool) throws -> [String: [Row]] {
        try pool.read { db in
            var out: [String: [Row]] = [:]
            for table in ["automation_outputs", "automation_runs", "agent_actions"] {
                out[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY id")
            }
            return out
        }
    }

    func testAuto09_ReplyPressOnlyQueues() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let (id, tower) = try seed(pool)
        let before = try dump(pool)
        let runner = FakeCLIRunner(stdout: Data(#"{"run_id":7,"daemon_running":true}"#.utf8))
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: runner)
        await vm.follow(tower)

        await vm.pressReply(outputID: id, action: 1, contentHash: "h1")

        XCTAssertEqual(runner.invocations,
                       [["automations", "reply", "--output", String(id), "--action", "1",
                         "--content-hash", "h1", "--json"]])
        XCTAssertEqual(try dump(pool), before)
        XCTAssertNil(vm.lastError)
        XCTAssertFalse(vm.isWriting(output: id))
    }

    func testSecondPressWhileWritingIsDropped() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let (id, tower) = try seed(pool)
        let runner = FakeCLIRunner(stdout: Data(#"{"run_id":7,"daemon_running":true}"#.utf8))
        runner.blockUntilCancelled = true
        runner.returnDataOnCancelInsteadOfThrowing = true
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: runner)
        await vm.follow(tower)

        let first = Task { await vm.pressReply(outputID: id, action: 1, contentHash: "h1") }
        await runner.untilInvocations(1)
        XCTAssertTrue(vm.isWriting(output: id))

        await vm.pressReply(outputID: id, action: 1, contentHash: "h1")
        XCTAssertEqual(runner.invocations.count, 1)

        first.cancel()
        await first.value
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertFalse(vm.isWriting(output: id))
    }

    func testCLIFailureKeepsCardAndSaysWhy() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let (id, tower) = try seed(pool)
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: Sent — run #7\n"))
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: runner)
        await vm.follow(tower)

        await vm.pressReply(outputID: id, action: 1, contentHash: "h1")

        XCTAssertTrue(vm.lastError?.contains("Sent — run #7") == true, vm.lastError ?? "nil")
        XCTAssertEqual(vm.outputRows.map(\.id), [id])
    }

    /// The CLI refuses a press on a card rewritten since it was drawn
    /// (`ErrOutputChanged`): the banner says so and the card is read again.
    func testChangedCardRefusalSaysLookAgain() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let (id, tower) = try seed(pool)
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(
            code: 1, stderr: "Error: This card changed — look again\n"))
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: runner)
        await vm.follow(tower)

        await vm.pressReply(outputID: id, action: 1, contentHash: "stale")

        XCTAssertEqual(runner.invocations.first?.suffix(3), ["--content-hash", "stale", "--json"])
        XCTAssertEqual(vm.lastError, "This card changed — look again")
        XCTAssertEqual(vm.outputRows.map(\.id), [id])
    }

    /// Cobra prints a refusal as "Error: <text>"; the banner shows the text.
    func testCLIRefusalDropsTheErrorPrefix() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let (id, tower) = try seed(pool)
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: Sent — run #7\n"))
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: runner)
        await vm.follow(tower)

        await vm.pressReply(outputID: id, action: 1, contentHash: "h1")

        XCTAssertEqual(vm.lastError, "Sent — run #7")
    }
}
