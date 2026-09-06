import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

final class ChatMessageTurnIDTests: XCTestCase {
    func testEnsureTurnIDColumnIsIdempotentAndRoundTrips() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try manager.dbPool.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
            try ChatMessageQueries.ensureTurnIDColumn(db)
            try ChatMessageQueries.ensureTurnIDColumn(db) // second call must not throw
            let conv = try ChatConversationQueries.create(db, title: "t")
            try ChatMessageQueries.insert(db, conversationID: conv.id, role: "assistant", text: "hi", turnID: "turn-1")
            try ChatMessageQueries.insert(db, conversationID: conv.id, role: "user", text: "yo")
        }
        let records = try manager.dbPool.read { db in
            try ChatMessageQueries.fetchByConversation(db, conversationID: 1)
        }
        XCTAssertEqual(records.map(\.turnID), ["turn-1", ""])
        XCTAssertEqual(records[0].toChatMessage().turnID, "turn-1")
        XCTAssertNil(records[1].toChatMessage().turnID)
    }

    func testDatabaseManagerAddsColumnToLegacyTable() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try manager.dbPool.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db) // legacy shape, no turn_id
        }
        try manager.dbPool.write { db in try ChatMessageQueries.ensureTurnIDColumn(db) }
        let columns = try manager.dbPool.read { db in try db.columns(in: "chat_messages").map(\.name) }
        XCTAssertTrue(columns.contains("turn_id"))
    }
}
