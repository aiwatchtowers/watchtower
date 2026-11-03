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

    func testFetchInFolderReturnsRowsInTheFolderOnly() throws {
        let db = try TestDatabase.create()
        let projectID = try db.write { try TestDatabase.insertWorkbench($0, folder: "/repo") }
        let other = try db.write { try TestDatabase.insertWorkbench($0, name: "other", folder: "/other") }
        func add(_ p: Int64, _ folder: String) throws -> Int64 {
            try db.write { db in
                try TerminalSessionQueries.create(db, .init(
                    projectID: p, kind: .claude, title: "t", folderPath: folder, claudeSessionID: UUID().uuidString)).id
            }
        }
        let top = "/repo/.claude/worktrees/a_b"
        let exact = try add(projectID, top)
        let inside = try add(projectID, top + "/app")
        let fromOtherWorkbench = try add(other, top)
        _ = try add(projectID, "/repo/.claude/worktrees/a_bc")
        _ = try add(projectID, "/repo/.claude/worktrees/aXb")
        _ = try add(projectID, "/repo")
        let ids = try db.read { try TerminalSessionQueries.fetchInFolder($0, top: top) }.map(\.id)
        XCTAssertEqual(ids, [exact, inside, fromOtherWorkbench])
    }
}
