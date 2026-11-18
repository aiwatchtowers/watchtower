import ChatWire
import GRDB
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The `claude_ai_connector_call` card on the Mac (#737, spec
/// 2026-10-16-chat-claude-ai-tools-design D5): such a row never offers Retry
/// nor waits on the owner once it failed, and its approve pins the args
/// shown. The pure half (args, patch, labels) is `ChatWire`'s
/// `ConnectorCallProposalTests`.
@MainActor
final class ConnectorCallProposalTests: XCTestCase {
    nonisolated private static let args =
        #"{"server":"claude.ai Connector A","tool":"send_message","input":{"to":"a@example.com","n":2},"reason":"asked"}"#

    private func action(
        args: String = args,
        status: String = "pending",
        error: String = "",
        tool: String = ConnectorCallProposal.tool,
        turnID: String = "t1",
        dismissedAt: String = ""
    ) -> AgentAction {
        AgentAction(row: Row([
            "id": 9, "tool": tool, "external": true, "args_json": args, "reason": "asked", "surface": "main",
            "conversation_id": 1, "context_type": "", "context_id": "", "turn_id": turnID, "status": status,
            "trust_at_create": "ask", "result_json": "", "error": error,
            "created_at": "", "decided_at": "", "applied_at": "", "dismissed_at": dismissedAt
        ]))
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
    /// the owner — unless its outcome is unknown (below); on the strip it is
    /// part of the recent terminal tail.
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
            // Every other failed reason provably sent nothing: settled too.
            for reason in [ConnectorCallProposal.stopped, "connector said no"] {
                _ = try TestDatabase.insertAgentAction(
                    db, tool: call, external: true, argsJSON: Self.args, status: "failed", error: reason,
                    appliedAt: "2025-12-01T00:00:00Z")
            }
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

    /// Owner decision (ask #342): a call whose session ended while it ran may
    /// have reached the connector, so it waits on the owner — badge, Home and
    /// the strip's non-terminal group — until Dismiss; then it is settled.
    func testOutcomeUnknownAwaitsTheOwnerUntilDismissed() throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let since = "2026-01-01T00:00:00Z"
        let (unknown, applied) = try pool.write { db in
            // Failed long before the tail's floor: still waits on the owner.
            let unknown = try TestDatabase.insertAgentAction(
                db, tool: ConnectorCallProposal.tool, external: true, argsJSON: Self.args, status: "failed",
                error: ConnectorCallProposal.sessionEndedWhileRunning, appliedAt: "2025-12-01T00:00:00Z")
            let applied = try TestDatabase.insertAgentAction(
                db, status: "applied", createdAt: "2026-09-05T10:00:00Z", decidedAt: "2026-02-01T00:00:00Z")
            return (unknown, applied)
        }
        try pool.read { db in
            XCTAssertEqual(try AgentActionQueries.awaitingOwnerCount(db), 1)
            XCTAssertEqual(try AgentActionQueries.awaitingOwner(db, limit: 10).map(\.id), [unknown])
            XCTAssertEqual(try AgentActionQueries.fetchStrip(db, terminalSince: since).map(\.id), [unknown, applied],
                           "an undismissed unknown outcome sorts with the non-terminal rows")
        }
        // What `actions dismiss` writes (Go `DismissSessionCall`).
        try pool.write { db in
            try db.execute(sql: "UPDATE agent_actions SET dismissed_at = '2026-01-02T00:00:00Z' WHERE id = ?",
                           arguments: [unknown])
        }
        try pool.read { db in
            XCTAssertEqual(try AgentActionQueries.awaitingOwnerCount(db), 0)
            XCTAssertEqual(try AgentActionQueries.awaitingOwner(db, limit: 10).map(\.id), [])
            XCTAssertEqual(try AgentActionQueries.fetchStrip(db, terminalSince: since).map(\.id), [applied, unknown],
                           "a dismissed one is settled: in the tail while its dismissal is recent")
            XCTAssertEqual(try AgentActionQueries.fetchStrip(db, terminalSince: "2026-01-03T00:00:00Z").map(\.id),
                           [applied], "and off the strip once both its failure and its dismissal are old")
            let row = try XCTUnwrap(AgentAction.fetchOne(db, sql: "SELECT * FROM agent_actions WHERE id = ?",
                                                         arguments: [unknown]))
            XCTAssertEqual(row.dismissedAt, "2026-01-02T00:00:00Z")
            XCTAssertFalse(ConnectorCallProposal.awaitsDismissal(row))
        }
    }

    /// The card's Dismiss runs `actions dismiss <id>` (Go owns every
    /// agent_actions write) and re-reads the rows.
    func testFeedDismissRunsTheCLI() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let id = try await pool.write { db in
            try TestDatabase.insertAgentAction(db, tool: ConnectorCallProposal.tool, external: true, argsJSON: Self.args,
                                               status: "failed", error: ConnectorCallProposal.sessionEndedWhileRunning)
        }
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"error":""}"#.utf8))
        let feed = AgentActionFeed(dbPool: pool, cliRunner: runner)
        feed.start(conversationID: 1)
        feed.refresh()
        XCTAssertTrue(ConnectorCallProposal.awaitsDismissal(try XCTUnwrap(feed.rows.first { $0.id == id })))
        await feed.dismiss(id)
        XCTAssertEqual(runner.invocations, [["actions", "dismiss", String(id), "--json"]])
        XCTAssertNil(feed.rowErrors[id])
        XCTAssertFalse(feed.inFlight.contains(id))
        feed.stop()
    }
}
