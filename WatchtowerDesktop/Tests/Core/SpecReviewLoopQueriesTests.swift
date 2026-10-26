import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class SpecReviewLoopQueriesTests: XCTestCase {
    private var db: DatabaseQueue!

    static let twoItems = #"[{"key":"ag:1","kind":"agreement","text":"a","note":"","round":1},"#
        + #"{"key":"bs:2","kind":"blind_spot","text":"b","note":"","round":1}]"#

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    /// A review ask from `sessionID` with its `spec_reviews` row.
    static func insertLoopAsk(
        _ d: Database,
        projectID: Int64,
        sessionID: Int64?,
        askStatus: String = "open",
        withdrawnReason: String = "",
        loop: String = "author",
        status: String = "done",
        round: Int = 1,
        openItems: String = twoItems,
        finishedAt: String = "2026-10-26T10:00:00Z"
    ) throws -> Int64 {
        let id = try TestDatabase.insertOwnerAsk(d, projectID: projectID, sessionID: sessionID, kind: "review",
                                                 docPath: "docs/spec.md", status: askStatus, withdrawnReason: withdrawnReason)
        try d.execute(sql: """
            INSERT INTO spec_reviews (ask_id, status, queued_at, finished_at, loop, round, open_items)
            VALUES (?, ?, '2026-10-26T09:59:00Z', ?, ?, ?, ?)
            """, arguments: [id, status, finishedAt, loop, round, openItems])
        return id
    }

    private func session(_ d: Database, projectID: Int64) throws -> Int64 {
        try TerminalSessionQueries.create(d, .init(projectID: projectID, kind: .shell, title: "s", folderPath: "/tmp/acme")).id
    }

    func testPendingListsDoneAuthorRoundsOnly() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let s = try session(d, projectID: p)
            let due = try Self.insertLoopAsk(d, projectID: p, sessionID: s, round: 2)
            _ = try Self.insertLoopAsk(d, projectID: p, sessionID: s, askStatus: "withdrawn", withdrawnReason: "superseded")
            _ = try Self.insertLoopAsk(d, projectID: p, sessionID: s, loop: "owner")
            _ = try Self.insertLoopAsk(d, projectID: p, sessionID: s, status: "running")
            _ = try Self.insertLoopAsk(d, projectID: p, sessionID: s, openItems: "")
            _ = try Self.insertLoopAsk(d, projectID: p, sessionID: s, openItems: "[]")
            _ = try Self.insertLoopAsk(d, projectID: p, sessionID: s, openItems: "{not json")
            _ = try Self.insertLoopAsk(d, projectID: p, sessionID: nil)

            XCTAssertEqual(try SpecReviewLoopQueries.pending(d), [
                .init(askID: due, sessionID: s, round: 2, items: 2, finishedAt: "2026-10-26T10:00:00Z")
            ])
        }
    }

    func testProgressBySession() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let s1 = try session(d, projectID: p)
            let s2 = try session(d, projectID: p)
            let s3 = try session(d, projectID: p)
            _ = try Self.insertLoopAsk(d, projectID: p, sessionID: s1, round: 1)
            _ = try Self.insertLoopAsk(d, projectID: p, sessionID: s1, status: "running", round: 2)
            _ = try Self.insertLoopAsk(d, projectID: p, sessionID: s2, status: "queued", round: 3)
            _ = try Self.insertLoopAsk(d, projectID: p, sessionID: s3, loop: "owner", round: 3)
            _ = try Self.insertLoopAsk(d, projectID: p, sessionID: s3, askStatus: "withdrawn", withdrawnReason: "superseded")

            XCTAssertEqual(try SpecReviewLoopQueries.progress(d), [s1: 2, s2: 3])
        }
    }
}
