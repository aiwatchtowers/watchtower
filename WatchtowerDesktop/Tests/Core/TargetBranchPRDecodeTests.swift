import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The side panel's read-only Branch and PR rows (spec 2026-10-06 Part 3):
/// `Target` reads the existing `targets.branch`/`targets.pr` columns.
final class TargetBranchPRDecodeTests: XCTestCase {
    func testBranchAndPRDecodeFromTheirColumns() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let id = try TestDatabase.insertWorkbenchTarget(d, projectID: p)
            try d.execute(sql: "UPDATE targets SET branch = 'feature/acme', pr = '42' WHERE id = ?", arguments: [id])
            let plain = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Plain")

            let target = try XCTUnwrap(TargetQueries.fetchByID(d, id: Int(id)))
            XCTAssertEqual(target.branch, "feature/acme")
            XCTAssertEqual(target.pr, "42")
            let empty = try XCTUnwrap(TargetQueries.fetchByID(d, id: Int(plain)))
            XCTAssertEqual(empty.branch, "")
            XCTAssertEqual(empty.pr, "")
        }
    }

    func testARowWithoutTheColumnsDecodesEmpty() {
        let target = Target(row: Row(["id": 1, "text": "Old row"]))
        XCTAssertEqual(target.branch, "")
        XCTAssertEqual(target.pr, "")
    }
}
