import XCTest
import GRDB
import WatchtowerTestSupport

/// The test schema mirror carries migration 00082 so the artifact-comment
/// queries are tested against the real shape.
final class ArtifactCommentSchemaMirrorTests: XCTestCase {
    func testMirrorHasTheTableAndItsConstraints() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            XCTAssertTrue(try db.tableExists("chat_artifact_comments"))
            let conversation = try TestDatabase.insertChatConversation(db)
            let insert = { (status: String, sentAt: Double?) in
                try db.execute(sql: """
                    INSERT INTO chat_artifact_comments
                        (conversation_id, artifact_key, artifact_version, body, anchor_quote, status, created_at, sent_at)
                    VALUES (?, 'plan', 1, 'b', 'q', ?, 0, ?)
                    """, arguments: [conversation, status, sentAt])
            }
            XCTAssertThrowsError(try insert("draft", nil), "status CHECK")
            XCTAssertThrowsError(try insert("sent", nil), "a sent comment carries sent_at")
            try insert("open", nil)
            try insert("sent", 1)
            try db.execute(sql: "DELETE FROM chat_conversations WHERE id = ?", arguments: [conversation])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_artifact_comments"), 0)
        }
    }
}
