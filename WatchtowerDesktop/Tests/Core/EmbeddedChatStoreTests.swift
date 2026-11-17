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

    /// The stores that write a turn's rows in-process: the memory store. A
    /// database chat's rows are written by its `ai query --persist` run; the
    /// same promises are Go's `TestEmbeddedTurn_*` (`internal/chatstore`):
    /// BeginWritesOwnerAndPartialReply, ReplyRecordsItsProvider,
    /// FollowUpWritesNoOwnerRow, ErrorEndKeepsTheTextAndItsCode,
    /// RowsKeepTheTreeColumnsAtTheirDefaults,
    /// OnlyACompletedReplyTouchesTheConversation, DeletedConversationMidTurnIsGone.
    private func stores() -> [EmbeddedChatStore] {
        [MemoryEmbeddedChatStore()]
    }

    func testBeginTurnWritesTheOwnerRowThenAnEmptyPartialReply() async throws {
        for store in stores() {
            let ids = try await store.beginTurn(ownerText: "hello", turnID: "t1", provider: "codex")
            let rows = try store.loadMessages()
            XCTAssertEqual(rows.map(\.role), ["user", "assistant"], "\(store)")
            XCTAssertEqual(rows.map(\.id), [ids.ownerID, ids.assistantID].compactMap { $0 })
            XCTAssertEqual(rows[1].status, "partial")
            XCTAssertEqual(rows[1].text, "")
            XCTAssertEqual(rows.map(\.turnID), ["t1", "t1"])
            XCTAssertEqual(rows[1].provider, "codex", "the error card's sign-in hint reads it")
        }
    }

    func testFollowUpTurnWritesNoOwnerRow() async throws {
        for store in stores() {
            let ids = try await store.beginTurn(ownerText: nil, turnID: "t1", provider: nil)
            XCTAssertNil(ids.ownerID)
            XCTAssertEqual(try store.loadMessages().map(\.role), ["assistant"])
        }
    }

    func testProgressAndFinalizeUpdateTheReply() async throws {
        for store in stores() {
            let ids = try await store.beginTurn(ownerText: "q", turnID: "t", provider: nil)
            try await store.saveProgress(messageID: ids.assistantID, text: "half")
            XCTAssertEqual(try store.loadMessages().last?.text, "half")
            try await store.finalize(messageID: ids.assistantID, text: "half and more", status: "error",
                                     errorCode: "auth", errorMessage: "not logged in")
            let reply = try XCTUnwrap(store.loadMessages().last)
            XCTAssertEqual(reply.text, "half and more")
            XCTAssertEqual(reply.status, "error")
            XCTAssertEqual(reply.errorCode, "auth")
            XCTAssertEqual(reply.errorMessage, "not logged in")
        }
    }

    func testMemoryIDsNeverCollideWithPersistedOnes() async throws {
        let store = MemoryEmbeddedChatStore()
        let id = try await store.append(role: "assistant", text: "Hi!")
        XCTAssertLessThan(id, 0)
    }

    /// The database store never writes a turn's rows itself (its run does),
    /// and a deleted chat reads as gone.
    func testADeletedConversationThrowsContextGone() async throws {
        let store = DatabaseEmbeddedChatStore(dbPool: pool, conversationID: conversationID)
        do {
            _ = try await store.beginTurn(ownerText: "q", turnID: "t", provider: nil)
            XCTFail("the database store writes no turn rows")
        } catch {
            XCTAssertTrue(error is ChatWriteError, "\(error)")
        }
        XCTAssertTrue(try store.loadMessages().isEmpty, "nothing was written")
        let id = conversationID
        try await pool.write { db in try ChatConversationQueries.delete(db, id: id) }
        XCTAssertThrowsError(try store.loadMessages()) { XCTAssertTrue($0 is ChatContextGoneError) }
    }

    func testConversationIDReusesTheContextsConversation() async throws {
        let created = try await DatabaseEmbeddedChatStore.conversationID(
            dbPool: pool, contextType: "meeting", contextID: "7", title: "Meeting: weekly")
        let again = try await DatabaseEmbeddedChatStore.conversationID(
            dbPool: pool, contextType: "meeting", contextID: "7", title: "Meeting: renamed")
        XCTAssertEqual(created, again)
        let conv = try await pool.read { db in try ChatConversationQueries.fetchByID(db, id: created) }
        XCTAssertEqual(conv?.title, "Meeting: weekly")
        XCTAssertEqual(conv?.contextID, "7")
        let other = try await DatabaseEmbeddedChatStore.conversationID(
            dbPool: pool, contextType: "meeting", contextID: "8", title: "Meeting: other")
        XCTAssertNotEqual(other, created)
    }
}

extension EmbeddedChatStoreTests {
    func testMemoryActualMetadataSurvivesProgressAndTerminalError() async throws {
        let store = MemoryEmbeddedChatStore()
        let ids = try await store.beginTurn(ownerText: "Owner", turnID: "t", provider: "claude")
        try await store.saveActual(messageID: ids.assistantID, provider: "codex", model: "actual-model")
        try await store.saveProgress(messageID: ids.assistantID, text: "Partial")
        try await store.finalize(messageID: ids.assistantID, text: "Partial", status: "partial",
                                 errorCode: "quota_exhausted", errorMessage: "Quota reached")
        let row = try XCTUnwrap(store.loadMessages().last)
        XCTAssertEqual(row.provider, "codex")
        XCTAssertEqual(row.model, "actual-model")
        XCTAssertEqual(row.errorCode, "quota_exhausted")
    }
}
