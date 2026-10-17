import XCTest
import GRDB
import WatchtowerCore
import WatchtowerTestSupport

final class TerminalSessionQueriesTests: XCTestCase {
    private func claude(_ project: Int64?, _ title: String = "Session", target: Int64? = nil)
        -> TerminalSessionQueries.NewSession {
        .init(projectID: project, kind: .claude, title: title, targetID: target,
              folderPath: "/tmp/acme", claudeSessionID: UUID().uuidString)
    }

    private func codex(_ project: Int64?, _ title: String = "Codex") -> TerminalSessionQueries.NewSession {
        .init(projectID: project, kind: .codex, title: title, folderPath: "/tmp/acme")
    }

    func testCodexRowWithNullIDDecodes() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let row = try TerminalSessionQueries.create(db, codex(project))
            XCTAssertEqual(row.kind, .codex)
            XCTAssertEqual(row.kind.agent, .codex)
            XCTAssertTrue(row.kind.isAgent)
            XCTAssertNil(row.claudeSessionID, "Codex mints its id: a new codex row has none")
            XCTAssertNil(row.transcriptPath)
            let path = "/Users/example/.codex/sessions/2026/10/12/rollout-x.jsonl"
            try db.execute(
                sql: "UPDATE terminal_sessions SET claude_session_id = ?, agent_transcript_path = ? WHERE id = ?",
                arguments: ["00000000-0000-7000-8000-000000000001", path, row.id]
            )
            let stored = try XCTUnwrap(TerminalSessionQueries.fetch(db, id: row.id))
            XCTAssertEqual(stored.claudeSessionID, "00000000-0000-7000-8000-000000000001")
            XCTAssertEqual(stored.transcriptPath, path)
            XCTAssertEqual(try TerminalSessionQueries.fetchForWorkbench(db, projectID: project).map(\.id), [row.id])
        }
    }

    func testInsertClaudeWithoutIDIsRejected() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            for id in [nil, ""] as [String?] {
                let new = TerminalSessionQueries.NewSession(
                    projectID: nil, kind: .claude, title: "s", folderPath: "/tmp/acme", claudeSessionID: id
                )
                XCTAssertThrowsError(try TerminalSessionQueries.create(db, new), "id \(String(describing: id))") {
                    XCTAssertEqual($0 as? TerminalSessionQueryError, .missingSessionID)
                }
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM terminal_sessions"), 0)
            // A shell and a codex row need no id.
            let shell = try TerminalSessionQueries.create(
                db, .init(projectID: nil, kind: .shell, title: "zsh", folderPath: "/tmp/acme")
            )
            XCTAssertNil(shell.claudeSessionID)
            XCTAssertNil(try TerminalSessionQueries.create(db, codex(nil)).claudeSessionID)
        }
    }

    func testResetAgentSessionNullsIDAndPathForCodexOnly() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let cx = try TerminalSessionQueries.create(db, codex(project))
            let cl = try TerminalSessionQueries.create(db, claude(project))
            try db.execute(
                sql: "UPDATE terminal_sessions SET claude_session_id = ?, agent_transcript_path = ? WHERE id IN (?, ?)",
                arguments: ["00000000-0000-7000-8000-000000000002", "/Users/example/t.jsonl", cx.id, cl.id]
            )
            try TerminalSessionQueries.resetAgentSession(db, id: cx.id)
            try TerminalSessionQueries.resetAgentSession(db, id: cl.id)

            let codexRow = try XCTUnwrap(TerminalSessionQueries.fetch(db, id: cx.id))
            XCTAssertNil(codexRow.claudeSessionID)
            XCTAssertNil(codexRow.transcriptPath)
            XCTAssertEqual(codexRow.title, "Codex", "the row and its name stay")
            let claudeRow = try XCTUnwrap(TerminalSessionQueries.fetch(db, id: cl.id))
            XCTAssertEqual(claudeRow.claudeSessionID, "00000000-0000-7000-8000-000000000002",
                           "a claude row keeps its id")
            XCTAssertEqual(claudeRow.transcriptPath, "/Users/example/t.jsonl")
            // Resetting an already reset codex row is a no-op, not an error.
            XCTAssertNoThrow(try TerminalSessionQueries.resetAgentSession(db, id: cx.id))
        }
    }

    /// Seeds every per-conversation column (and the ones a conversation
    /// change keeps) with a non-empty value, as the previous conversation's
    /// hooks left them.
    private func seedConversation(_ db: Database, id: Int64) throws {
        try db.execute(
            sql: """
                UPDATE terminal_sessions SET agent_transcript_path = '/Users/example/old.jsonl',
                    agent_turn_end = 3, agent_tool_run = 2,
                    agent_background = 4, agent_background_at = '2026-10-14T10:00:00.000Z',
                    chat_question = 'Which branch?', chat_question_at = '2026-10-14T10:00:01.000Z',
                    agent_turns = '{"since":"2026-10-14T09:00:00.000Z","turns":{}}',
                    agent_state = 'waiting', agent_state_at = '2026-10-14T10:00:02.000Z',
                    agent_cwd = '/tmp/acme/wt', agent_cwd_at = '2026-10-14T10:00:03.000Z'
                WHERE id = ?
                """,
            arguments: [id]
        )
    }

    /// Board #552: "Start fresh" clears what Go's `SetTerminalClaudeSessionID`
    /// (claude) and `SetTerminalAgentSessionID` (codex) clear on a
    /// conversation change, and keeps what they keep.
    private func assertConversationCleared(_ db: Database, id: Int64, _ label: String) throws {
        let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM terminal_sessions WHERE id = ?",
                                             arguments: [id]))
        for column in ["agent_transcript_path", "agent_turn_end", "agent_background", "agent_background_at",
                       "chat_question", "chat_question_at", "agent_turns"] {
            XCTAssertTrue((row[column] as DatabaseValue).isNull, "\(label): \(column) is cleared")
        }
        XCTAssertEqual(row["agent_tool_run"] as Int?, 0, "\(label): agent_tool_run is reset to 0")
        XCTAssertEqual(row["agent_cwd"] as String?, "/tmp/acme/wt", "\(label): the working directory stays")
        XCTAssertEqual(row["agent_cwd_at"] as String?, "2026-10-14T10:00:03.000Z", label)
        XCTAssertEqual(row["agent_state"] as String?, "waiting", "\(label): the state is the next run mark's")
        XCTAssertEqual(row["agent_state_at"] as String?, "2026-10-14T10:00:02.000Z", label)
    }

    func testStartFreshClearsThePreviousConversationsColumns() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let cl = try TerminalSessionQueries.create(db, claude(project))
            let cx = try TerminalSessionQueries.create(db, codex(project))
            try db.execute(sql: "UPDATE terminal_sessions SET claude_session_id = ? WHERE id = ?",
                           arguments: ["00000000-0000-7000-8000-000000000003", cx.id])
            try seedConversation(db, id: cl.id)
            try seedConversation(db, id: cx.id)

            try TerminalSessionQueries.replaceClaudeSessionID(db, id: cl.id, uuid: "new-id")
            XCTAssertEqual(try TerminalSessionQueries.fetch(db, id: cl.id)?.claudeSessionID, "new-id")
            try assertConversationCleared(db, id: cl.id, "claude")

            try TerminalSessionQueries.resetAgentSession(db, id: cx.id)
            XCTAssertNil(try TerminalSessionQueries.fetch(db, id: cx.id)?.claudeSessionID)
            try assertConversationCleared(db, id: cx.id, "codex")
        }
    }

    func testResetAgentSessionLeavesAClaudeRowsConversationUntouched() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let cl = try TerminalSessionQueries.create(db, claude(project))
            try seedConversation(db, id: cl.id)
            let before = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM terminal_sessions WHERE id = ?",
                                                    arguments: [cl.id]))
            try TerminalSessionQueries.resetAgentSession(db, id: cl.id)
            let after = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM terminal_sessions WHERE id = ?",
                                                   arguments: [cl.id]))
            XCTAssertEqual(after, before, "the codex reset never touches a claude row")
        }
    }

    func testFetchAgentStatesIncludesCodexRows() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db, name: "acme")
            let cl = try TerminalSessionQueries.create(db, claude(project))
            let cx = try TerminalSessionQueries.create(db, codex(project))
            _ = try TerminalSessionQueries.create(
                db, .init(projectID: project, kind: .shell, title: "zsh", folderPath: "/tmp/acme")
            )
            let looseCodex = try TerminalSessionQueries.create(db, codex(nil, "Loose"))
            try db.execute(
                sql: "UPDATE terminal_sessions SET agent_state = 'working', agent_state_at = ? WHERE id = ?",
                arguments: ["2026-10-12T12:00:00.000Z", cx.id]
            )
            let rows = try TerminalSessionQueries.fetchAgentStates(db, liveIDs: [])
            XCTAssertEqual(rows.map(\.id), [cl.id, cx.id], "workbench agents of both kinds; no shell, no standalone")
            XCTAssertEqual(rows[1].agentState, "working")
            XCTAssertEqual(try TerminalSessionQueries.fetchAgentStates(db, liveIDs: [looseCodex.id]).map(\.id),
                           [cl.id, cx.id, looseCodex.id], "a live standalone codex terminal is read too")
        }
    }

    func testMirrorHasTerminalSessionsTable() throws {
        let queue = try TestDatabase.create()
        try queue.read { db in XCTAssertTrue(try db.tableExists("terminal_sessions")) }
    }

    func testCreateAndOrderByLastActiveAfterTouch() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let first = try TerminalSessionQueries.create(db, claude(project, "First"))
            let second = try TerminalSessionQueries.create(db, claude(project, "Second"))
            XCTAssertEqual(first.titleSource, .auto)
            try db.execute(sql: "UPDATE terminal_sessions SET last_active_at = '2026-01-01T00:00:00Z' WHERE id = ?",
                           arguments: [first.id])
            try db.execute(sql: "UPDATE terminal_sessions SET last_active_at = '2026-01-02T00:00:00Z' WHERE id = ?",
                           arguments: [second.id])
            XCTAssertEqual(try TerminalSessionQueries.fetchForWorkbench(db, projectID: project).map(\.id),
                           [second.id, first.id])
            try db.execute(sql: "UPDATE terminal_sessions SET last_active_at = '2020-01-01T00:00:00Z' WHERE id = ?",
                           arguments: [second.id])
            try TerminalSessionQueries.touch(db, id: first.id)
            let touched = try TerminalSessionQueries.fetchForWorkbench(db, projectID: project)
            XCTAssertEqual(touched.map(\.id), [first.id, second.id])
            XCTAssertNotEqual(touched[0].lastActiveAt, "2026-01-01T00:00:00Z")
        }
    }

    func testRenameSetsUserSourceAndRefusesEmpty() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let row = try TerminalSessionQueries.create(db, claude(nil))
            try TerminalSessionQueries.rename(db, id: row.id, title: "Release work")
            let renamed = try XCTUnwrap(TerminalSessionQueries.fetch(db, id: row.id))
            XCTAssertEqual(renamed.title, "Release work")
            XCTAssertEqual(renamed.titleSource, .user)
            XCTAssertThrowsError(try TerminalSessionQueries.rename(db, id: row.id, title: "")) {
                XCTAssertEqual($0 as? TerminalSessionQueryError, .emptyTitle)
            }
            XCTAssertThrowsError(try TerminalSessionQueries.rename(db, id: row.id, title: "  "))
            XCTAssertEqual(try TerminalSessionQueries.fetch(db, id: row.id)?.title, "Release work")
        }
    }

    /// A row closed by an older build (`closed_at` set) still loads and is
    /// listed like any other session.
    func testLegacyClosedRowIsListedLikeAnyOther() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let row = try TerminalSessionQueries.create(db, claude(project))
            try db.execute(sql: "UPDATE terminal_sessions SET closed_at = '2026-09-30T12:00:00Z' WHERE id = ?",
                           arguments: [row.id])
            XCTAssertEqual(try TerminalSessionQueries.fetch(db, id: row.id)?.id, row.id)
            XCTAssertEqual(try TerminalSessionQueries.fetchForWorkbench(db, projectID: project).map(\.id), [row.id])
            let loose = try TerminalSessionQueries.create(db, claude(nil))
            try db.execute(sql: "UPDATE terminal_sessions SET closed_at = '2026-09-30T12:00:00Z' WHERE id = ?",
                           arguments: [loose.id])
            XCTAssertEqual(try TerminalSessionQueries.fetchStandalone(db).map(\.id), [loose.id])
        }
    }

    func testFetchStandaloneExcludesProjectRows() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            _ = try TerminalSessionQueries.create(db, claude(project))
            let loose = try TerminalSessionQueries.create(db, claude(nil))
            XCTAssertEqual(try TerminalSessionQueries.fetchStandalone(db).map(\.id), [loose.id])
        }
    }

    func testFetchAllWorkbenchSessionsSkipsStandaloneNewestFirst() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let acme = try TestDatabase.insertWorkbench(db)
            let other = try TestDatabase.insertWorkbench(db, name: "other", folder: "/tmp/other")
            let old = try TerminalSessionQueries.create(db, claude(acme, "Old"))
            let new = try TerminalSessionQueries.create(db, claude(other, "New"))
            let mid = try TerminalSessionQueries.create(db, claude(acme, "Mid"))
            let loose = try TerminalSessionQueries.create(db, claude(nil))
            for (row, stamp) in [(old, "2026-01-01T00:00:00Z"), (new, "2026-01-03T00:00:00Z"),
                                 (mid, "2026-01-02T00:00:00Z"), (loose, "2026-01-04T00:00:00Z")] {
                try db.execute(sql: "UPDATE terminal_sessions SET last_active_at = ? WHERE id = ?",
                               arguments: [stamp, row.id])
            }
            XCTAssertEqual(try TerminalSessionQueries.fetchAllWorkbenchSessions(db).map(\.id),
                           [new.id, mid.id, old.id])
        }
    }

    func testDeletingProjectCascadesButKeepsStandalone() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            _ = try TerminalSessionQueries.create(db, claude(project))
            let loose = try TerminalSessionQueries.create(db, claude(nil))
            try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [project])
            XCTAssertTrue(try TerminalSessionQueries.fetchForWorkbench(db, projectID: project).isEmpty)
            XCTAssertNotNil(try TerminalSessionQueries.fetch(db, id: loose.id))
        }
    }

    func testDeletingTargetNullsTargetID() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: project)
            let row = try TerminalSessionQueries.create(db, claude(project, target: target))
            XCTAssertEqual(try TerminalSessionQueries.fetchForTarget(db, targetID: target).map(\.id), [row.id])
            try db.execute(sql: "DELETE FROM targets WHERE id = ?", arguments: [target])
            XCTAssertNil(try XCTUnwrap(TerminalSessionQueries.fetch(db, id: row.id)).targetID)
        }
    }

    func testReplaceClaudeSessionIDAndDelete() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let row = try TerminalSessionQueries.create(db, claude(nil))
            try TerminalSessionQueries.replaceClaudeSessionID(db, id: row.id, uuid: "new-id")
            XCTAssertEqual(try TerminalSessionQueries.fetch(db, id: row.id)?.claudeSessionID, "new-id")
            try TerminalSessionQueries.delete(db, id: row.id)
            XCTAssertNil(try TerminalSessionQueries.fetch(db, id: row.id))
        }
    }

    func testFetchAgentStatesReadsEveryWorkbenchClaudeRowAndTheLiveOnes() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db, name: "acme")
            let waiting = try TerminalSessionQueries.create(db, claude(project, "Waiting"))
            let fresh = try TerminalSessionQueries.create(db, claude(project, "Fresh"))
            let loose = try TerminalSessionQueries.create(db, claude(nil, "Loose"))
            let idleLoose = try TerminalSessionQueries.create(db, claude(nil, "Idle loose"))
            let shell = try TerminalSessionQueries.create(db, .init(
                projectID: project, kind: .shell, title: "Shell", folderPath: "/tmp/acme"
            ))
            try db.execute(
                sql: "UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = ? WHERE id = ?",
                arguments: ["2026-10-03T12:34:56.789Z", waiting.id]
            )
            let rows = try TerminalSessionQueries.fetchAgentStates(db, liveIDs: [loose.id])
            XCTAssertEqual(rows.map(\.id), [waiting.id, fresh.id, loose.id],
                           "every workbench claude row, live or not, and the live standalone one")
            XCTAssertFalse(rows.map(\.id).contains(idleLoose.id), "a standalone terminal not live is not read")
            XCTAssertFalse(rows.map(\.id).contains(shell.id), "a shell has no agent")
            XCTAssertEqual(rows[0], SessionAgentStateRow(
                id: waiting.id, projectID: project, title: "Waiting", agentState: "waiting",
                agentStateAt: "2026-10-03T12:34:56.789Z", workbenchName: "acme"
            ))
            XCTAssertEqual(rows[0].stored, .waiting)
            XCTAssertNil(rows[1].agentState, "a NULL state reads as nil")
            XCTAssertNil(rows[1].agentStateAt)
            XCTAssertNil(rows[1].stored)
            XCTAssertNil(rows[2].workbenchName, "a standalone terminal has no workbench")
            XCTAssertEqual(try TerminalSessionQueries.fetchAgentStates(db, liveIDs: []).map(\.id), [waiting.id, fresh.id])
        }
    }

    func testFetchAgentStatesReadsFinishedTheErrorAndOpenAsks() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db, name: "acme")
            let done = try TerminalSessionQueries.create(db, claude(project, "Done"))
            let failed = try TerminalSessionQueries.create(db, claude(project, "Failed"))
            let other = try TerminalSessionQueries.create(db, claude(project, "Other"))
            try db.execute(
                sql: """
                    UPDATE terminal_sessions SET finished_at = '2026-10-03T12:00:00.000Z', finish_summary = 'Shipped'
                    WHERE id = ?
                    """,
                arguments: [done.id]
            )
            try db.execute(
                sql: """
                    UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = '2026-10-03T12:01:00.000Z',
                        agent_failed_at = '2026-10-03T12:01:00.000Z', agent_error = 'rate_limit'
                    WHERE id = ?
                    """,
                arguments: [failed.id]
            )
            var askIDs: [String: [Int64]] = [:]
            for status in ["answered", "open", "open", "withdrawn"] {
                askIDs[status, default: []].append(try TestDatabase.insertOwnerAsk(
                    db, projectID: project, sessionID: done.id, status: status,
                    answer: status == "answered" ? "yes" : "", withdrawnReason: status == "withdrawn" ? "agent" : ""
                ))
            }
            try TestDatabase.insertOwnerAsk(db, projectID: project, sessionID: other.id)
            try TestDatabase.insertOwnerAsk(db, projectID: project)

            let rows = try TerminalSessionQueries.fetchAgentStates(db, liveIDs: [])
            XCTAssertEqual(rows.map(\.id), [done.id, failed.id, other.id])
            XCTAssertEqual(rows[0], SessionAgentStateRow(
                id: done.id, projectID: project, title: "Done", agentState: nil, agentStateAt: nil,
                workbenchName: "acme", finishedAt: "2026-10-03T12:00:00.000Z", finishSummary: "Shipped",
                openAsks: 2, oldestOpenAskID: askIDs["open"]?.first
            ), "only this session's open asks count; the oldest open one, not an older answered one")
            XCTAssertNil(rows[1].oldestOpenAskID, "no open ask, no oldest")
            XCTAssertEqual(rows[1].agentFailedAt, "2026-10-03T12:01:00.000Z")
            XCTAssertEqual(rows[1].agentError, "rate_limit")
            XCTAssertNil(rows[1].finishedAt)
            XCTAssertEqual(rows[1].finishSummary, "")
            XCTAssertEqual(rows[1].openAsks, 0)
        }
    }

    /// #534: the open asks are split by kind — questions and reviews
    /// counted, checks the rest — and an answered ask counts in none.
    func testAgentStatesCountQuestionAndReviewAsks() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db, name: "acme")
            let session = try TerminalSessionQueries.create(db, claude(project, "Session A"))
            for kind in ["check", "review", "question"] {
                try TestDatabase.insertOwnerAsk(db, projectID: project, sessionID: session.id, kind: kind,
                                                docPath: kind == "review" ? "docs/review.md" : "")
            }
            try TestDatabase.insertOwnerAsk(db, projectID: project, sessionID: session.id, kind: "question",
                                            status: "answered", answer: "yes")

            let row = try XCTUnwrap(TerminalSessionQueries.fetchAgentStates(db, liveIDs: []).first)
            XCTAssertEqual(row.openAsks, 3)
            XCTAssertEqual(row.openQuestionAsks, 1)
            XCTAssertEqual(row.openReviewAsks, 1)
        }
    }

    func testFetchAgentStatesReadsTheBackgroundColumns() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db, name: "acme")
            let busy = try TerminalSessionQueries.create(db, claude(project, "Busy"))
            let quiet = try TerminalSessionQueries.create(db, claude(project, "Quiet"))
            try db.execute(
                sql: """
                    UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = '2026-10-03T12:01:00.000Z',
                        agent_background = 2, agent_background_at = '2026-10-03T12:01:30.250Z'
                    WHERE id = ?
                    """,
                arguments: [busy.id]
            )
            let rows = try TerminalSessionQueries.fetchAgentStates(db, liveIDs: [])
            XCTAssertEqual(rows.map(\.id), [busy.id, quiet.id])
            XCTAssertEqual(rows[0].agentBackground, 2)
            XCTAssertEqual(rows[0].agentBackgroundAt, "2026-10-03T12:01:30.250Z")
            XCTAssertNil(rows[1].agentBackground, "a NULL count reads as nil")
            XCTAssertNil(rows[1].agentBackgroundAt)
        }
    }

    func testFetchAgentStatesReadsTheChatQuestionRaw() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db, name: "acme")
            let asking = try TerminalSessionQueries.create(db, claude(project, "Asking"))
            let quiet = try TerminalSessionQueries.create(db, claude(project, "Quiet"))
            let question = #"{"question":"Red or orange?","options":[{"label":"Red","recommended":true}]}"#
            try db.execute(
                sql: "UPDATE terminal_sessions SET chat_question = ?, chat_question_at = ? WHERE id = ?",
                arguments: [question, "2026-10-10T12:34:56.789Z", asking.id]
            )
            let rows = try TerminalSessionQueries.fetchAgentStates(db, liveIDs: [])
            XCTAssertEqual(rows.map(\.id), [asking.id, quiet.id])
            XCTAssertEqual(rows[0].chatQuestion, question)
            XCTAssertEqual(rows[0].chatQuestionAt, "2026-10-10T12:34:56.789Z", "the stamp is kept as stored")
            XCTAssertNil(rows[1].chatQuestion, "no question reads as nil")
            XCTAssertNil(rows[1].chatQuestionAt)
        }
    }

    // MARK: - Agent cwd (board #565)

    func testFetchAgentCwdsReadsTheWorkbenchRowsThatHaveOne() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let other = try TestDatabase.insertWorkbench(db, name: "Other", folder: "/tmp/other")
            let moved = try TerminalSessionQueries.create(db, claude(project, "Moved"))
            let unknown = try TerminalSessionQueries.create(db, claude(project, "Unknown"))
            let elsewhere = try TerminalSessionQueries.create(db, claude(other, "Elsewhere"))
            for id in [moved.id, elsewhere.id] {
                try db.execute(sql: """
                    UPDATE terminal_sessions SET agent_cwd = '/tmp/acme/.claude/worktrees/mobile-a',
                        agent_cwd_at = '2026-10-12T10:00:00.000Z' WHERE id = ?
                    """, arguments: [id])
            }
            let cwds = try TerminalSessionQueries.fetchAgentCwds(db, projectID: project)
            XCTAssertEqual(cwds, [moved.id: SessionAgentCwd(sessionID: moved.id,
                                                            path: "/tmp/acme/.claude/worktrees/mobile-a",
                                                            at: "2026-10-12T10:00:00.000Z")])
            XCTAssertNil(cwds[unknown.id])
        }
    }

    /// The run start is `agent_turns`' `since`, read as Go's
    /// `db.TerminalAgentCwd` reads it: NULL without a run mark and when the
    /// column is not JSON (json_extract would fail on it).
    func testFetchAgentCwdsReadsTheRunStartAsGoDoes() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let marked = try TerminalSessionQueries.create(db, claude(project, "Marked"))
            let garbled = try TerminalSessionQueries.create(db, claude(project, "Garbled"))
            let unmarked = try TerminalSessionQueries.create(db, claude(project, "Unmarked"))
            let turns: [(Int64, String?)] = [
                (marked.id, #"{"since":"2026-10-12T09:00:00.000Z"}"#), (garbled.id, "not json"), (unmarked.id, nil)
            ]
            for (id, json) in turns {
                try db.execute(sql: """
                    UPDATE terminal_sessions SET agent_cwd = '/tmp/acme', agent_cwd_at = '2026-10-12T10:00:00.000Z',
                        agent_turns = ? WHERE id = ?
                    """, arguments: [json, id])
            }
            let cwds = try TerminalSessionQueries.fetchAgentCwds(db, projectID: project)
            XCTAssertEqual(cwds[marked.id]?.runStart, "2026-10-12T09:00:00.000Z")
            XCTAssertNil(cwds[garbled.id]?.runStart, "agent_turns that is not JSON reads as no run start")
            XCTAssertNotNil(cwds[garbled.id], "and still loads the row")
            XCTAssertNil(cwds[unmarked.id]?.runStart)
        }
    }

    /// A reload does not probe the columns again: the probe is cached per
    /// connection (GRDB's schema cache) until the schema changes.
    func testFetchAgentCwdsProbesTheColumnsOncePerConnection() throws {
        final class Box: @unchecked Sendable { var probes = 0 }
        let box = Box()
        let queue = try TestDatabase.create()
        let project = try queue.write { db in try TestDatabase.insertWorkbench(db) }
        _ = try queue.read { db in try TerminalSessionQueries.fetchAgentCwds(db, projectID: project) }
        try queue.read { db in
            db.trace { event in
                if event.description.contains("table_info") || event.description.contains("table_xinfo") {
                    box.probes += 1
                }
            }
            _ = try TerminalSessionQueries.fetchAgentCwds(db, projectID: project)
            db.trace(nil)
        }
        XCTAssertEqual(box.probes, 0)
    }

    /// A database without migration 00110: no cwds, and every other session
    /// read still works (the cwd stays out of `TerminalSession`).
    func testADatabaseWithoutTheCwdColumnsStillLoadsSessions() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try db.execute(sql: "ALTER TABLE terminal_sessions DROP COLUMN agent_cwd_at")
            try db.execute(sql: "ALTER TABLE terminal_sessions DROP COLUMN agent_cwd")
            let project = try TestDatabase.insertWorkbench(db)
            let row = try TerminalSessionQueries.create(db, claude(project))
            XCTAssertEqual(try TerminalSessionQueries.fetchForWorkbench(db, projectID: project).map(\.id), [row.id])
            XCTAssertEqual(try TerminalSessionQueries.fetchAgentCwds(db, projectID: project), [:])
        }
    }

    /// A database without migration 00110: the session states still load,
    /// each with no cwd stamp (`agent_cwd_at` reads as NULL).
    func testFetchAgentStatesWorksWithoutTheCwdColumns() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try db.execute(sql: "ALTER TABLE terminal_sessions DROP COLUMN agent_cwd_at")
            try db.execute(sql: "ALTER TABLE terminal_sessions DROP COLUMN agent_cwd")
            let project = try TestDatabase.insertWorkbench(db, name: "acme")
            let row = try TerminalSessionQueries.create(db, claude(project, "Waiting"))
            try db.execute(
                sql: "UPDATE terminal_sessions SET agent_state = 'waiting' WHERE id = ?", arguments: [row.id]
            )
            let rows = try TerminalSessionQueries.fetchAgentStates(db, liveIDs: [])
            XCTAssertEqual(rows.map(\.id), [row.id])
            XCTAssertEqual(rows.first?.agentState, "waiting")
            XCTAssertNil(rows.first?.agentCwdAt)
        }
    }

    // MARK: - Cleanup result (board #535)

    func testFetchCleanupRecordReadsTheStoredResultAndStamp() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let row = try TerminalSessionQueries.create(db, claude(project))
            let json = #"{"session_id":\#(row.id),"mode":"apply","items":[],"summary":"1 worktree removed (~2 GB)"}"#
            try db.execute(
                sql: "UPDATE terminal_sessions SET cleanup_result = ?, cleanup_at = '2026-10-12T10:00:00Z' WHERE id = ?",
                arguments: [json, row.id]
            )
            let record = try XCTUnwrap(TerminalSessionQueries.fetchCleanupRecord(db, sessionID: row.id))
            XCTAssertEqual(record.at, "2026-10-12T10:00:00Z")
            XCTAssertEqual(record.result?.summary, "1 worktree removed (~2 GB)")
            XCTAssertEqual(record.result?.mode, "apply")
        }
    }

    func testFetchCleanupRecordIsNilWithoutAResultOrARow() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let row = try TerminalSessionQueries.create(db, claude(project))
            XCTAssertNil(try TerminalSessionQueries.fetchCleanupRecord(db, sessionID: row.id))
            XCTAssertNil(try TerminalSessionQueries.fetchCleanupRecord(db, sessionID: row.id + 100))
        }
    }

    /// Garbage in `cleanup_result` is a record without a result, not an error
    /// that would fail the report.
    func testFetchCleanupRecordKeepsAnUndecodableResultAsNil() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let row = try TerminalSessionQueries.create(db, claude(project))
            try db.execute(
                sql: "UPDATE terminal_sessions SET cleanup_result = 'not json' WHERE id = ?", arguments: [row.id]
            )
            let record = try XCTUnwrap(TerminalSessionQueries.fetchCleanupRecord(db, sessionID: row.id))
            XCTAssertNil(record.result)
            XCTAssertEqual(record.at, "")
        }
    }

    /// A database without migration 00111: no record, and every other
    /// session read still works (the columns stay out of `TerminalSession`).
    func testADatabaseWithoutTheCleanupColumnsStillLoadsSessions() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try db.execute(sql: "ALTER TABLE terminal_sessions DROP COLUMN cleanup_at")
            try db.execute(sql: "ALTER TABLE terminal_sessions DROP COLUMN cleanup_result")
            let project = try TestDatabase.insertWorkbench(db)
            let row = try TerminalSessionQueries.create(db, claude(project))
            XCTAssertEqual(try TerminalSessionQueries.fetch(db, id: row.id)?.id, row.id)
            XCTAssertEqual(try TerminalSessionQueries.fetchForWorkbench(db, projectID: project).map(\.id), [row.id])
            XCTAssertNil(try TerminalSessionQueries.fetchCleanupRecord(db, sessionID: row.id))
        }
    }
    func testCreateStoresAutomationRunID() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let automation = try TestDatabase.insertAutomation(db, workbenchID: project)
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation, status: "waiting",
                                                           waitingReason: "app")
            var new = claude(project)
            new.automationRunID = run
            let row = try TerminalSessionQueries.create(db, new)
            XCTAssertEqual(row.automationRunID, run)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT automation_run_id FROM terminal_sessions WHERE id = ?",
                                              arguments: [row.id]), run)
        }
    }

    func testCreateWithoutRunLeavesNull() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let row = try TerminalSessionQueries.create(db, claude(try TestDatabase.insertWorkbench(db)))
            XCTAssertNil(row.automationRunID)
            XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT automation_run_id IS NULL FROM terminal_sessions WHERE id = ?",
                                             arguments: [row.id]), true)
        }
    }
}
