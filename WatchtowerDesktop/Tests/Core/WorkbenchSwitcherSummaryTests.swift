import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class WorkbenchSwitcherSummaryTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    private func session(_ d: Database, _ project: Int64?, lastActive: String) throws {
        let row = try TerminalSessionQueries.create(d, .init(
            projectID: project, kind: .shell, title: "Shell", folderPath: "/tmp/acme"
        ))
        try d.execute(sql: "UPDATE terminal_sessions SET last_active_at = ? WHERE id = ?",
                      arguments: [lastActive, row.id])
    }

    func testBlockedCountsOnlyTheWorkbenchsOwnBlockedTargets() throws {
        try db.write { d in
            let acme = try TestDatabase.insertWorkbench(d)
            let other = try TestDatabase.insertWorkbench(d, name: "other", folder: "/tmp/other")
            try TestDatabase.insertWorkbenchTarget(d, projectID: acme, status: "blocked")
            try TestDatabase.insertWorkbenchTarget(d, projectID: acme, status: "blocked")
            try TestDatabase.insertWorkbenchTarget(d, projectID: acme, status: "in_progress")
            try TestDatabase.insertWorkbenchTarget(d, projectID: other, status: "blocked")
            try TestDatabase.insertTarget(d, status: "blocked")

            let rows = try WorkbenchQueries.switcherSummaries(d)
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            XCTAssertEqual(byID[acme]?.blockedTargets, 2)
            XCTAssertEqual(byID[other]?.blockedTargets, 1)
            XCTAssertEqual(byID[acme]?.summary.openTargets, 3, "the summaries fields ride along")
            XCTAssertEqual(byID[acme]?.summary.inProgressTargets, 1)
        }
    }

    func testSessionCountAndLastActivityWithZeroOneSeveralSessions() throws {
        try db.write { d in
            let none = try TestDatabase.insertWorkbench(d, name: "none", folder: "/tmp/none")
            let one = try TestDatabase.insertWorkbench(d, name: "one", folder: "/tmp/one")
            let many = try TestDatabase.insertWorkbench(d, name: "many", folder: "/tmp/many")
            try session(d, one, lastActive: "2026-09-30T08:00:00Z")
            try session(d, many, lastActive: "2026-09-29T08:00:00Z")
            try session(d, many, lastActive: "2026-10-01T09:30:00Z")
            try session(d, many, lastActive: "2026-09-28T08:00:00Z")
            try session(d, nil, lastActive: "2026-10-02T00:00:00Z")

            let rows = try WorkbenchQueries.switcherSummaries(d)
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            XCTAssertEqual(byID[none]?.sessionCount, 0)
            XCTAssertEqual(byID[none]?.lastSessionActivity, "")
            XCTAssertEqual(byID[one]?.sessionCount, 1)
            XCTAssertEqual(byID[one]?.lastSessionActivity, "2026-09-30T08:00:00Z")
            XCTAssertEqual(byID[many]?.sessionCount, 3)
            XCTAssertEqual(byID[many]?.lastSessionActivity, "2026-10-01T09:30:00Z", "a standalone session is not counted")
            XCTAssertEqual(rows.count, 3)
        }
    }
}
