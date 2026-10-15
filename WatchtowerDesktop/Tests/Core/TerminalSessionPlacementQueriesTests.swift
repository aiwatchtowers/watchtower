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
}
