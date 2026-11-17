import XCTest
@testable import ChatWire

/// The one agent-action model of both devices' approval card (ask #1409), built from the `approval` payload.
final class ChatAgentActionTests: XCTestCase {
    func testFromPayloadMapsEveryField() throws {
        let payload = ChatApprovalPayload(
            id: 9, tool: "create_jira_issue", title: "Create jira issue", argsDisplay: #"{"summary":"x"}"#,
            argsSHA256: "abc123", status: "applied", reason: "asked", external: true, error: "boom",
            result: ["url": "https://example.com/acme-1", "label": "ACME-1", "target_id": "7"], turnID: "t1",
            argsComplete: true
        )
        let action = ChatAgentAction(payload: payload)
        XCTAssertEqual(action.id, 9)
        XCTAssertEqual(action.tool, "create_jira_issue")
        XCTAssertEqual(action.argsJSON, #"{"summary":"x"}"#)
        XCTAssertEqual(action.argsSHA256, "abc123")
        XCTAssertEqual(action.status, "applied")
        XCTAssertEqual(action.reason, "asked")
        XCTAssertTrue(action.external)
        XCTAssertEqual(action.error, "boom")
        XCTAssertEqual(action.turnID, "t1")
        XCTAssertTrue(action.argsComplete)
        XCTAssertEqual(action.resultString("url"), "https://example.com/acme-1")
        XCTAssertEqual(action.resultString("label"), "ACME-1")
        XCTAssertEqual(action.resultWebURL("url"), URL(string: "https://example.com/acme-1"))
        XCTAssertEqual(action.argString("summary"), "x")

        // A payload from a daemon one version behind: the card fields at their defaults.
        let old = try ChatWireCoder.makeDecoder().decode(ChatApprovalPayload.self, from: Data(#"""
            {"id": 3, "tool": "send_slack_message", "title": "Send slack message", "args_display": "{}",
             "args_sha256": "def", "status": "pending"}
            """#.utf8))
        let fromOld = ChatAgentAction(payload: old)
        XCTAssertFalse(fromOld.external)
        XCTAssertEqual(fromOld.error, "")
        XCTAssertEqual(fromOld.resultJSON, "")
        XCTAssertEqual(fromOld.turnID, "")
        XCTAssertFalse(fromOld.argsComplete)
        XCTAssertEqual(fromOld.reason, "")
        XCTAssertTrue(fromOld.isPending)
    }

    func testClippedArgsYieldNoEditableProposal() throws {
        let args = ##"{"text":"hi","target":{"account_id":1,"workspace":"Acme","channel_id":"CGEN","label":"#general"}}"##
        func action(complete: Bool) -> ChatAgentAction {
            ChatAgentAction(payload: ChatApprovalPayload(
                id: 7, tool: SlackSendProposal.tool, title: "", argsDisplay: args, argsSHA256: "abc",
                status: "pending", argsComplete: complete
            ))
        }
        let clipped = try XCTUnwrap(SlackSendProposal(action: action(complete: false)), "still read for display")
        XCTAssertEqual(clipped.recipientLine, "To: #general in Acme")
        XCTAssertEqual(clipped.text, "hi")
        XCTAssertFalse(clipped.editable)
        XCTAssertTrue(try XCTUnwrap(SlackSendProposal(action: action(complete: true))).editable)
    }
}
