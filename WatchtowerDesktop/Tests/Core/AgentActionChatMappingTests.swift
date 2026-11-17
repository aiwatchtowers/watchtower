import ChatWire
import GRDB
import XCTest
@testable import WatchtowerCore

/// The Mac's `agent_actions` row → the one approval-card model (`ChatWire.ChatAgentAction`, ask #1409).
final class AgentActionChatMappingTests: XCTestCase {
    func testRowInitReadsEveryColumn() {
        let action = AgentAction(row: Row([
            "id": 7, "tool": "create_jira_issue", "external": true, "args_json": #"{"summary":"x"}"#,
            "reason": "asked", "surface": "main", "conversation_id": 3, "context_type": "reaction",
            "context_id": "C1@1.2", "turn_id": "t9", "status": "failed", "trust_at_create": "execute",
            "result_json": #"{"url":"https://example.com/acme-1"}"#, "error": "boom",
            "created_at": "2026-01-01T00:00:00Z", "decided_at": "2026-01-01T00:01:00Z",
            "applied_at": "2026-01-01T00:02:00Z", "dismissed_at": "2026-01-01T00:03:00Z"
        ]))
        let expected = ChatAgentAction(
            id: 7, tool: "create_jira_issue", external: true, argsJSON: #"{"summary":"x"}"#, argsSHA256: "",
            argsComplete: true, reason: "asked", surface: "main", conversationID: 3, contextType: "reaction",
            contextID: "C1@1.2", turnID: "t9", status: "failed", trustAtCreate: "execute",
            resultJSON: #"{"url":"https://example.com/acme-1"}"#, error: "boom", createdAt: "2026-01-01T00:00:00Z",
            decidedAt: "2026-01-01T00:01:00Z", appliedAt: "2026-01-01T00:02:00Z", dismissedAt: "2026-01-01T00:03:00Z"
        )
        XCTAssertEqual(action, expected)
    }

    /// A row read before a column existed keeps the column defaults.
    func testRowInitDefaultsMissingColumns() {
        let action = AgentAction(row: Row(["id": 1, "tool": "create_idea"]))
        XCTAssertEqual(action, ChatAgentAction(id: 1, tool: "create_idea"))
        XCTAssertTrue(action.argsComplete, "a Mac row carries its whole args")
    }
}
