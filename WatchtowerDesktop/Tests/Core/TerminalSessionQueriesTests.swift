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
}
