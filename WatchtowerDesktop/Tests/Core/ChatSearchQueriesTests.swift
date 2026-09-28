import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatSearchQueriesTests: XCTestCase {
    func testFTSQueryQuotesAndPrefixesEveryToken() {
        XCTAssertEqual(ChatSearchQueries.ftsQuery(#"payments  roll-out "x""#), #""payments"* "roll"* "out"* "x"*"#)
        XCTAssertNil(ChatSearchQueries.ftsQuery("  -- "))
    }

    func testFindsMessagesWithHighlightedSnippetAndSkipsDiscussAndArchived() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let main = try TestDatabase.insertChatConversation(d, title: "Rollout")
            let msg = try TestDatabase.insertChatMessage(d, conversationID: main, role: "assistant", text: "The payments rollout slipped")
            let discuss = try TestDatabase.insertChatConversation(d, contextType: "target")
            try TestDatabase.insertChatMessage(d, conversationID: discuss, role: "user", text: "payments again")
            let archived = try TestDatabase.insertChatConversation(d)
            try TestDatabase.insertChatMessage(d, conversationID: archived, role: "user", text: "payments archived")
            try d.execute(sql: "UPDATE chat_conversations SET archived_at = 1 WHERE id = ?", arguments: [archived])

            let hits = try ChatSearchQueries.search(d, query: "payment")
            let messageHits = hits.filter { $0.messageID != nil }
            XCTAssertEqual(messageHits.map(\.messageID), [msg])
            XCTAssertTrue(messageHits[0].snippet.contains(ChatSearchQueries.markStart + "payments" + ChatSearchQueries.markEnd))
            XCTAssertEqual(String(messageHits[0].attributedSnippet.characters), "The payments rollout slipped")
        }
    }

    func testTitleHitsComeFirstAndCyrillicMatchesByPrefix() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d, title: "Платёжный релиз")
            try TestDatabase.insertChatMessage(d, conversationID: conv, role: "user", text: "платёжный шлюз упал")
            // Title LIKE is case-sensitive outside ASCII, so the query keeps
            // the title's capital; FTS (unicode61) folds case for the message.
            let hits = try ChatSearchQueries.search(d, query: "Платёж")
            XCTAssertEqual(hits.first?.messageID, nil, "the title hit is listed first")
            XCTAssertEqual(hits.count, 2)
        }
    }

    func testEmptyQueryYieldsNothing() throws {
        let db = try TestDatabase.create()
        try db.read { d in XCTAssertTrue(try ChatSearchQueries.search(d, query: "   ").isEmpty) }
    }
}
