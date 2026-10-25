import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// A Reply press goes through `watchtower automations reply` (AUTO-09: the
/// CLI records the press and only queues a run); the Desktop writes nothing
/// for it (STRIP-02).
@MainActor
final class InboxReplyPressTests: XCTestCase {
    private func seed(_ pool: DatabasePool) async throws -> Int64 {
        try await pool.write { db in
            let automationID = try TestDatabase.insertAutomation(db, slug: "triage", name: "Triage")
            let runID = try TestDatabase.insertAutomationRun(db, automationID: automationID)
            _ = try TestDatabase.insertAgentAction(db)
            return try TestDatabase.insertAutomationOutput(
                db, automationID: automationID, runID: runID,
                actionsJSON: #"[{"label":"Open","kind":"link","open":"https://example.com"},"#
                    + #"{"label":"Backlog","kind":"reply","reply":"backlog","data":{"id":"A-1"}}]"#
            )
        }
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
        let id = try await seed(pool)
        let before = try dump(pool)
        let runner = FakeCLIRunner(stdout: Data(#"{"run_id":7,"daemon_running":true}"#.utf8))
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: runner)
        await vm.refresh()

        await vm.pressReply(outputID: id, action: 1)

        XCTAssertEqual(runner.invocations,
                       [["automations", "reply", "--output", String(id), "--action", "1", "--json"]])
        XCTAssertEqual(try dump(pool), before)
        XCTAssertNil(vm.lastError)
        XCTAssertFalse(vm.isWriting(output: id))
    }

    func testSecondPressWhileWritingIsDropped() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let id = try await seed(pool)
        let runner = FakeCLIRunner(stdout: Data(#"{"run_id":7,"daemon_running":true}"#.utf8))
        runner.blockUntilCancelled = true
        runner.returnDataOnCancelInsteadOfThrowing = true
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: runner)
        await vm.refresh()

        let first = Task { await vm.pressReply(outputID: id, action: 1) }
        await waitUntil { runner.invocations.count == 1 }
        XCTAssertTrue(vm.isWriting(output: id))

        await vm.pressReply(outputID: id, action: 1)
        XCTAssertEqual(runner.invocations.count, 1)

        first.cancel()
        await first.value
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertFalse(vm.isWriting(output: id))
    }

    func testCLIFailureKeepsCardAndSaysWhy() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let id = try await seed(pool)
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: Sent — run #7\n"))
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: runner)
        await vm.refresh()

        await vm.pressReply(outputID: id, action: 1)

        XCTAssertTrue(vm.lastError?.contains("Sent — run #7") == true, vm.lastError ?? "nil")
        XCTAssertEqual(vm.outputRows.map(\.id), [id])
    }

    /// Cobra prints a refusal as "Error: <text>"; the banner shows the text.
    func testCLIRefusalDropsTheErrorPrefix() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let id = try await seed(pool)
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: Sent — run #7\n"))
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: runner)
        await vm.refresh()

        await vm.pressReply(outputID: id, action: 1)

        XCTAssertEqual(vm.lastError, "Sent — run #7")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met in \(timeout)s")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
