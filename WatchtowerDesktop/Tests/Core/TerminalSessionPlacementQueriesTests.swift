import GRDB
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

final class TerminalSessionPlacementQueriesTests: XCTestCase {
    func testCreateStoresTheWorktreeBranchAndBase() throws {
        let db = try TestDatabase.create()
        let projectID = try db.write { try TestDatabase.insertWorkbench($0, folder: "/repo") }
        let row = try db.write { db in
            try TerminalSessionQueries.create(db, .init(
                projectID: projectID, kind: .claude, title: "t", folderPath: "/repo/.claude/worktrees/a",
                claudeSessionID: UUID().uuidString, worktreeBranch: "wt/a", worktreeBase: "abc1234"))
        }
        XCTAssertEqual(row.worktreeBranch, "wt/a")
        XCTAssertEqual(row.worktreeBase, "abc1234")
        let plain = try db.write { db in
            try TerminalSessionQueries.create(db, .init(
                projectID: projectID, kind: .claude, title: "p", folderPath: "/repo", claudeSessionID: UUID().uuidString))
        }
        XCTAssertNil(plain.worktreeBranch)
        XCTAssertNil(plain.worktreeBase)
    }

    func testWorktreeSetupRoundTripsTrimmed() throws {
        let db = try TestDatabase.create()
        let projectID = try db.write { try TestDatabase.insertWorkbench($0, folder: "/repo") }
        XCTAssertEqual(try db.read { try WorkbenchQueries.fetch($0, id: projectID) }?.worktreeSetup, "")
        try db.write { try WorkbenchQueries.setWorktreeSetup($0, projectID: projectID, command: "  npm install \n") }
        XCTAssertEqual(try db.read { try WorkbenchQueries.fetch($0, id: projectID) }?.worktreeSetup, "npm install")
    }

    func testWorktreeSetupOnAMissingWorkbenchThrows() throws {
        let db = try TestDatabase.create()
        XCTAssertThrowsError(try db.write { try WorkbenchQueries.setWorktreeSetup($0, projectID: 999, command: "x") })
    }

    func testHasWorktreeMatchesOnlyTheSessionsOwnRootAndBranch() throws {
        let db = try TestDatabase.create()
        let projectID = try db.write { try TestDatabase.insertWorkbench($0, folder: "/repo") }
        func add(_ title: String) throws -> Int64 {
            try db.write { db in
                try TerminalSessionQueries.create(db, .init(
                    projectID: projectID, kind: .claude, title: title, folderPath: "/repo/.claude/worktrees/a",
                    claudeSessionID: UUID().uuidString)).id
            }
        }
        let me = try add("me")
        let other = try add("other")
        try db.write { db in
            for (id, root, branch) in [(me, "/private/repo/.claude/worktrees/a", "fix/x"),
                                       (me, "/private/repo/.claude/worktrees/a", ""),
                                       (other, "/private/repo/.claude/worktrees/a", "fix/y")] {
                try db.execute(
                    sql: "INSERT INTO terminal_session_worktrees (session_id, root, branch, first_at) VALUES (?, ?, ?, ?)",
                    arguments: [id, root, branch, "2026-11-03T10:00:00Z"])
            }
        }
        let roots = ["/repo/.claude/worktrees/a", "/private/repo/.claude/worktrees/a"]
        func has(_ id: Int64, _ roots: [String], _ branch: String) throws -> Bool {
            try db.read { try TerminalSessionQueries.hasWorktree($0, sessionID: id, roots: roots, branch: branch) }
        }
        XCTAssertTrue(try has(me, roots, "fix/x"))
        XCTAssertTrue(try has(me, roots, ""), "a detached HEAD the agent made")
        XCTAssertFalse(try has(me, roots, "fix/y"), "another session's branch")
        XCTAssertFalse(try has(me, ["/repo/.claude/worktrees/a"], "fix/x"), "the unresolved path alone")
        XCTAssertFalse(try has(me, ["/private/repo/.claude/worktrees/b"], "fix/x"), "another worktree")
        XCTAssertFalse(try has(me, [], "fix/x"))
        XCTAssertTrue(try has(other, roots, "fix/y"))
    }
}
