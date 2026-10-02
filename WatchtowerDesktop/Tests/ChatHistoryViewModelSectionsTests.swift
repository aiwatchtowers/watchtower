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
        vm.load { done.fulfill() }
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
        XCTAssertEqual(vm.sections.map(\.kind), [.today])

        vm.togglePin(a)
        XCTAssertEqual(vm.sections.map(\.kind), [.pinned, .today])
        vm.rename(b, title: "  Renamed  ")
        XCTAssertEqual(vm.conversations.first { $0.id == b }?.title, "Renamed")
        XCTAssertEqual(vm.conversations.first { $0.id == b }?.titleSource, "user")
        vm.rename(b, title: "   ")
        XCTAssertEqual(vm.conversations.first { $0.id == b }?.title, "Renamed", "an empty rename is ignored")

        vm.archive(a)
        XCTAssertFalse(vm.conversations.contains { $0.id == a })
        XCTAssertNil(vm.lastError)
    }

    /// A message-less chat (the landing's unsent draft) is listed only while selected.
    /// ↑/↓ walk the chats in the order shown (Pinned first), stop at the
    /// ends, and with nothing selected start from the first (↓) or last (↑).
    func testSelectAdjacentWalksTheListedOrder() async throws {
        let (a, b, c) = try await dbManager.dbPool.write { d in
            (try Self.answered(d, title: "A"), try Self.answered(d, title: "B"), try Self.answered(d, title: "C"))
        }
        let vm = await loaded()
        XCTAssertFalse(vm.selectAdjacent(by: 0))
        vm.togglePin(b)
        let shown = vm.sections.flatMap(\.conversations).map(\.id)
        XCTAssertEqual(shown.first, b, "the pinned chat leads")
        XCTAssertEqual(Set(shown), [a, b, c])

        XCTAssertNil(vm.selectedConversationID)
        XCTAssertTrue(vm.selectAdjacent(by: 1))
        XCTAssertEqual(vm.selectedConversationID, shown[0])
        XCTAssertFalse(vm.selectAdjacent(by: -1), "already the first")
        XCTAssertEqual(vm.selectedConversationID, shown[0])
        XCTAssertTrue(vm.selectAdjacent(by: 1))
        XCTAssertTrue(vm.selectAdjacent(by: 1))
        XCTAssertEqual(vm.selectedConversationID, shown[2])
        XCTAssertFalse(vm.selectAdjacent(by: 1), "already the last")
        XCTAssertTrue(vm.selectAdjacent(by: -1))
        XCTAssertEqual(vm.selectedConversationID, shown[1])

        vm.selectedConversationID = nil
        XCTAssertTrue(vm.selectAdjacent(by: -1))
        XCTAssertEqual(vm.selectedConversationID, shown[2], "↑ with nothing selected picks the last")
    }

    func testSelectAdjacentOnAnEmptyHistoryDoesNothing() async {
        let vm = await loaded()
        XCTAssertFalse(vm.selectAdjacent(by: 1))
        XCTAssertFalse(vm.selectAdjacent(by: -1))
        XCTAssertNil(vm.selectedConversationID)
    }

    func testMessageLessChatsAreListedOnlyWhileSelected() async throws {
        let (answered, empty) = try await dbManager.dbPool.write { d in
            (try Self.answered(d, title: "A"), try TestDatabase.insertChatConversation(d, title: ""))
        }
        let vm = await loaded()
        XCTAssertEqual(vm.sections.flatMap(\.conversations).map(\.id), [answered])
        vm.selectedConversationID = empty
        XCTAssertEqual(Set(vm.sections.flatMap(\.conversations).map(\.id)), [answered, empty])
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
