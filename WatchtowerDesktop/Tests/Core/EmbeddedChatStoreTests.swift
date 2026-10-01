import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

@MainActor
final class EmbeddedChatStoreTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var conversationID: Int64 = 0

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        conversationID = try pool.write { db in
            try TestDatabase.insertChatConversation(db, title: "Track: x", contextType: "track")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
    }

    private func stores() -> [EmbeddedChatStore] {
        [DatabaseEmbeddedChatStore(dbPool: pool, conversationID: conversationID), MemoryEmbeddedChatStore()]
    }

    func testBeginTurnWritesTheOwnerRowThenAnEmptyPartialReply() throws {
        for store in stores() {
            let ids = try store.beginTurn(ownerText: "hello", turnID: "t1")
            let rows = try store.loadMessages()
            XCTAssertEqual(rows.map(\.role), ["user", "assistant"], "\(store)")
            XCTAssertEqual(rows.map(\.id), [ids.ownerID, ids.assistantID].compactMap { $0 })
            XCTAssertEqual(rows[1].status, "partial")
            XCTAssertEqual(rows[1].text, "")
            XCTAssertEqual(rows.map(\.turnID), ["t1", "t1"])
        }
    }

    func testFollowUpTurnWritesNoOwnerRow() throws {
        for store in stores() {
            let ids = try store.beginTurn(ownerText: nil, turnID: "t1")
            XCTAssertNil(ids.ownerID)
            XCTAssertEqual(try store.loadMessages().map(\.role), ["assistant"])
        }
    }

    func testProgressAndFinalizeUpdateTheReply() throws {
        for store in stores() {
            let ids = try store.beginTurn(ownerText: "q", turnID: "t")
            try store.saveProgress(messageID: ids.assistantID, text: "half")
            XCTAssertEqual(try store.loadMessages().last?.text, "half")
            try store.finalize(messageID: ids.assistantID, text: "half and more", status: "error",
                               errorCode: "auth", errorMessage: "not logged in")
            let reply = try XCTUnwrap(store.loadMessages().last)
            XCTAssertEqual(reply.text, "half and more")
            XCTAssertEqual(reply.status, "error")
            XCTAssertEqual(reply.errorCode, "auth")
            XCTAssertEqual(reply.errorMessage, "not logged in")
        }
    }

    func testSessionIDRoundTrips() throws {
        for store in stores() {
            XCTAssertNil(try store.loadSessionID())
            try store.saveSessionID("s-1")
            XCTAssertEqual(try store.loadSessionID(), "s-1")
        }
    }

    func testMemoryIDsNeverCollideWithPersistedOnes() throws {
        let store = MemoryEmbeddedChatStore()
        let id = try store.append(role: "assistant", text: "Hi!")
        XCTAssertLessThan(id, 0)
    }

    func testADeletedConversationThrowsContextGone() throws {
        let store = DatabaseEmbeddedChatStore(dbPool: pool, conversationID: conversationID)
        let ids = try store.beginTurn(ownerText: "q", turnID: "t")
        let id = conversationID
        try pool.write { db in try ChatConversationQueries.delete(db, id: id) }
        XCTAssertThrowsError(try store.saveProgress(messageID: ids.assistantID, text: "x")) {
            XCTAssertTrue($0 is ChatContextGoneError)
        }
        XCTAssertThrowsError(try store.beginTurn(ownerText: "again", turnID: "t2")) {
            XCTAssertTrue($0 is ChatContextGoneError)
        }
        XCTAssertThrowsError(try store.loadSessionID()) { XCTAssertTrue($0 is ChatContextGoneError) }
    }

    /// Storage format unchanged: an embedded row leaves the main chat's tree
    /// columns at their defaults, so existing readers see a linear thread.
    func testDatabaseRowsKeepTheTreeColumnsAtTheirDefaults() throws {
        let store = DatabaseEmbeddedChatStore(dbPool: pool, conversationID: conversationID)
        let ids = try store.beginTurn(ownerText: "q", turnID: "t")
        try store.finalize(messageID: ids.assistantID, text: "a", status: "complete", errorCode: nil, errorMessage: nil)
        let rows = try store.loadMessages()
        XCTAssertTrue(rows.allSatisfy { $0.parentID == nil && $0.provider == nil && $0.tokensIn == nil })
        XCTAssertEqual(rows.last?.status, "complete")
        XCTAssertNil(rows.last?.errorCode)
    }
}
