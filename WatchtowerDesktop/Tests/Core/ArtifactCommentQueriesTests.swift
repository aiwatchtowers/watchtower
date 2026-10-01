import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ArtifactCommentQueriesTests: XCTestCase {
    private var queue: DatabaseQueue!
    private var conversationID: Int64 = 0

    override func setUpWithError() throws {
        queue = try TestDatabase.create()
        conversationID = try queue.write { try TestDatabase.insertChatConversation($0) }
    }

    private func add(_ db: Database, quote: String = "q", body: String = "b") throws -> Int64 {
        try ArtifactCommentQueries.add(db, conversationID: conversationID, key: "plan", version: 1,
                                       anchor: CommentAnchor(quote: quote, prefix: "", suffix: "", heading: ""),
                                       body: body)
    }

    private func status(_ db: Database, _ id: Int64) throws -> String? {
        try String.fetchOne(db, sql: "SELECT status FROM chat_artifact_comments WHERE id = ?", arguments: [id])
    }

    func testAddTrimsTheBodyAndRefusesAnEmptyBodyOrQuote() throws {
        try queue.write { db in
            let id = try add(db, body: "  Why?  \n")
            XCTAssertEqual(try ArtifactCommentQueries.comments(db, conversationID: conversationID, key: "plan").map(\.body), ["Why?"])
            XCTAssertEqual(try status(db, id), "open")
            XCTAssertThrowsError(try add(db, body: " \n")) { XCTAssertEqual($0 as? ArtifactCommentError, .emptyBody) }
            XCTAssertThrowsError(try add(db, quote: "  ")) { XCTAssertEqual($0 as? ArtifactCommentError, .emptyQuote) }
        }
    }

    func testMarkSentTouchesOnlyTheIncludedOpenComments() throws {
        try queue.write { db in
            let (a, b, _, d) = (try add(db), try add(db), try add(db), try add(db))
            let earlier = Date(timeIntervalSince1970: 100)
            XCTAssertEqual(try ArtifactCommentQueries.markSent(db, ids: [d], at: earlier), 1)
            let now = Date(timeIntervalSince1970: 200)

            XCTAssertEqual(try ArtifactCommentQueries.markSent(db, ids: [a, b, d], at: now), 2, "d was sent before")
            let rows = try ArtifactCommentQueries.comments(db, conversationID: conversationID, key: "plan")
            XCTAssertEqual(rows.map(\.status), [.sent, .sent, .open, .sent])
            XCTAssertEqual(rows.map(\.sentAt), [200, 200, nil, 100], "c was not included; d keeps its first sent_at")
            XCTAssertEqual(try ArtifactCommentQueries.markSent(db, ids: [], at: now), 0)
        }
    }

    func testDeleteRemovesOnlyAnUnsentComment() throws {
        try queue.write { db in
            let (draft, sent) = (try add(db), try add(db))
            try ArtifactCommentQueries.markSent(db, ids: [sent], at: Date())
            XCTAssertTrue(try ArtifactCommentQueries.deleteUnsent(db, id: draft))
            XCTAssertFalse(try ArtifactCommentQueries.deleteUnsent(db, id: sent), "a sent comment is part of the conversation")
            XCTAssertEqual(try ArtifactCommentQueries.comments(db, conversationID: conversationID, key: "plan").map(\.id), [sent])
        }
    }

    func testResolveOnlyASentOrOutdatedComment() throws {
        try queue.write { db in
            let (draft, sent, lost) = (try add(db), try add(db), try add(db))
            try ArtifactCommentQueries.markSent(db, ids: [sent], at: Date())
            try ArtifactCommentQueries.apply(db, plan: ArtifactCommentReanchor.Plan(lost: [lost]), version: 2)
            XCTAssertFalse(try ArtifactCommentQueries.resolve(db, id: draft), "an unsent comment is deleted, not resolved")
            XCTAssertTrue(try ArtifactCommentQueries.resolve(db, id: sent))
            XCTAssertTrue(try ArtifactCommentQueries.resolve(db, id: lost))
            XCTAssertEqual(try status(db, draft), "open")
            XCTAssertEqual(try status(db, sent), "resolved")
            XCTAssertEqual(try status(db, lost), "resolved")
        }
    }

    func testApplyMovesAndOutdatesOnlyLiveComments() throws {
        try queue.write { db in
            let (moved, lost, resolved) = (try add(db), try add(db), try add(db))
            try ArtifactCommentQueries.markSent(db, ids: [resolved], at: Date())
            try ArtifactCommentQueries.resolve(db, id: resolved)
            try ArtifactCommentQueries.apply(db, plan: ArtifactCommentReanchor.Plan(moved: [moved, resolved], lost: [lost, resolved]),
                                             version: 3)
            let rows = try ArtifactCommentQueries.comments(db, conversationID: conversationID, key: "plan")
            XCTAssertEqual(rows.map(\.status), [.open, .outdated, .resolved])
            XCTAssertEqual(rows.map(\.artifactVersion), [3, 1, 1], "an outdated comment keeps the version it was last found on")
        }
    }
}
