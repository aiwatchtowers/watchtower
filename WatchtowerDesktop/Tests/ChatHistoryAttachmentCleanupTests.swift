import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

@MainActor
final class ChatHistoryAttachmentCleanupTests: XCTestCase {
    func testDeletingConversationRemovesItsFilesAfterCommit() async throws {
        let (dbManager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let history = ChatHistoryViewModel(dbManager: dbManager, attachmentsRoot: root)
        let conversationRow = await history.createConversation()
        let conversation = try XCTUnwrap(conversationRow)
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).md")
        try Data("x".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }
        let att = try await ChatAttachmentStore(db: dbManager.dbPool, rootDir: root).importFile(url: src, conversationID: conversation.id)

        await history.deleteConversation(conversation.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: att.path))
        let rows = try await dbManager.dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_attachments") }
        XCTAssertEqual(rows, 0, "rows go by FK cascade")
    }

    /// No active workspace (`attachmentsRoot == nil`, the default in prod):
    /// delete still succeeds — it just has no files to clean up.
    func testNoAttachmentsRootIsANoOp() async throws {
        let (dbManager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        let history = ChatHistoryViewModel(dbManager: dbManager, attachmentsRoot: nil)
        let conversationRow = await history.createConversation()
        let conversation = try XCTUnwrap(conversationRow)

        await history.deleteConversation(conversation.id)

        let rows = try await dbManager.dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_conversations") }
        XCTAssertEqual(rows, 0)
    }
}
