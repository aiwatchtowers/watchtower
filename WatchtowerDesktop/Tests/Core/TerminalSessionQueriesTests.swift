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

    func testFetchAgentStatesReturnsOnlyTheAskedIDsWithTheWorkbenchName() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db, name: "acme")
            let waiting = try TerminalSessionQueries.create(db, claude(project, "Waiting"))
            let fresh = try TerminalSessionQueries.create(db, claude(project, "Fresh"))
            let other = try TerminalSessionQueries.create(db, claude(project, "Other"))
            let loose = try TerminalSessionQueries.create(db, claude(nil, "Loose"))
            for id in [waiting.id, other.id] {
                try db.execute(
                    sql: "UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = ? WHERE id = ?",
                    arguments: ["2026-10-03T12:34:56.789Z", id]
                )
            }
            let rows = try TerminalSessionQueries.fetchAgentStates(db, ids: [waiting.id, fresh.id, loose.id])
            XCTAssertEqual(rows.map(\.id), [waiting.id, fresh.id, loose.id], "only the asked ids")
            XCTAssertEqual(rows[0], SessionAgentStateRow(
                id: waiting.id, projectID: project, title: "Waiting", agentState: "waiting",
                agentStateAt: "2026-10-03T12:34:56.789Z", workbenchName: "acme"
            ))
            XCTAssertEqual(rows[0].stored, .waiting)
            XCTAssertNil(rows[1].agentState, "a NULL state reads as nil")
            XCTAssertNil(rows[1].agentStateAt)
            XCTAssertNil(rows[1].stored)
            XCTAssertNil(rows[2].workbenchName, "a standalone terminal has no workbench")
            XCTAssertEqual(try TerminalSessionQueries.fetchAgentStates(db, ids: []), [])
        }
    }
}
