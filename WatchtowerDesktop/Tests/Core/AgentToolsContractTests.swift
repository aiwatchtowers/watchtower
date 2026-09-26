import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

final class AgentToolsContractTests: XCTestCase {
    func testMainBlockListsBothWriteTools() {
        let block = AgentToolsContract.promptBlock(surface: .main)
        XCTAssertTrue(block.contains("=== AGENT ACTIONS ==="))
        XCTAssertTrue(block.contains("create_target"))
        XCTAssertTrue(block.contains("create_jira_issue"))
        XCTAssertTrue(block.contains("list_jira_projects"))
        XCTAssertTrue(block.contains("get_action"))
        XCTAssertTrue(block.contains("never claim"))
        XCTAssertTrue(block.contains("awaits their approval"))
    }

    func testTargetBlockOmitsCreateTargetAndDrawsTheLine() {
        let block = AgentToolsContract.promptBlock(surface: .target)
        XCTAssertFalse(block.contains("create_target"))
        XCTAssertTrue(block.contains("create_jira_issue"))
        XCTAssertTrue(block.contains("watchtower-action"), "coexistence rule with the block grammar")
    }

    func testNoToolsBlockIsHonest() {
        XCTAssertTrue(AgentToolsContract.noToolsBlock.contains("No tools are connected"))
        XCTAssertFalse(AgentToolsContract.noToolsBlock.contains("create_"))
    }

    func testActionsSinceLastTurnRendersOutcomes() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertAgentAction(db, tool: "create_jira_issue", status: "applied",
                                               resultJSON: #"{"key":"ABC-7","url":"https://x/browse/ABC-7"}"#,
                                               appliedAt: "2026-09-04T10:05:00Z")
            try TestDatabase.insertAgentAction(db, status: "rejected", decidedAt: "2026-09-04T10:06:00Z")
            try TestDatabase.insertAgentAction(db, status: "failed", error: "issuetype: invalid", appliedAt: "2026-09-04T10:07:00Z")
        }
        let rows = try queue.read { db in try AgentActionQueries.fetchByConversation(db, conversationID: 1) }
        let block = try XCTUnwrap(AgentToolsContract.actionsSinceLastTurnBlock(rows))
        XCTAssertTrue(block.hasPrefix("=== ACTIONS SINCE YOUR LAST MESSAGE ==="))
        XCTAssertTrue(block.contains("#1 create_jira_issue: applied"))
        XCTAssertTrue(block.contains("ABC-7"))
        XCTAssertTrue(block.contains("#2 create_target: rejected"))
        XCTAssertTrue(block.contains("#3 create_target: failed — issuetype: invalid"))
        XCTAssertNil(AgentToolsContract.actionsSinceLastTurnBlock([]))
    }
}
