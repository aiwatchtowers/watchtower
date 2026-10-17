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
    nonisolated private static let args = #"{"server":"claude.ai Connector A","tool":"send_message","input":{"to":"a@example.com","n":2},"reason":"asked"}"#

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
              "n" : 2,
              "to" : "a@example.com"
            }
            """)
        XCTAssertNil(ConnectorCallProposal(action: action(tool: "send_slack_message")), "another tool")
        XCTAssertNil(ConnectorCallProposal(action: action(args: #"{"server":"s","tool":"t","input":[1]}"#)),
                     "an input that is not an object is unreadable")
        XCTAssertNil(ConnectorCallProposal(action: action(args: "not json")))
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
        XCTAssertEqual(Card.statusLabel(for: action(status: "pending")), "Awaiting your approval")
        XCTAssertEqual(Card.statusLabel(for: action(status: "approved")), "Approved — the chat is running it")
        XCTAssertEqual(Card.statusLabel(for: action(status: "executing")), "Running…")
        XCTAssertEqual(Card.statusLabel(for: action(status: "applied")), "Done")
        XCTAssertEqual(Card.statusLabel(for: action(status: "rejected", error: Card.notApprovedInTime)),
                       "Cancelled — not approved in time")
        XCTAssertEqual(Card.statusLabel(for: action(status: "rejected", error: Card.stopped)), "Cancelled — chat stopped")
        XCTAssertEqual(Card.statusLabel(for: action(status: "rejected")), "Rejected")
        XCTAssertEqual(Card.statusLabel(for: action(status: "failed", error: "connector said no")),
                       "Failed — connector said no")
        XCTAssertEqual(Card.statusLabel(for: action(status: "failed")), "Failed")
        XCTAssertEqual(Card.statusLabel(for: action(status: "failed", error: Card.sessionEndedBeforeApproval)),
                       "Chat session ended — not sent")
        XCTAssertEqual(Card.statusLabel(for: action(status: "failed", error: Card.sessionEndedWhileRunning)),
                       "Chat session ended — outcome unknown")
    }

    /// The controller's H2 default: an approval the dead session can never
    /// claim must not read as a call about to run, nor offer Approve.
    func testSessionEndedIsNeverShownAsRunning() {
        typealias Card = ConnectorCallProposal
        XCTAssertEqual(Card.statusLabel(for: action(status: "approved"), sessionHolds: false), "Chat session ended — not sent")
        XCTAssertEqual(Card.statusLabel(for: action(status: "pending"), sessionHolds: false),
                       "Chat session ended — can no longer run")
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
        XCTAssertTrue(Card.sessionHolds(action(turnID: ""), runningTurnID: "t2"))
        XCTAssertFalse(Card.sessionHolds(action(turnID: ""), runningTurnID: nil))
    }

    func testSessionCallsOfferNoRetry() {
        for status in ["approved", "failed"] {
            XCTAssertFalse(action(status: status).canRetry, status)
            XCTAssertTrue(action(status: status, tool: "create_jira_issue").canRetry, status)
        }
        XCTAssertTrue(action(status: "failed").isTerminal, "nothing can retry a failed session call")
        XCTAssertFalse(action(status: "failed", tool: "create_jira_issue").isTerminal)
        XCTAssertFalse(action(status: "approved").isTerminal)
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
