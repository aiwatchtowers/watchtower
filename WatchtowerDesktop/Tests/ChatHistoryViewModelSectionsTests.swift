import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class ChatHistoryViewModelSectionsTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUpWithError() throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
    }

    private func loaded() async -> ChatHistoryViewModel {
        let vm = ChatHistoryViewModel(dbManager: dbManager)
        let done = expectation(description: "load")
        vm.reloadRows { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        return vm
    }

    /// A conversation with one message on its active path.
    nonisolated private static func answered(_ d: Database, title: String) throws -> Int64 {
        let id = try TestDatabase.insertChatConversation(d, title: title)
        let msg = try TestDatabase.insertChatMessage(d, conversationID: id, role: "user", text: title)
        try d.execute(sql: "UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?", arguments: [msg, id])
        return id
    }

    func testSectionsPinRenameArchive() async throws {
        let (a, b) = try await dbManager.dbPool.write { d in
            (try Self.answered(d, title: "A"), try Self.answered(d, title: "B"))
        }
        let vm = await loaded()
        XCTAssertEqual(vm.sections.map(\.kind), [.recent])

        await vm.togglePin(a)
        XCTAssertEqual(vm.sections.map(\.kind), [.pinned, .recent])
        await vm.rename(b, title: "  Renamed  ")
        XCTAssertEqual(vm.conversations.first { $0.id == b }?.title, "Renamed")
        XCTAssertEqual(vm.conversations.first { $0.id == b }?.titleSource, "user")
        await vm.rename(b, title: "   ")
        XCTAssertEqual(vm.conversations.first { $0.id == b }?.title, "Renamed", "an empty rename is ignored")

        await vm.archive(a)
        XCTAssertFalse(vm.conversations.contains { $0.id == a })
        XCTAssertNil(vm.lastError)
    }

    /// Archiving the chat on screen clears the selection: no other chat is
    /// selected — and marked read — in its place (the view shows the landing).
    func testArchivingTheSelectedChatSelectsNoOther() async throws {
        let (a, b) = try await dbManager.dbPool.write { d -> (Int64, Int64) in
            let a = try Self.answered(d, title: "A")
            let b = try Self.answered(d, title: "B")
            let parent = try Int64.fetchOne(d, sql: "SELECT active_leaf_message_id FROM chat_conversations WHERE id = ?",
                                            arguments: [b])
            let answer = try TestDatabase.insertChatMessage(
                d, conversationID: b, role: "assistant", text: "unread", parentID: parent)
            try d.execute(sql: "UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?",
                          arguments: [answer, b])
            return (a, b)
        }
        let vm = await loaded()
        vm.selectedConversationID = a
        await vm.writesSettled()
        await vm.archive(a)
        XCTAssertNil(vm.selectedConversationID)
        await vm.writesSettled()
        let readAt = try await dbManager.dbPool.read {
            try Double.fetchOne($0, sql: "SELECT read_at FROM chat_conversations WHERE id = ?", arguments: [b])
        }
        XCTAssertNil(readAt, "the other chat was never shown, so it stays unread")
    }

    /// A message-less chat (the landing's unsent draft) is listed only while selected.
    func testMessageLessChatsAreListedOnlyWhileSelected() async throws {
        let (answered, empty) = try await dbManager.dbPool.write { d in
            (try Self.answered(d, title: "A"), try TestDatabase.insertChatConversation(d, title: ""))
        }
        let vm = await loaded()
        XCTAssertEqual(vm.sections.flatMap(\.items).map(\.id), [answered])
        vm.selectedConversationID = empty
        XCTAssertEqual(Set(vm.sections.flatMap(\.items).map(\.id)), [answered, empty])
    }

    func testSearchFindsMessages() async throws {
        try await dbManager.dbPool.write { d in
            let conv = try TestDatabase.insertChatConversation(d, title: "X")
            try TestDatabase.insertChatMessage(d, conversationID: conv, role: "user", text: "payments rollout")
        }
        let vm = await loaded()
        XCTAssertEqual(vm.search("rollout").compactMap(\.messageID).count, 1)
        XCTAssertTrue(vm.search("").isEmpty)
    }
}
