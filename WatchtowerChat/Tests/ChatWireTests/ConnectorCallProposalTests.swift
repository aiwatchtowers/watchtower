import XCTest
@testable import ChatWire

/// The `claude_ai_connector_call` card's pure half (#737, spec
/// 2026-10-16-chat-claude-ai-tools-design D5): what the card reads from the
/// args, the `--patch` an input edit sends (Go `reviseConnectorCall` is the
/// twin) and the honest status labels of a session-applied row. The feed and
/// strip half stays in the Desktop's `ConnectorCallProposalTests`.
final class ConnectorCallProposalTests: XCTestCase {
    private static let args =
        #"{"server":"claude.ai Connector A","tool":"send_message","input":{"to":"a@example.com","n":2},"reason":"asked"}"#

    private func action(
        args: String = args,
        status: String = "pending",
        error: String = "",
        tool: String = ConnectorCallProposal.tool,
        turnID: String = "t1",
        dismissedAt: String = ""
    ) -> ChatAgentAction {
        ChatAgentAction(id: 9, tool: tool, external: true, argsJSON: args, reason: "asked", surface: "main",
                        conversationID: 1, turnID: turnID, status: status, error: error, dismissedAt: dismissedAt)
    }

    func testConnectorProposalParsesArgs() throws {
        let p = try XCTUnwrap(ConnectorCallProposal(action: action()))
        XCTAssertEqual(p.server, "claude.ai Connector A")
        XCTAssertEqual(p.toolName, "send_message")
        XCTAssertEqual(p.inputJSON, """
            {
              "to": "a@example.com",
              "n": 2
            }
            """)
        XCTAssertNil(ConnectorCallProposal(action: action(tool: "send_slack_message")), "another tool")
        XCTAssertNil(ConnectorCallProposal(action: action(args: #"{"server":"s","tool":"t","input":[1]}"#)),
                     "an input that is not an object is unreadable")
        XCTAssertNil(ConnectorCallProposal(action: action(args: "not json")))
        XCTAssertNil(ConnectorCallProposal(action: action(args: #"{"tool":"t","input":{}}"#)), "no server")
        XCTAssertNil(ConnectorCallProposal(action: action(args: #"{"server":"s","tool":"","input":{}}"#)), "empty tool")
    }

    /// The card shows the input as stored: numbers are never re-encoded, key
    /// order is kept, nested values are indented, and a printable `\u`
    /// escape reads as its character.
    func testConnectorInputIsShownAsStored() throws {
        let args = #"{"input":{"z":0.30000000000000001,"big":12345678901234567890,"#
            + #""s":"a,b:{\"q\"}\u00e9","list":[1,{"k":[]}],"e":{}},"server":"s","tool":"t"}"#
        let p = try XCTUnwrap(ConnectorCallProposal(action: action(args: args)))
        XCTAssertEqual(p.inputJSON, #"""
            {
              "z": 0.30000000000000001,
              "big": 12345678901234567890,
              "s": "a,b:{\"q\"}é",
              "list": [
                1,
                {
                  "k": []
                }
              ],
              "e": {}
            }
            """#)
        XCTAssertEqual(p.approval(editedInput: p.inputJSON), .plain)
        // Go's json.Marshal HTML-escapes <, > and &: shown as written; a
        // quote and a control character stay escaped.
        let html = try XCTUnwrap(ConnectorCallProposal(action: action(args:
            #"{"server":"s","tool":"t","input":{"body":"\u003cp\u003eQ\u0026A\u003c/p\u003e \u0022 \u0001 \\u003c"}}"#)))
        XCTAssertEqual(html.inputJSON, #"""
            {
              "body": "<p>Q&A</p> \u0022 \u0001 \\u003c"
            }
            """#)
        let patch = try XCTUnwrap(p.patch(editedInput: p.inputJSON))
        XCTAssertTrue(patch.contains("12345678901234567890"), "an edit keeps untouched numbers as stored")
    }

    func testConnectorProposalPatchNeedsAnObject() throws {
        let p = try XCTUnwrap(ConnectorCallProposal(action: action()))
        XCTAssertEqual(p.patch(editedInput: #"{"to":"b@example.com"}"#), #"{"input":{"to":"b@example.com"}}"#)
        // The typed text is embedded verbatim, number spelling included.
        XCTAssertEqual(p.patch(editedInput: "  {\"n\": 1.50}\n"), #"{"input":{"n": 1.50}}"#)
        for bad in ["[1]", "\"x\"", "null", "", "{", #"{"a":1} {"b":2}"#, "{\"a\":1}}"] {
            XCTAssertNil(p.patch(editedInput: bad), bad)
            XCTAssertNil(p.approval(editedInput: bad), bad)
        }
        XCTAssertEqual(p.approval(editedInput: p.inputJSON), .plain, "untouched input is a plain approve")
        XCTAssertEqual(p.approval(editedInput: #"{"to":"c"}"#), .edited(patch: #"{"input":{"to":"c"}}"#))
    }

    func testConnectorStatusLabels() {
        typealias Card = ConnectorCallProposal
        XCTAssertEqual(Card.statusLabel(for: action(status: "pending"), sessionHolds: true), "Awaiting your approval")
        XCTAssertEqual(Card.statusLabel(for: action(status: "approved"), sessionHolds: true), "Approved — the chat is running it")
        XCTAssertEqual(Card.statusLabel(for: action(status: "executing"), sessionHolds: true), "Running…")
        XCTAssertEqual(Card.statusLabel(for: action(status: "applied"), sessionHolds: true), "Done")
        XCTAssertEqual(Card.statusLabel(for: action(status: "rejected", error: Card.notApprovedInTime), sessionHolds: true),
                       "Cancelled — not approved in time")
        XCTAssertEqual(Card.statusLabel(for: action(status: "rejected", error: Card.stopped), sessionHolds: true), "Cancelled — chat stopped")
        XCTAssertEqual(Card.statusLabel(for: action(status: "rejected"), sessionHolds: true), "Rejected")
        XCTAssertEqual(Card.statusLabel(for: action(status: "failed", error: "connector said no"), sessionHolds: true),
                       "Failed")
        XCTAssertFalse(Card.labelCarriesError(action(status: "failed", error: "connector said no")),
                       "a connector's own error is shown on its own line")
        XCTAssertEqual(Card.statusLabel(for: action(status: "failed", error: Card.stopped), sessionHolds: true),
                       "Chat stopped — not sent")
        for known in [Card.sessionEndedBeforeApproval, Card.sessionEndedWhileRunning, Card.stopped] {
            XCTAssertTrue(Card.labelCarriesError(action(status: "failed", error: known)), known)
        }
        for known in [Card.notApprovedInTime, Card.stopped] {
            XCTAssertTrue(Card.labelCarriesError(action(status: "rejected", error: known)), known)
        }
        XCTAssertFalse(Card.labelCarriesError(action(status: "failed", error: Card.notApprovedInTime)),
                       "a reason the label does not word for this status stays visible")
        XCTAssertFalse(Card.labelCarriesError(action(status: "failed", error: Card.stopped, tool: "create_jira_issue")),
                       "another tool's error is never hidden")
        XCTAssertEqual(Card.statusLabel(for: action(status: "failed"), sessionHolds: true), "Failed")
        XCTAssertEqual(Card.statusLabel(for: action(status: "failed", error: Card.sessionEndedBeforeApproval), sessionHolds: true),
                       "Chat session ended — not sent")
        XCTAssertEqual(Card.statusLabel(for: action(status: "failed", error: Card.sessionEndedWhileRunning), sessionHolds: true),
                       "Chat session ended — outcome unknown")
    }

    /// An approval the dead session can never claim must not read as a call
    /// about to run, nor offer Approve.
    func testSessionEndedIsNeverShownAsRunning() {
        typealias Card = ConnectorCallProposal
        XCTAssertEqual(Card.statusLabel(for: action(status: "approved"), sessionHolds: false), "Chat session ended — not sent")
        XCTAssertEqual(Card.statusLabel(for: action(status: "pending"), sessionHolds: false),
                       "Chat session ended — reject to dismiss")
        XCTAssertEqual(Card.statusLabel(for: action(status: "executing"), sessionHolds: false),
                       "Chat session ended — outcome unknown")
        XCTAssertEqual(Card.statusLabel(for: action(status: "applied"), sessionHolds: false), "Done")
        XCTAssertTrue(Card.canApprove(action(status: "pending"), sessionHolds: true))
        XCTAssertFalse(Card.canApprove(action(status: "pending"), sessionHolds: false))
        XCTAssertFalse(Card.canApprove(action(status: "approved"), sessionHolds: true))
    }

    func testSessionHoldsOnlyItsOwnRunningTurn() {
        typealias Card = ConnectorCallProposal
        XCTAssertTrue(Card.sessionHolds(action(turnID: "t1"), runningTurnID: "t1"))
        XCTAssertFalse(Card.sessionHolds(action(turnID: "t1"), runningTurnID: "t2"), "a later turn of the session")
        XCTAssertFalse(Card.sessionHolds(action(turnID: "t1"), runningTurnID: nil), "no live session running a turn")
        XCTAssertFalse(Card.sessionHolds(action(turnID: ""), runningTurnID: "t2"), "no turn id ties it to a turn")
        XCTAssertFalse(Card.sessionHolds(action(turnID: ""), runningTurnID: nil))
    }

    func testAwaitsDismissalOnlyForAnUndismissedUnknownOutcome() {
        typealias Card = ConnectorCallProposal
        XCTAssertTrue(Card.awaitsDismissal(action(status: "failed", error: Card.sessionEndedWhileRunning)))
        XCTAssertFalse(Card.awaitsDismissal(action(status: "failed", error: Card.sessionEndedWhileRunning,
                                                   dismissedAt: "2026-01-01T00:00:00Z")))
        for other in [Card.sessionEndedBeforeApproval, Card.stopped, "connector said no"] {
            XCTAssertFalse(Card.awaitsDismissal(action(status: "failed", error: other)), other)
        }
        XCTAssertFalse(Card.awaitsDismissal(action(status: "executing")))
        XCTAssertFalse(Card.awaitsDismissal(action(status: "failed", error: Card.sessionEndedWhileRunning,
                                                   tool: "create_jira_issue")))
    }
}
