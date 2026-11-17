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

    // MARK: - The approve digest (AGENT-07)

    /// A payload-built action pins the digest the payload carries, never a hash of its display text.
    func testPayloadBuiltApproveDigestIsThePayloads() {
        let action = ChatAgentAction(payload: ChatApprovalPayload(
            id: 1, tool: "create_idea", title: "", argsDisplay: "{\n  \"essence\": \"x\"\n}", argsSHA256: "abc123",
            status: "pending"
        ))
        XCTAssertFalse(action.argsStored)
        XCTAssertEqual(action.approveDigest, "abc123")

        let noDigest = ChatAgentAction(payload: ChatApprovalPayload(
            id: 1, tool: "create_idea", title: "", argsDisplay: "{}", argsSHA256: "", status: "pending"
        ))
        XCTAssertNil(noDigest.approveDigest, "display text is never hashed")
    }

    /// A row-built action hashes its stored args (Go `tools.ArgsSHA256`).
    func testRowBuiltApproveDigestHashesTheStoredArgs() {
        let action = ChatAgentAction(id: 1, tool: "create_idea", argsJSON: "{}")
        XCTAssertTrue(action.argsStored)
        // sha256("{}")
        XCTAssertEqual(action.approveDigest, "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
    }

    // MARK: - Clipped args: too long to show here, not unreadable

    private func clipped(_ tool: String, _ display: String) -> ChatAgentAction {
        ChatAgentAction(payload: ChatApprovalPayload(
            id: 4, tool: tool, title: "", argsDisplay: display, argsSHA256: "abc", status: "pending", argsComplete: false
        ))
    }

    func testClippedSlackSaysTooLong() {
        let action = clipped(SlackSendProposal.tool, #"{"text":"aaaa…"#)
        XCTAssertTrue(action.argsClipped)
        XCTAssertNil(SlackSendProposal(action: action))
        XCTAssertEqual(ActionSummaryLines.summaryLines(for: action), [SlackSendProposal.clippedNote])
        XCTAssertEqual(action.approveDigest, "abc", "Approve stays, pinned")
    }

    func testClippedConnectorCallIsNotUnreadable() {
        let action = clipped(ConnectorCallProposal.tool, #"{"input":{"body":"aaaa…"#)
        XCTAssertTrue(action.argsClipped)
        XCTAssertFalse(ConnectorCallProposal.isUnreadable(action))
        XCTAssertTrue(ConnectorCallProposal.canApprove(action, sessionHolds: true))
        XCTAssertEqual(ActionSummaryLines.summaryLines(for: action), [ConnectorCallProposal.clippedNote])

        // Whole args that cannot be read stay unreadable.
        let broken = ChatAgentAction(id: 4, tool: ConnectorCallProposal.tool, argsJSON: #"{"server":"s"}"#)
        XCTAssertTrue(ConnectorCallProposal.isUnreadable(broken))
    }

    func testClippedConfluenceEditKeepsApproveBehindItsFlag() {
        let action = clipped(ConfluenceEdit.tool, #"{"base_version":7,"new_storage":"<p>aaaa…"#)
        XCTAssertTrue(action.argsClipped)
        XCTAssertNil(ConfluenceEdit.proposal(for: action), "no diff")
        XCTAssertEqual(ConfluenceEdit.canApprove(action), ConfluenceEdit.allowsApproveWhenClipped)
        XCTAssertTrue(ConfluenceEdit.allowsApproveWhenClipped, "today's phone behaviour until the owner decides (F7)")
        XCTAssertEqual(ActionSummaryLines.summaryLines(for: action), [ConfluenceEdit.clippedNote])

        // Whole args without changes stay unreadable, and offer no Approve (F7).
        let unreadable = ChatAgentAction(id: 4, tool: ConfluenceEdit.tool, argsJSON: #"{"base_version":7}"#)
        XCTAssertFalse(unreadable.argsClipped)
        XCTAssertFalse(ConfluenceEdit.canApprove(unreadable))
        XCTAssertEqual(ActionSummaryLines.summaryLines(for: unreadable), ["Unreadable Confluence edit proposal"])
    }

    /// An older daemon's payload says nothing of completeness; whole args that parse are read as usual.
    func testIncompleteButParsableArgsAreNotClipped() {
        let action = clipped("create_idea", #"{"essence":"x"}"#)
        XCTAssertFalse(action.argsClipped)
        XCTAssertEqual(ActionSummaryLines.summaryLines(for: action), ["x"])
    }
}
