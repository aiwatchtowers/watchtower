import GRDB
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The `claude_ai_connector_call` card's pure half (#737, spec
/// 2026-10-16-chat-claude-ai-tools-design D5): what the card reads from the
/// args, the `--patch` an input edit sends (Go `reviseConnectorCall` is the
/// twin), the honest status labels of a session-applied row, and that such a
/// row never offers Retry nor waits on the owner once it failed.
@MainActor
final class ConnectorCallProposalTests: XCTestCase {
    nonisolated private static let args =
        #"{"server":"claude.ai Connector A","tool":"send_message","input":{"to":"a@example.com","n":2},"reason":"asked"}"#

    private func action(
        args: String = args,
        status: String = "pending",
        error: String = "",
        tool: String = ConnectorCallProposal.tool,
        turnID: String = "t1"
    ) -> AgentAction {
        AgentAction(row: Row([
            "id": 9, "tool": tool, "external": true, "args_json": args, "reason": "asked", "surface": "main",
            "conversation_id": 1, "context_type": "", "context_id": "", "turn_id": turnID, "status": status,
            "trust_at_create": "ask", "result_json": "", "error": error,
            "created_at": "", "decided_at": "", "applied_at": ""
        ]))
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

    func testSessionCallsOfferNoRetry() {
        for status in ["approved", "failed"] {
            XCTAssertFalse(action(status: status).canRetry, status)
            XCTAssertTrue(action(status: status, tool: "create_jira_issue").canRetry, status)
        }
        // Still not terminal: a failed call whose turn left no message keeps
        // its card in the chat (`AgentActionFeed.unattached`).
        XCTAssertFalse(action(status: "failed").isTerminal)
        XCTAssertEqual(AgentActionFeed.unattached(rows: [action(status: "failed")], messageTurnIDs: []).count, 1)
        XCTAssertTrue(action().isSessionApplied)
    }

    /// AGENT-07: the approve a connector card sends — plain or with the
    /// edited input — pins the digest of the args the card showed.
    func testApproveCarriesArgsDigest() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let id = try await pool.write { db in
            try TestDatabase.insertAgentAction(db, tool: ConnectorCallProposal.tool, external: true, argsJSON: Self.args)
        }
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"error":""}"#.utf8))
        let feed = AgentActionFeed(dbPool: pool, cliRunner: runner)
        let shown = action().argsJSON
        let patch = try XCTUnwrap(XCTUnwrap(ConnectorCallProposal(action: action())).patch(editedInput: #"{"to":"b"}"#))
        await feed.approve(id, shownArgs: shown)
        await feed.approve(id, shownArgs: shown, patch: patch)
        let digest = AgentActionFeed.argsSHA256(Self.args)
        XCTAssertEqual(runner.invocations, [
            ["actions", "approve", String(id), "--args-sha256", digest, "--json"],
            ["actions", "approve", String(id), "--args-sha256", digest, "--patch", #"{"input":{"to":"b"}}"#, "--json"]
        ])
    }

    /// "Approve all" leaves a connector call to its own card, which offers
    /// Approve only while the call is readable and its session holds it.
    func testApproveAllSkipsSessionCalls() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let call = try await pool.write { db in
            _ = try TestDatabase.insertAgentAction(db, turnID: "t1")
            _ = try TestDatabase.insertAgentAction(db, turnID: "t1")
            return try TestDatabase.insertAgentAction(db, tool: ConnectorCallProposal.tool, external: true,
                                                      argsJSON: Self.args, turnID: "t1")
        }
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"error":""}"#.utf8))
        let feed = AgentActionFeed(dbPool: pool, cliRunner: runner)
        feed.start(conversationID: 1)
        feed.refresh()
        XCTAssertEqual(feed.bulkApprovable(forTurn: "t1").count, 2)
        await feed.approveAllPending(forTurn: "t1")
        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertFalse(runner.invocations.contains { $0.contains(String(call)) })
        feed.stop()
    }

    /// A failed connector call has no Retry, so it never counts as waiting on
    /// the owner; on the strip it is part of the recent terminal tail.
    func testFailedSessionCallIsNotAwaitingTheOwner() throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let since = "2026-01-01T00:00:00Z"
        let call = ConnectorCallProposal.tool
        let (pending, failedRecent, jiraFailed) = try pool.write { db in
            let pending = try TestDatabase.insertAgentAction(db, tool: call, external: true, argsJSON: Self.args)
            let recent = try TestDatabase.insertAgentAction(
                db, tool: call, external: true, argsJSON: Self.args, status: "failed",
                error: ConnectorCallProposal.sessionEndedBeforeApproval, appliedAt: "2026-02-01T00:00:00Z")
            // Failed before the tail's floor: off the strip altogether.
            _ = try TestDatabase.insertAgentAction(
                db, tool: call, external: true, argsJSON: Self.args, status: "failed", appliedAt: "2025-12-01T00:00:00Z")
            let jira = try TestDatabase.insertAgentAction(db, tool: "create_jira_issue", external: true, status: "failed")
            return (pending, recent, jira)
        }
        try pool.read { db in
            XCTAssertEqual(try AgentActionQueries.awaitingOwnerCount(db), 2)
            XCTAssertEqual(Set(try AgentActionQueries.awaitingOwner(db, limit: 10).map(\.id)), [pending, jiraFailed])
            let strip = try AgentActionQueries.fetchStrip(db, terminalSince: since).map(\.id)
            XCTAssertEqual(Set(strip), [pending, jiraFailed, failedRecent])
            XCTAssertEqual(strip.last, failedRecent, "a failed session call sorts with the terminal tail")
        }
    }
}
