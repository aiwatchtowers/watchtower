import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class WorkbenchBranchTargetsTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    private func target(_ d: Database, project: Int64, text: String, status: String = "todo", branch: String) throws -> Int64 {
        let id = try TestDatabase.insertWorkbenchTarget(d, projectID: project, text: text, status: status)
        try d.execute(sql: "UPDATE targets SET branch = ? WHERE id = ?", arguments: [branch, id])
        return id
    }

    func testOnlyThisWorkbenchsTargetsWithABranch() throws {
        try db.write { d in
            let mine = try TestDatabase.insertWorkbench(d, name: "acme", folder: "/tmp/acme")
            let other = try TestDatabase.insertWorkbench(d, name: "beta", folder: "/tmp/beta")
            let login = try target(d, project: mine, text: "Login", branch: "feature/login")
            _ = try target(d, project: other, text: "Elsewhere", branch: "feature/login")
            _ = try target(d, project: mine, text: "No branch", branch: "")
            _ = try target(d, project: mine, text: "Blank branch", branch: "   ")
            let padded = try target(d, project: mine, text: "Padded", branch: " fix/y ")
            let byBranch = try WorkbenchQueries.branchTargets(d, projectID: mine)
            XCTAssertEqual(Set(byBranch.keys), ["feature/login", "fix/y"], "blank branches are excluded, names trimmed")
            XCTAssertEqual(byBranch["feature/login"], [WorkbenchBranchTarget(id: login, title: "Login", status: "todo")])
            XCTAssertEqual(byBranch["fix/y"]?.map(\.id), [padded])
        }
    }

    func testOpenTargetsComeBeforeClosedOnesThenById() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let done = try target(d, project: p, text: "Shipped", status: "done", branch: "feature/x")
            let open = try target(d, project: p, text: "Follow-up", status: "in_progress", branch: "feature/x")
            let dismissed = try target(d, project: p, text: "Dropped", status: "dismissed", branch: "feature/x")
            let review = try target(d, project: p, text: "Review", status: "in_review", branch: "feature/x")
            let list = try WorkbenchQueries.branchTargets(d, projectID: p)["feature/x"]
            XCTAssertEqual(list?.map(\.id), [open, review, done, dismissed])
            XCTAssertEqual(list?.first?.status, "in_progress")
        }
    }

    func testNoTargetsIsEmpty() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            XCTAssertEqual(try WorkbenchQueries.branchTargets(d, projectID: p), [:])
        }
    }
}
