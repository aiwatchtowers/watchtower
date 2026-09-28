import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatConversationQueriesTests: XCTestCase {
    func testRenameMarksTitleAsUserOwnedAndPrefixNoLongerOverwrites() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let conv = try ChatConversationQueries.create(d)
            try ChatConversationQueries.setPrefixTitle(d, id: conv.id, text: String(repeating: "x", count: 100))
            XCTAssertEqual(try ChatConversationQueries.fetchByID(d, id: conv.id)?.title.count, 80)

            try ChatConversationQueries.rename(d, id: conv.id, title: "Mine")
            try ChatConversationQueries.setPrefixTitle(d, id: conv.id, text: "other")
            let row = try XCTUnwrap(ChatConversationQueries.fetchByID(d, id: conv.id))
            XCTAssertEqual(row.title, "Mine")
            XCTAssertEqual(row.titleSource, "user")
        }
    }

    func testPinArchiveAndProjectAndProviderModel() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let conv = try ChatConversationQueries.create(d)
            try ChatConversationQueries.pin(d, id: conv.id, pinned: true)
            try ChatConversationQueries.setProviderModel(d, id: conv.id, provider: "codex", model: nil)
            var row = try XCTUnwrap(ChatConversationQueries.fetchByID(d, id: conv.id))
            XCTAssertTrue(row.pinned)
            XCTAssertEqual(row.provider, "codex")
            XCTAssertNil(row.model)

            try ChatConversationQueries.archive(d, id: conv.id)
            XCTAssertTrue(try ChatConversationQueries.fetchStandalone(d).isEmpty, "archived chats leave the history")
            row = try XCTUnwrap(ChatConversationQueries.fetchByID(d, id: conv.id))
            XCTAssertNotNil(row.archivedAt)
        }
    }

    func testCreateInProject() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            try d.execute(sql: "INSERT INTO chat_projects (name, created_at, updated_at) VALUES ('P', 0, 0)")
            let project = d.lastInsertedRowID
            let conv = try ChatConversationQueries.create(d, projectID: project)
            XCTAssertEqual(conv.projectID, project)
            try ChatConversationQueries.setProject(d, id: conv.id, projectID: nil)
            XCTAssertNil(try ChatConversationQueries.fetchByID(d, id: conv.id)?.projectID)
        }
    }

    func testProjectGuardedSessionIDWriteSkipsAMovedConversation() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            try d.execute(sql: "INSERT INTO chat_projects (name, created_at, updated_at) VALUES ('P', 0, 0)")
            let project = d.lastInsertedRowID
            let conv = try ChatConversationQueries.create(d)

            try ChatConversationQueries.updateSessionID(d, id: conv.id, sessionID: "s-none", projectID: nil)
            XCTAssertEqual(try ChatConversationQueries.fetchByID(d, id: conv.id)?.sessionID, "s-none")

            try ChatConversationQueries.setProject(d, id: conv.id, projectID: project)
            try ChatConversationQueries.updateSessionID(d, id: conv.id, sessionID: "s-late", projectID: nil)
            XCTAssertNil(try ChatConversationQueries.fetchByID(d, id: conv.id)?.sessionID,
                         "a session spawned outside the project writes nothing")
            try ChatConversationQueries.updateSessionID(d, id: conv.id, sessionID: "s-proj", projectID: project)
            XCTAssertEqual(try ChatConversationQueries.fetchByID(d, id: conv.id)?.sessionID, "s-proj")
        }
    }

    /// A resumed Claude session keeps the prompt it started with, so a real
    /// move drops the stored session; a same-project "move" keeps it.
    func testSetProjectClearsTheStoredSessionOnlyOnARealMove() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            try d.execute(sql: "INSERT INTO chat_projects (name, created_at, updated_at) VALUES ('P', 0, 0)")
            let project = d.lastInsertedRowID
            let conv = try ChatConversationQueries.create(d, projectID: project)
            try d.execute(sql: "UPDATE chat_conversations SET session_id = 'sess-1' WHERE id = ?", arguments: [conv.id])

            try ChatConversationQueries.setProject(d, id: conv.id, projectID: project)
            XCTAssertEqual(try ChatConversationQueries.fetchByID(d, id: conv.id)?.sessionID, "sess-1")

            try ChatConversationQueries.setProject(d, id: conv.id, projectID: nil)
            let moved = try XCTUnwrap(ChatConversationQueries.fetchByID(d, id: conv.id))
            XCTAssertNil(moved.projectID)
            XCTAssertNil(moved.sessionID)
        }
    }

    /// `chat title` fires once: after the FIRST completed assistant reply,
    /// and never over an owner rename.
    func testNeedsAITitleOnlyAfterTheFirstCompletedReply() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            XCTAssertFalse(try ChatConversationQueries.needsAITitle(d, id: conv))
            try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "a", status: "partial")
            XCTAssertFalse(try ChatConversationQueries.needsAITitle(d, id: conv), "a partial reply is not a finished exchange")
            try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "b")
            XCTAssertTrue(try ChatConversationQueries.needsAITitle(d, id: conv))
            try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "c")
            XCTAssertFalse(try ChatConversationQueries.needsAITitle(d, id: conv))
        }
    }

    func testNeedsAITitleIsFalseForAUserTitle() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "b")
            try ChatConversationQueries.rename(d, id: conv, title: "Mine")
            XCTAssertFalse(try ChatConversationQueries.needsAITitle(d, id: conv))
        }
    }
}
