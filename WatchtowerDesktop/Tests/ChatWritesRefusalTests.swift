import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerInterface
import WatchtowerTestSupport

/// A chat write is a `chat.*` tower command (mobile Inbox spec §8): the row
/// changes at once, and a refusal puts it back and shows Go's sentence.
@MainActor
final class ChatWritesRefusalTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var tower: FakeChatTower!
    private var history: ChatHistoryViewModel!
    private var conversationID: Int64 = 0
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        suite = "ChatWritesRefusalTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        tower = FakeChatTower(db: dbManager.dbPool)
        conversationID = try await dbManager.dbPool.write { db in
            let conv = try TestDatabase.insertChatConversation(db, title: "Plans")
            let user = try TestDatabase.insertChatMessage(db, conversationID: conv, role: "user", text: "q")
            let answer = try TestDatabase.insertChatMessage(db, conversationID: conv, role: "assistant", text: "a",
                                                            parentID: user)
            try db.execute(sql: "UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?",
                           arguments: [answer, conv])
            return conv
        }
        history = ChatHistoryViewModel(dbManager: dbManager, writes: ChatWrites(tower: tower), defaults: defaults)
        await withCheckedContinuation { done in history.reloadRows { done.resume() } }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        defaults.removePersistentDomain(forName: suite)
    }

    private var row: ChatConversation? { history.conversations.first { $0.id == conversationID } }

    func testPinRefusalRevertsTheRow() async {
        tower.refuse(.chatPin, with: "This chat no longer exists.")
        let pinning = Task { await history.togglePin(conversationID) }
        await untilTurn { self.row?.pinned == true }
        await pinning.value
        XCTAssertEqual(row?.pinned, false, "the refusal puts it back")
        XCTAssertEqual(history.lastError, "This chat no longer exists.")
    }

    func testRenameRefusalReverts() async {
        tower.refuse(.chatRename, with: "A chat's name can't be empty.")
        let renaming = Task { await history.rename(conversationID, title: "Roadmap") }
        await untilTurn { self.row?.title == "Roadmap" }
        await renaming.value
        XCTAssertEqual(row?.title, "Plans")
        XCTAssertEqual(history.lastError, "A chat's name can't be empty.")
    }

    func testDeleteRefusalReverts() async {
        tower.refuse(.chatDelete, with: "Watchtower couldn't apply this.")
        await history.deleteConversation(conversationID)
        XCTAssertNotNil(row, "the chat stays listed")
        XCTAssertEqual(history.lastError, "Could not delete the chat: Watchtower couldn't apply this.")
        XCTAssertEqual(tower.calls(.chatDelete).count, 1)
    }

    func testReadRefusalReverts() async {
        XCTAssertNil(row?.readAt)
        tower.refuse(.chatRead, with: "This chat no longer exists.")
        history.markRead(conversationID)
        XCTAssertNotNil(row?.readAt, "read at once")
        await history.writesSettled()
        XCTAssertNil(row?.readAt, "the refusal puts it back")
    }

    func testBranchRefusalReverts() async throws {
        let pool = ChatSessionPool(dbPool: dbManager.dbPool,
                                   processFactory: { FakeChatSessionProcess(arguments: $0) },
                                   closeGrace: .milliseconds(20))
        let chat = ChatViewModel(dbManager: dbManager, pool: pool, writes: ChatWrites(tower: tower), defaults: defaults)
        chat.select(conversationID: conversationID)
        let shown = chat.thread.map(\.id)
        tower.refuse(.chatBranch, with: "This message no longer exists.")
        await chat.selectVariant(messageID: try XCTUnwrap(shown.last))
        XCTAssertEqual(chat.thread.map(\.id), shown, "the thread is as it was")
        XCTAssertEqual(chat.errorMessage, "Couldn't switch the variant: This message no longer exists.")
        await pool.closeAll()
    }
}
