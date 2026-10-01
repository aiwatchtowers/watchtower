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

    // MARK: - Shared Go fixtures (dual path, spec §4.1 item 4)

    /// `internal/chat/testdata` — the files Go's
    /// `TestActionsContract_MatchesSharedFixtures` pins `chat.ActionsContract`
    /// to. Both sides read the SAME files, so a one-sided edit fails here or there.
    private static func goFixture(_ surface: String) throws -> String {
        let path = URL(fileURLWithPath: #filePath)   // …/WatchtowerDesktop/Tests/Core/<this file>
            .deletingLastPathComponent()              // …/Tests/Core
            .deletingLastPathComponent()              // …/Tests
            .deletingLastPathComponent()              // …/WatchtowerDesktop
            .deletingLastPathComponent()              // repo root
            .appendingPathComponent("internal/chat/testdata/actions_contract_\(surface).txt")
        let raw = try String(contentsOf: path, encoding: .utf8)
        return raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
    }

    func testPromptBlocksMatchTheGoFixturesByteForByte() throws {
        XCTAssertEqual(AgentToolsContract.promptBlock(surface: .main), try Self.goFixture("main"))
        XCTAssertEqual(AgentToolsContract.promptBlock(surface: .target), try Self.goFixture("target"))
    }

    func testBothBlocksTeachConfluenceEditing() {
        for surface in [AgentSurface.main, .target] {
            let block = AgentToolsContract.promptBlock(surface: surface)
            XCTAssertTrue(block.contains("- edit_confluence_page — "), "\(surface)")
            XCTAssertTrue(block.contains("read it with get_confluence_page first"), "\(surface)")
            XCTAssertTrue(block.contains("pass its version as base_version"), "\(surface)")
            XCTAssertTrue(block.contains("Keep every ⟦…⟧ marker you do not mean to delete, verbatim"), "\(surface)")
        }
    }

    func testTargetBlockOffersTheJiraIssueWrites() {
        let block = AgentToolsContract.promptBlock(surface: .target)
        for tool in ["add_jira_comment", "transition_jira_issue", "assign_jira_issue", "update_jira_issue"] {
            XCTAssertTrue(block.contains("- \(tool) — "), tool)
        }
        for tool in ["create_track", "create_idea", "remind_me"] {
            XCTAssertFalse(block.contains("- \(tool) — "), "\(tool) is main-chat only")
        }
    }
}
