import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox labels an agent-action card an automation run proposed
/// (`context_type='automation_run'`) with "⚙ <name> · run #<n>" (spec §12.5).
@MainActor
final class AgentActionCardLabelTests: XCTestCase {
    func testAutomationRowGetsLabel() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let actionID = try await pool.write { db -> Int64 in
            let automationID = try TestDatabase.insertAutomation(db, slug: "mail-summary", name: "Mail summary")
            var runID: Int64 = 0
            while runID < 12 { runID = try TestDatabase.insertAutomationRun(db, automationID: automationID) }
            return try TestDatabase.insertAgentAction(
                db, surface: "automation", conversationID: 0, contextType: "automation_run", contextID: "12"
            )
        }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())

        vm.refresh()

        XCTAssertEqual(vm.actionLabels[actionID], "⚙ Mail summary · run #12")
        XCTAssertNil(vm.lastError)
    }

    func testOtherRowsHaveNoLabel() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let ids = try await pool.write { db -> [Int64] in
            let automationID = try TestDatabase.insertAutomation(db)
            let runID = try TestDatabase.insertAutomationRun(db, automationID: automationID)
            return [
                try TestDatabase.insertAgentAction(db, turnID: "chat"),
                // Same id in context_id, different context: no label.
                try TestDatabase.insertAgentAction(db, contextType: "target", contextID: String(runID), turnID: "target")
            ]
        }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())

        vm.refresh()

        XCTAssertEqual(vm.actionRows.count, 2)
        for id in ids { XCTAssertNil(vm.actionLabels[id]) }
    }

    func testDeletedAutomationFallsBackToRunOnly() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let actionID = try await pool.write { db in
            try TestDatabase.insertAgentAction(
                db, surface: "automation", conversationID: 0, contextType: "automation_run", contextID: "12"
            )
        }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())

        vm.refresh()

        XCTAssertEqual(vm.actionLabels[actionID], "⚙ automation · run #12")
    }
}
