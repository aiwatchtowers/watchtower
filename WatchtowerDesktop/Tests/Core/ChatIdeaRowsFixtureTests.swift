import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// `IdeaQueries.createFromChat` over Go's `internal/db/testdata/chat_idea_rows.json`,
/// which `TestCreateIdeaFromChat_SharedRows` runs against `db.CreateIdeaFromChat`:
/// the Mac's and the hub's chat stores write the same chat-born idea rows.
final class ChatIdeaRowsFixtureTests: XCTestCase {
    private struct Case: Decodable {
        struct Expect: Decodable {
            struct Idea: Decodable {
                let kind, title, essence, status, source: String
                let chatBorn: Int

                enum CodingKeys: String, CodingKey {
                    case kind, title, essence, status, source
                    case chatBorn = "chat_born"
                }
            }

            struct Mention: Decodable {
                let source, ref, quote: String
            }

            let idea: Idea
            let mention: Mention
        }

        let name, kind, body: String
        let conversationID, messageID: Int64
        let expect: Expect

        enum CodingKeys: String, CodingKey {
            case name, kind, body, expect
            case conversationID = "conversation_id"
            case messageID = "message_id"
        }
    }

    private static func cases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/db/testdata/chat_idea_rows.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    func testCreateFromChatMatchesGoRows() throws {
        let cases = try Self.cases()
        XCTAssertGreaterThanOrEqual(cases.count, 8)
        for c in cases {
            let queue = try TestDatabase.create()
            let id = try queue.write { db in
                try IdeaQueries.createFromChat(db, kind: c.kind, body: c.body,
                                               conversationID: c.conversationID, messageID: c.messageID)
            }
            let row = try XCTUnwrap(try queue.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT kind, title, essence, status, source, chat_born, last_mention_at FROM ideas WHERE id = ?
                    """, arguments: [id])
            }, c.name)
            let e = c.expect.idea
            XCTAssertEqual(row["kind"] as String, e.kind, c.name)
            XCTAssertEqual(row["title"] as String, e.title, c.name)
            XCTAssertEqual(row["essence"] as String, e.essence, c.name)
            XCTAssertEqual(row["status"] as String, e.status, c.name)
            XCTAssertEqual(row["source"] as String, e.source, c.name)
            XCTAssertEqual(row["chat_born"] as Int, e.chatBorn, c.name)
            let mentions = try queue.read { db in
                try Row.fetchAll(db, sql: "SELECT source, ref, quote, said_at FROM idea_mentions WHERE idea_id = ?",
                                 arguments: [id])
            }
            XCTAssertEqual(mentions.count, 1, c.name)
            let m = try XCTUnwrap(mentions.first, c.name)
            XCTAssertEqual(m["source"] as String, c.expect.mention.source, c.name)
            XCTAssertEqual(m["ref"] as String, c.expect.mention.ref, c.name)
            XCTAssertEqual(m["quote"] as String, c.expect.mention.quote, c.name)
            XCTAssertEqual(m["said_at"] as String, row["last_mention_at"] as String, c.name)
        }
    }
}
