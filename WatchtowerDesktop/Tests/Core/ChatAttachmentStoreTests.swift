import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatAttachmentStoreTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private var root: URL!
    private var src: URL!
    private var store: ChatAttachmentStore!
    private var conversationID: Int64 = 0

    override func setUpWithError() throws {
        dbQueue = try TestDatabase.create()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chatfiles-\(UUID().uuidString)")
        src = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        store = ChatAttachmentStore(db: dbQueue, rootDir: root)
        conversationID = try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 0, 0)")
            return db.lastInsertedRowID
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: src)
    }

    private func source(_ name: String, _ data: Data) throws -> URL {
        let url = src.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func insertUserMessage() throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO chat_messages (conversation_id, role, text, turn_id, created_at) VALUES (?, 'user', 'hi', '', 0)",
                arguments: [conversationID])
            return db.lastInsertedRowID
        }
    }

    func testImportCopiesFileWith0600UnderConversationDir() throws {
        let att = try store.importFile(url: source("shot.png", AttachmentValidatorTests.png), conversationID: conversationID)
        XCTAssertEqual(att.name, "shot.png")
        XCTAssertEqual(att.mime, "image/png")
        XCTAssertEqual(att.size, Int64(AttachmentValidatorTests.png.count))
        XCTAssertEqual(att.conversationID, conversationID)
        XCTAssertNil(att.projectID)
        XCTAssertNil(att.messageID)
        XCTAssertTrue(att.path.hasPrefix(root.appendingPathComponent("conversations/\(conversationID)").path))
        XCTAssertTrue(att.path.hasSuffix(".png"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: att.path)), AttachmentValidatorTests.png)
        let perms = try FileManager.default.attributesOfItem(atPath: att.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testSameFileTwiceSharesStorageButGetsTwoRows() throws {
        let url = try source("shot.png", AttachmentValidatorTests.png)
        let first = try store.importFile(url: url, conversationID: conversationID)
        let second = try store.importFile(url: url, conversationID: conversationID)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.path, second.path)
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory(for: .conversation(conversationID)).path)
        XCTAssertEqual(files.count, 1)

        try store.discard(first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path), "still referenced by the second row")
        try store.discard(second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testRejectedFileLeavesNoRowAndNoFile() throws {
        XCTAssertThrowsError(try store.importFile(url: source("a.zip", AttachmentValidatorTests.zip), conversationID: conversationID)) { error in
            XCTAssertEqual(error as? AttachmentRejection, .unsupportedType(fileName: "a.zip"))
        }
        let count = try dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_attachments") }
        XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testImportDataForPastedImage() throws {
        let att = try store.importData(AttachmentValidatorTests.png, name: "Pasted image.png", owner: .conversation(conversationID))
        XCTAssertEqual(att.name, "Pasted image.png")
        XCTAssertEqual(att.mime, "image/png")
    }

    func testProjectOwnerUsesProjectsDir() throws {
        let projectID = try dbQueue.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO chat_projects (name, instructions, created_at, updated_at) VALUES ('P', '', 0, 0)")
            return db.lastInsertedRowID
        }
        let att = try store.importFile(url: source("n.md", Data("x".utf8)), projectID: projectID)
        XCTAssertEqual(att.projectID, projectID)
        XCTAssertNil(att.conversationID)
        XCTAssertTrue(att.path.hasPrefix(root.appendingPathComponent("projects/\(projectID)").path))
    }

    /// A new project file changes what a fresh session attaches or inlines:
    /// the project's chats lose their stored session (a `--resume` would
    /// never see the file); a conversation's own attachment drops nothing.
    func testProjectFileImportDropsTheProjectsStoredSessions() throws {
        let (projectID, inProject) = try dbQueue.write { db -> (Int64, Int64) in
            try db.execute(sql: "INSERT INTO chat_projects (name, instructions, created_at, updated_at) VALUES ('P', '', 0, 0)")
            let pid = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO chat_conversations (title, created_at, updated_at, project_id, session_id)
                VALUES ('', 0, 0, ?, 'sess-p')
                """, arguments: [pid])
            let inProject = db.lastInsertedRowID
            try db.execute(sql: "UPDATE chat_conversations SET session_id = 'sess-c' WHERE id = ?", arguments: [conversationID])
            return (pid, inProject)
        }
        _ = try store.importFile(url: source("a.md", Data("a".utf8)), conversationID: conversationID)
        XCTAssertEqual(try sessionID(inProject), "sess-p")
        _ = try store.importFile(url: source("b.md", Data("b".utf8)), projectID: projectID)
        XCTAssertNil(try sessionID(inProject))
        XCTAssertEqual(try sessionID(conversationID), "sess-c")
    }

    private func sessionID(_ id: Int64) throws -> String? {
        try dbQueue.read { try String.fetchOne($0, sql: "SELECT session_id FROM chat_conversations WHERE id = ?", arguments: [id]) }
    }

    func testLinkAndFetchByMessages() throws {
        let att = try store.importFile(url: source("n.md", Data("x".utf8)), conversationID: conversationID)
        let messageID = try insertUserMessage()
        try dbQueue.write { try ChatAttachmentQueries.link($0, attachmentIDs: [att.id], messageID: messageID) }
        let byMessage = try dbQueue.read { try ChatAttachmentQueries.fetchByMessages($0, messageIDs: [messageID]) }
        XCTAssertEqual(byMessage[messageID]?.map(\.id), [att.id])
        XCTAssertEqual(try dbQueue.read { try ChatAttachmentQueries.fetchByMessages($0, messageIDs: []) }, [:])

        // Linking never steals a row that already belongs to a message.
        let other = try insertUserMessage()
        try dbQueue.write { try ChatAttachmentQueries.link($0, attachmentIDs: [att.id], messageID: other) }
        let again = try dbQueue.read { try ChatAttachmentQueries.fetchByMessages($0, messageIDs: [messageID, other]) }
        XCTAssertEqual(again[messageID]?.count, 1)
        XCTAssertNil(again[other])
    }

    func testRemoveFilesDeletesOwnerDirectory() throws {
        let att = try store.importFile(url: source("shot.png", AttachmentValidatorTests.png), conversationID: conversationID)
        ChatAttachmentStore.removeFiles(for: .conversation(conversationID), rootDir: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: att.path))
        // Missing directory is a no-op, not a crash.
        ChatAttachmentStore.removeFiles(for: .conversation(conversationID), rootDir: root)
    }
}
