import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The Mac's ⌘K chat search over Go's `internal/db/testdata/chat_search_cases.json`,
/// which `TestChatSearch_SharedCases` runs through the hub's port
/// (`db.SearchChats`): the phone's search returns the Mac's hits. Swift is
/// the reference.
final class ChatSearchQueriesFixtureTests: XCTestCase {
    private static func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/db/testdata/chat_search_cases.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testHitsMatchTheGoPort() throws {
        let fx = try Self.fixture()
        let cases = try XCTUnwrap(fx["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 8)
        let queue = try TestDatabase.create()
        try queue.write { db in
            for c in fx["conversations"] as? [[String: Any]] ?? [] {
                try db.execute(sql: """
                    INSERT INTO chat_conversations (id, title, context_type, archived_at, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [c["id"] as? Int64, c["title"] as? String, c["context_type"] as? String,
                                     c["archived_at"] as? Double, c["updated_at"] as? Double, c["updated_at"] as? Double])
            }
            for m in fx["messages"] as? [[String: Any]] ?? [] {
                try db.execute(sql: """
                    INSERT INTO chat_messages (id, conversation_id, role, text, created_at) VALUES (?, ?, ?, ?, ?)
                    """, arguments: [m["id"] as? Int64, m["conversation_id"] as? Int64, m["role"] as? String,
                                     m["text"] as? String, m["created_at"] as? Double])
            }
        }
        try queue.read { db in
            for tc in cases {
                let name = tc["name"] as? String ?? "?"
                let hits = try ChatSearchQueries.search(db, query: try XCTUnwrap(tc["query"] as? String),
                                                        limit: try XCTUnwrap(tc["limit"] as? Int))
                let want = (tc["hits"] as? [[String: Any]] ?? []).map { h in
                    ChatSearchHit(conversationID: h["conversation_id"] as? Int64 ?? 0,
                                  messageID: h["message_id"] as? Int64,
                                  title: h["title"] as? String ?? "",
                                  snippet: h["snippet"] as? String ?? "")
                }
                XCTAssertEqual(hits, want, name)
            }
        }
    }
}
