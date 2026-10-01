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

    // MARK: - Untouched chats (the landing's draft)

    func testUntouchedQueriesSpareEverythingTheOwnerTouched() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let untouched = try TestDatabase.insertChatConversation(d, title: "")
            let messaged = try TestDatabase.insertChatConversation(d, title: "m")
            try TestDatabase.insertChatMessage(d, conversationID: messaged, role: "user", text: "hi")
            let attached = try TestDatabase.insertChatConversation(d, title: "a")
            try d.execute(sql: """
                INSERT INTO chat_attachments (conversation_id, name, mime, size, path, sha256, created_at)
                VALUES (?, 'f.txt', 'text/plain', 1, 'f.txt', 'x', 0)
                """, arguments: [attached])
            let project = try ChatProjectQueries.create(d, name: "P")
            let inProject = try ChatConversationQueries.create(d, projectID: project.id).id
            let archived = try TestDatabase.insertChatConversation(d, title: "")
            try ChatConversationQueries.archive(d, id: archived)
            let scoped = try TestDatabase.insertChatConversation(d, title: "", contextType: "target")
            let pinned = try TestDatabase.insertChatConversation(d, title: "", pinned: true)
            let renamed = try TestDatabase.insertChatConversation(d, title: "")
            try ChatConversationQueries.rename(d, id: renamed, title: "Mine")

            func created(_ id: Int64) throws -> Double { try XCTUnwrap(ChatConversationQueries.fetchByID(d, id: id)).createdAt }
            let stamp = try created(untouched)
            XCTAssertEqual(try ChatConversationQueries.fetchUntouched(d, id: untouched, createdAt: stamp)?.id, untouched)
            for kept in [messaged, attached, inProject, archived, scoped, pinned, renamed] {
                let at = try created(kept)
                XCTAssertNil(try ChatConversationQueries.fetchUntouched(d, id: kept, createdAt: at), "\(kept)")
                XCTAssertFalse(try ChatConversationQueries.deleteIfUntouched(d, id: kept, createdAt: at), "\(kept)")
            }
            // Same id, another row (a reset database): never matched.
            XCTAssertNil(try ChatConversationQueries.fetchUntouched(d, id: untouched, createdAt: stamp + 1))
            XCTAssertFalse(try ChatConversationQueries.deleteIfUntouched(d, id: untouched, createdAt: stamp + 1))
            XCTAssertTrue(try ChatConversationQueries.deleteIfUntouched(d, id: untouched, createdAt: stamp))
            XCTAssertFalse(try ChatConversationQueries.deleteIfUntouched(d, id: untouched, createdAt: stamp), "already gone")
        }
    }

    func testStandaloneListFlagsChatsWithUnsentFiles() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let plain = try TestDatabase.insertChatConversation(d, title: "plain")
            let withFile = try TestDatabase.insertChatConversation(d, title: "file")
            try d.execute(sql: """
                INSERT INTO chat_attachments (conversation_id, name, mime, size, path, sha256, created_at)
                VALUES (?, 'f.txt', 'text/plain', 1, 'f.txt', 'x', 0)
                """, arguments: [withFile])
            let byID = Dictionary(uniqueKeysWithValues: try ChatConversationQueries.fetchStandalone(d).map { ($0.id, $0) })
            XCTAssertEqual(byID[plain]?.hasAttachments, false)
            XCTAssertEqual(byID[withFile]?.hasAttachments, true)
            XCTAssertEqual(ChatLandingPolicy.recents(Array(byID.values)).map(\.id), [withFile])
            XCTAssertEqual(try ChatAttachmentQueries.fetchPending(d, conversationID: withFile).count, 1)
            XCTAssertTrue(try ChatAttachmentQueries.fetchPending(d, conversationID: plain).isEmpty)
        }
    }
}
