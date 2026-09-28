import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Entering the Chat tab: resume the last conversation within 2 h of its
/// last activity (or while a turn runs), otherwise the landing.
final class ChatLandingPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private typealias Last = ChatLandingPolicy.LastConversation

    private func last(
        id: Int64 = 7, idle: TimeInterval, archived: Bool = false, hasMessages: Bool = true, streaming: Bool = false
    ) -> Last {
        Last(id: id, updatedAt: now.addingTimeInterval(-idle), isArchived: archived,
             hasMessages: hasMessages, isStreaming: streaming)
    }

    private func decide(_ last: Last?, viewedAgo: TimeInterval? = nil) -> ChatLandingPolicy.Decision {
        ChatLandingPolicy.decide(last: last, lastViewedAt: viewedAgo.map { now.addingTimeInterval(-$0) }, now: now)
    }

    func testResumeWindowIsTwoHours() {
        XCTAssertEqual(ChatLandingPolicy.resumeWindow, 2 * 60 * 60)
    }

    func testResumesInsideTheWindow() {
        XCTAssertEqual(decide(last(idle: 5 * 60)), .resume(7))
        XCTAssertEqual(decide(last(idle: 2 * 3600 - 1)), .resume(7))
    }

    func testLandsOutsideTheWindow() {
        XCTAssertEqual(decide(last(idle: 2 * 3600 + 1)), .landing)
        XCTAssertEqual(decide(last(idle: 3 * 86_400)), .landing)
    }

    func testExactlyAtTheBoundaryLands() {
        XCTAssertEqual(decide(last(idle: 2 * 3600)), .landing)
    }

    func testStreamingAlwaysResumesWhateverTheTime() {
        XCTAssertEqual(decide(last(idle: 5 * 3600, streaming: true)), .resume(7))
        XCTAssertEqual(decide(last(idle: 2 * 3600, streaming: true)), .resume(7))
    }

    func testNoLastConversationLands() {
        XCTAssertEqual(decide(nil), .landing)
        XCTAssertEqual(decide(nil, viewedAgo: 60), .landing)
    }

    func testArchivedLastConversationLandsEvenWhenFresh() {
        XCTAssertEqual(decide(last(idle: 60, archived: true)), .landing)
        XCTAssertEqual(decide(last(idle: 60, archived: true, streaming: true)), .landing)
    }

    /// An untouched "New Chat" has nothing to resume into.
    func testConversationWithoutMessagesLands() {
        XCTAssertEqual(decide(last(idle: 60, hasMessages: false)), .landing)
    }

    /// Having the conversation on screen counts as activity: reading an old
    /// chat and stepping away briefly comes back to it.
    func testRecentViewingExtendsTheWindow() {
        XCTAssertEqual(decide(last(idle: 3 * 86_400), viewedAgo: 10 * 60), .resume(7))
        XCTAssertEqual(decide(last(idle: 3 * 86_400), viewedAgo: 2 * 3600), .landing)
    }

    /// An older view stamp never shortens the window a newer message opened.
    func testOlderViewStampDoesNotShortenTheWindow() {
        XCTAssertEqual(decide(last(idle: 60), viewedAgo: 5 * 3600), .resume(7))
    }

    func testLastConversationSnapshotFromARow() throws {
        let db = try TestDatabase.create()
        let (empty, full, archived) = try db.write { d -> (ChatConversation, ChatConversation, ChatConversation) in
            let emptyID = try TestDatabase.insertChatConversation(d, title: "empty")
            let fullID = try TestDatabase.insertChatConversation(d, title: "full")
            let msg = try TestDatabase.insertChatMessage(d, conversationID: fullID, role: "user", text: "hi")
            try d.execute(sql: "UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?",
                          arguments: [msg, fullID])
            let archivedID = try TestDatabase.insertChatConversation(d, title: "archived")
            try ChatConversationQueries.archive(d, id: archivedID)
            func fetch(_ id: Int64) throws -> ChatConversation {
                try XCTUnwrap(ChatConversationQueries.fetchByID(d, id: id))
            }
            return try (fetch(emptyID), fetch(fullID), fetch(archivedID))
        }
        XCTAssertFalse(Last(empty, isStreaming: false).hasMessages)
        XCTAssertTrue(Last(full, isStreaming: false).hasMessages)
        XCTAssertEqual(Last(full, isStreaming: false).updatedAt, full.updatedDate)
        XCTAssertTrue(Last(archived, isStreaming: false).isArchived)
        XCTAssertTrue(Last(empty, isStreaming: true).isStreaming)
    }

    // MARK: - Recents

    private func conversations(_ rows: [(String, TimeInterval, Bool, Bool)]) throws -> [ChatConversation] {
        let db = try TestDatabase.create()
        return try db.write { d in
            for (title, age, pinned, hasMessages) in rows {
                let id = try TestDatabase.insertChatConversation(
                    d, title: title, updatedAt: now.addingTimeInterval(-age).timeIntervalSince1970, pinned: pinned)
                if hasMessages {
                    let msg = try TestDatabase.insertChatMessage(d, conversationID: id, role: "user", text: title)
                    try d.execute(sql: "UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?",
                                  arguments: [msg, id])
                }
            }
            return try ChatConversationQueries.fetchAll(d)
        }
    }

    func testRecentsPutPinnedFirstAndSkipEmptyChats() throws {
        let convs = try conversations([
            ("old", 5000, false, true), ("new", 10, false, true), ("untouched", 1, false, false),
            ("pinned", 90_000, true, true)
        ])
        XCTAssertEqual(ChatLandingPolicy.recents(convs).map(\.title), ["pinned", "new", "old"])
    }

    func testRecentsAreCapped() throws {
        let rows = (0..<9).map { ("p\($0)", TimeInterval($0), true, true) }
            + (0..<9).map { ("r\($0)", TimeInterval($0), false, true) }
        let titles = ChatLandingPolicy.recents(try conversations(rows)).map(\.title)
        XCTAssertEqual(titles, ["p0", "p1", "p2", "p3", "p4", "r0", "r1", "r2", "r3", "r4", "r5"])
    }

    func testRecentsOfNothingIsEmpty() {
        XCTAssertTrue(ChatLandingPolicy.recents([]).isEmpty)
    }
}
