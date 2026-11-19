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
        // Mail summary's runs 1–12; action 1 proposed by run 12.
        let tower = try FeedCaseTransport.seeded("desktop_label_automation_run", pool: pool)
        let actionID: Int64 = 1
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())

        await vm.follow(tower)

        XCTAssertEqual(vm.actionLabels[actionID], "⚙ Mail summary · run #12")
        XCTAssertNil(vm.lastError)
    }

    func testOtherRowsHaveNoLabel() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        // Run 1; action 1 from a chat, action 2 with run 1's id in context_id
        // but another context: no label.
        let tower = try FeedCaseTransport.seeded("desktop_label_other_rows", pool: pool)
        let ids: [Int64] = [1, 2]
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())

        await vm.follow(tower)

        XCTAssertEqual(vm.actionRows.count, 2)
        for id in ids { XCTAssertNil(vm.actionLabels[id]) }
    }

    func testDeletedAutomationFallsBackToRunOnly() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        // Action 1 proposed by run 12 of an automation that is gone.
        let tower = try FeedCaseTransport.seeded("desktop_label_deleted_automation", pool: pool)
        let actionID: Int64 = 1
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())

        await vm.follow(tower)

        XCTAssertEqual(vm.actionLabels[actionID], "⚙ automation · run #12")
    }
}
