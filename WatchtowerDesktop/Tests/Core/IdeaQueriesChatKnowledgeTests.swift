import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Chat knowledge on the registry: owner-prefixed items (`chatIdea`; Go
/// writes and undoes them) and chat-born items, which
/// wait for a verdict whatever their kind and stay out of the decisions
/// ledger until approved.
final class IdeaQueriesChatKnowledgeTests: XCTestCase {
    private func makeChat(_ db: Database) throws -> (conversation: Int64, message: Int64) {
        try db.execute(sql: "INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 0, 0)")
        let conversation = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO chat_messages (conversation_id, role, text, turn_id, created_at) VALUES (?, 'user', '', '', 0)",
            arguments: [conversation])
        return (conversation, db.lastInsertedRowID)
    }

    func testChatBornProposedDecisionAwaitsVerdictAndCounts() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db in
            try TestDatabase.insertIdea(db, kind: "decision", title: "From chat", status: "proposed", chatBorn: true)
        }
        let idea = try XCTUnwrap(try queue.read { try IdeaQueries.fetchOne($0, id: Int(id)) })
        XCTAssertTrue(idea.chatBorn)
        XCTAssertTrue(idea.awaitsVerdict)
        XCTAssertEqual(try queue.read { try IdeaQueries.fetchForReview($0, kind: "decision") }.map(\.id), [Int(id)])
        XCTAssertEqual(try queue.read { try IdeaQueries.countForReview($0) }, 1)
        XCTAssertEqual(try queue.read { try IdeaQueries.reviewCountsByKind($0) }["decision"], 1)
    }

    func testMinedNeedsReviewDecisionStillInformational() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db in
            try TestDatabase.insertIdea(db, kind: "decision", status: "active", needsReview: true)
        }
        let idea = try XCTUnwrap(try queue.read { try IdeaQueries.fetchOne($0, id: Int(id)) })
        XCTAssertFalse(idea.chatBorn)
        XCTAssertFalse(idea.awaitsVerdict)
        XCTAssertEqual(try queue.read { try IdeaQueries.fetchForReview($0, kind: "decision") }, [])
        XCTAssertEqual(try queue.read { try IdeaQueries.countForReview($0) }, 0)
        XCTAssertNil(try queue.read { try IdeaQueries.reviewCountsByKind($0) }["decision"])
    }

    func testDecisionLedgerSkipsUnapprovedChatBorn() throws {
        let queue = try TestDatabase.create()
        let (superseded, mined, proposed) = try queue.write { db -> (Int64, Int64, Int64) in
            // Approved once, later superseded: still knowledge (spec §4).
            let superseded = try TestDatabase.insertIdea(
                db, kind: "decision", title: "Chat superseded", status: "superseded",
                seenAt: "2026-10-24T08:00:00Z", chatBorn: true)
            let mined = try TestDatabase.insertIdea(db, kind: "decision", title: "Mined", status: "active")
            let proposed = try TestDatabase.insertIdea(
                db, kind: "decision", title: "Chat proposed", status: "proposed", chatBorn: true)
            try TestDatabase.insertIdea(db, kind: "decision", title: "Chat rejected", status: "rejected", chatBorn: true)
            try TestDatabase.insertIdea(db, kind: "decision", title: "Chat not now", status: "not_now", chatBorn: true)
            try TestDatabase.insertIdea(db, kind: "decision", title: "Chat dropped", status: "dropped", chatBorn: true)
            return (superseded, mined, proposed)
        }
        XCTAssertEqual(Set(try queue.read { try IdeaQueries.fetchDecisionLedger($0) }.map(\.id)),
                       [Int(superseded), Int(mined)])
        XCTAssertEqual(try queue.read { try IdeaQueries.unreadDecisionCount($0) }, 1)
        XCTAssertEqual(Set(try queue.read { try IdeaQueries.fetchNewDecisionsSince($0, afterID: 0) }.map(\.id)),
                       [Int(superseded), Int(mined)])
        XCTAssertEqual(try queue.read { try IdeaQueries.maxDecisionID($0) }, Int(mined))

        // Approval (Go's `ideas.status`) makes it a ledger decision, unread until seen.
        try queue.write { db in
            try db.execute(sql: "UPDATE ideas SET seen_at = '2026-10-24T09:00:00Z' WHERE id IN (?, ?)",
                           arguments: [superseded, mined])
            try db.execute(sql: "UPDATE ideas SET status = 'active' WHERE id = ?", arguments: [proposed])
        }
        XCTAssertEqual(Set(try queue.read { try IdeaQueries.fetchDecisionLedger($0) }.map(\.id)),
                       [Int(superseded), Int(mined), Int(proposed)])
        XCTAssertEqual(try queue.read { try IdeaQueries.unreadDecisionCount($0) }, 1)
    }

    /// The "Chat deleted" check of a chat mention on the card.
    func testExistingConversationIDs() throws {
        let queue = try TestDatabase.create()
        let (kept, gone) = try queue.write { db -> (Int64, Int64) in
            let kept = try TestDatabase.insertChatConversation(db)
            let gone = try TestDatabase.insertChatConversation(db)
            try ChatConversationQueries.delete(db, id: gone)
            return (kept, gone)
        }
        XCTAssertEqual(try queue.read { try ChatConversationQueries.existingIDs($0, ids: [kept, gone, kept]) }, [kept])
        XCTAssertEqual(try queue.read { try ChatConversationQueries.existingIDs($0, ids: []) }, [])
    }
}
