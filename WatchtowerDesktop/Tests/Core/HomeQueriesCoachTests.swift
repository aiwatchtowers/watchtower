import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Home's coach row: the newest open proposal that has a workbench with
/// Analytics on to open it in (`HomeQueries.newestCoachProposal`).
final class HomeQueriesCoachTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    @discardableResult
    private func workbench(_ d: Database, _ name: String, analytics: Bool) throws -> Int64 {
        let id = try TestDatabase.insertWorkbench(d, name: name, folder: "/tmp/\(name)")
        try d.execute(sql: "UPDATE projects SET agent_analytics = ? WHERE id = ?", arguments: [analytics ? 1 : 0, id])
        return id
    }

    @discardableResult
    private func proposal(
        _ d: Database,
        _ title: String,
        workbench: Int64?,
        created: String = "2026-10-20T10:00:00Z",
        status: String = "open",
        after: String = "Be brief."
    ) throws -> Int64 {
        try d.execute(sql: """
            INSERT INTO coach_proposals (fingerprint, kind, destination, workbench_id, title, why, metric,
                                         before_text, after_text, sources, status, created_at)
            VALUES (?, 'add', 'session', ?, ?, 'why', 'corrections', '', ?, 3, ?, ?)
            """, arguments: [title, workbench, title, after, status, created])
        return d.lastInsertedRowID
    }

    private func read(lastOpened: Int64? = nil) throws -> HomeCoachProposal? {
        try db.read { try HomeQueries.newestCoachProposal($0, lastOpened: lastOpened) }
    }

    func testNewestOpenWins() throws {
        try db.write { d in
            let a = try workbench(d, "a", analytics: true)
            try proposal(d, "older", workbench: a, created: "2026-10-18T10:00:00Z")
            try proposal(d, "newest", workbench: a, created: "2026-10-20T10:00:00Z")
            try proposal(d, "newer but closed", workbench: a, created: "2026-10-22T10:00:00Z", status: "declined")
        }
        XCTAssertEqual(try read()?.proposal.title, "newest")
    }

    func testNoRowWithoutAnalyticsOnWorkbench() throws {
        try db.write { d in
            try workbench(d, "a", analytics: false)
            try proposal(d, "global", workbench: nil)
        }
        XCTAssertNil(try read())
    }

    func testWorkbenchProposalOfOffWorkbenchSkipped() throws {
        try db.write { d in
            let on = try workbench(d, "on", analytics: true)
            let off = try workbench(d, "off", analytics: false)
            try proposal(d, "for off", workbench: off, created: "2026-10-21T10:00:00Z")
            try proposal(d, "for on", workbench: on, created: "2026-10-20T10:00:00Z")
        }
        let row = try XCTUnwrap(try read())
        XCTAssertEqual(row.proposal.title, "for on")
        XCTAssertEqual(row.targetWorkbench, row.proposal.workbenchID)
    }

    func testGlobalProposalTargetsLowestOnWorkbench() throws {
        let ids = try db.write { d -> [Int64] in
            let off = try workbench(d, "off", analytics: false)
            let first = try workbench(d, "first", analytics: true)
            let second = try workbench(d, "second", analytics: true)
            try proposal(d, "global", workbench: nil)
            return [off, first, second]
        }
        let row = try XCTUnwrap(try read())
        XCTAssertEqual(row.proposal.workbenchID, 0, "NULL reads as global")
        XCTAssertEqual(row.targetWorkbench, ids[1])
    }

    func testGlobalProposalTargetsLastOpenedWhenOn() throws {
        let ids = try db.write { d -> [Int64] in
            let first = try workbench(d, "first", analytics: true)
            let second = try workbench(d, "second", analytics: true)
            try proposal(d, "global", workbench: nil)
            return [first, second]
        }
        XCTAssertEqual(try read(lastOpened: ids[1])?.targetWorkbench, ids[1])
    }

    func testGlobalProposalIgnoresLastOpenedWhenOff() throws {
        let ids = try db.write { d -> [Int64] in
            let on = try workbench(d, "on", analytics: true)
            let off = try workbench(d, "off", analytics: false)
            try proposal(d, "global", workbench: nil)
            return [on, off]
        }
        XCTAssertEqual(try read(lastOpened: ids[1])?.targetWorkbench, ids[0])
    }

    func testRowCarriesTheProposalFields() throws {
        try db.write { d in
            let a = try workbench(d, "a", analytics: true)
            try proposal(d, "Add a Non-goals section", workbench: a, after: "One\nTwo")
        }
        let p = try XCTUnwrap(try read()).proposal
        XCTAssertEqual(p.destination, "session")
        XCTAssertEqual(p.after, "One\nTwo")
        XCTAssertEqual(CoachHomeRow.lines(p).shown, [.added("One"), .added("Two")])
    }
}
