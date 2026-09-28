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

    func testSectionsPinRenameArchive() async throws {
        let (a, b) = try await dbManager.dbPool.write { d in
            (try TestDatabase.insertChatConversation(d, title: "A"), try TestDatabase.insertChatConversation(d, title: "B"))
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
