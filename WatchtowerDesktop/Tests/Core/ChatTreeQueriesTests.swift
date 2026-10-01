import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatTreeQueriesTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    /// A conversation migrated from the Swift-created tables has no leaf; its
    /// thread is every message in id order (Go `ActiveChatPath` does the same).
    func testConversationWithoutLeafReadsLinearIdOrder() throws {
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let a = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "user", text: "a")
            let b = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "b", parentID: a)
            let path = try ChatTreeQueries.activePath(d, conversationID: conv)
            XCTAssertEqual(path.map(\.id), [a, b])
        }
    }

    func testInsertsChainAndMoveTheLeaf() throws {
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let user = try ChatTreeQueries.insertUser(d, conversationID: conv, parentID: nil, text: "q", turnID: "t1")
            let asst = try ChatTreeQueries.insertAssistant(
                d, conversationID: conv, parentID: user.id, turnID: "t1", provider: "claude", model: "")
            XCTAssertEqual(asst.status, "partial", "an assistant row starts partial until turn_done")
            XCTAssertNil(asst.model, "an empty model is stored as NULL")
            let conversation = try XCTUnwrap(ChatConversationQueries.fetchByID(d, id: conv))
            XCTAssertEqual(conversation.activeLeafMessageID, asst.id)
            XCTAssertEqual(try ChatTreeQueries.activePath(d, conversationID: conv).map(\.id), [user.id, asst.id])
        }
    }

    func testRegenerateMakesASiblingAndSelectSiblingSwitchesBranch() throws {
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let user = try ChatTreeQueries.insertUser(d, conversationID: conv, parentID: nil, text: "q", turnID: "t1")
            let first = try ChatTreeQueries.insertAssistant(
                d, conversationID: conv, parentID: user.id, turnID: "t1", provider: "claude", model: "")
            let second = try ChatTreeQueries.insertAssistant(
                d, conversationID: conv, parentID: user.id, turnID: "t2", provider: "claude", model: "")
            XCTAssertEqual(try ChatTreeQueries.siblings(d, messageID: first.id).map(\.id), [first.id, second.id])
            XCTAssertEqual(try ChatTreeQueries.activePath(d, conversationID: conv).last?.id, second.id)

            try ChatTreeQueries.selectSibling(d, conversationID: conv, siblingID: first.id)
            XCTAssertEqual(try ChatTreeQueries.activePath(d, conversationID: conv).last?.id, first.id)
        }
    }

    func testThreadCarriesSiblingPositionsAndSteps() throws {
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let user = try ChatTreeQueries.insertUser(d, conversationID: conv, parentID: nil, text: "q", turnID: "t1")
            _ = try ChatTreeQueries.insertAssistant(d, conversationID: conv, parentID: user.id, turnID: "t1", provider: "claude", model: "")
            let second = try ChatTreeQueries.insertAssistant(
                d, conversationID: conv, parentID: user.id, turnID: "t2", provider: "claude", model: "")
            try ChatStepQueries.upsertStart(d, messageID: second.id, seq: 0, toolID: "tu1", name: "search_knowledge",
                                            argsJSON: #"{"queries":["x"]}"#, startedAt: 10)

            let thread = try ChatTreeQueries.thread(d, conversationID: conv)
            XCTAssertEqual(thread.map(\.id), [user.id, second.id])
            XCTAssertEqual(thread[1].siblingIndex, 2)
            XCTAssertEqual(thread[1].siblingCount, 2)
            XCTAssertEqual(thread[1].steps.map(\.name), ["search_knowledge"])
            XCTAssertEqual(thread[0].siblingCount, 1)
        }
    }

    func testUpdateAssistantWritesStatusUsageAndError() throws {
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let asst = try ChatTreeQueries.insertAssistant(d, conversationID: conv, parentID: nil, turnID: "t", provider: "claude", model: "")
            try ChatTreeQueries.updateAssistant(d, id: asst.id, text: "hi", status: "error", tokensIn: 3, tokensOut: 4,
                                                errorCode: "rate_limit", errorMessage: "429 from the API")
            try ChatTreeQueries.setModel(d, messageID: asst.id, model: "model-b")
            let row = try XCTUnwrap(ChatMessageRecord.fetchOne(d, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [asst.id]))
            XCTAssertEqual(row.text, "hi")
            XCTAssertEqual(row.status, "error")
            XCTAssertEqual(row.tokensIn, 3)
            XCTAssertEqual(row.tokensOut, 4)
            XCTAssertEqual(row.errorCode, "rate_limit")
            XCTAssertEqual(row.errorMessage, "429 from the API")
            XCTAssertEqual(row.model, "model-b")
        }
    }

    /// Discuss chats never set a leaf or parents; they keep reading linearly.
    func testEmptyConversationHasEmptyThread() throws {
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            XCTAssertTrue(try ChatTreeQueries.thread(d, conversationID: conv).isEmpty)
        }
    }

    /// The newest message of ANY branch, not the active leaf: after switching
    /// to an older variant the newest row is still the other branch's.
    func testNewestMessageIgnoresTheActiveBranch() throws {
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            XCTAssertNil(try ChatTreeQueries.newestMessage(d, conversationID: conv))
            let user = try ChatTreeQueries.insertUser(d, conversationID: conv, parentID: nil, text: "q", turnID: "t1")
            let first = try ChatTreeQueries.insertAssistant(
                d, conversationID: conv, parentID: user.id, turnID: "t1", provider: "claude", model: "")
            let second = try ChatTreeQueries.insertAssistant(
                d, conversationID: conv, parentID: user.id, turnID: "t2", provider: "codex", model: "")
            try ChatTreeQueries.selectSibling(d, conversationID: conv, siblingID: first.id)
            XCTAssertEqual(try ChatTreeQueries.newestMessage(d, conversationID: conv)?.id, second.id)
        }
    }
}
