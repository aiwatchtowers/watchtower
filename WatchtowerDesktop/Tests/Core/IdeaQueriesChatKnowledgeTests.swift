import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Chat knowledge on the registry: owner-prefixed items written at once
/// (`createFromChat`/`chatIdea`/`undoChatIdea`) and chat-born items, which
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

    func testCreateFromChatWritesChatBornActiveWithChatMention() throws {
        let queue = try TestDatabase.create()
        let body = String(repeating: "я", count: 130) + "\nsecond line"
        let (ideaID, chat) = try queue.write { db -> (Int64, (conversation: Int64, message: Int64)) in
            let chat = try makeChat(db)
            let id = try IdeaQueries.createFromChat(
                db, kind: "decision", body: body, conversationID: chat.conversation, messageID: chat.message)
            return (id, chat)
        }
        let idea = try XCTUnwrap(try queue.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) })
        XCTAssertEqual(idea.kind, .decision)
        XCTAssertEqual(idea.status, .active)
        XCTAssertEqual(idea.source, "owner")
        XCTAssertTrue(idea.chatBorn)
        XCTAssertEqual(idea.essence, body)
        XCTAssertEqual(idea.title, String(repeating: "я", count: 120))
        XCTAssertFalse(idea.lastMentionAt.isEmpty)
        XCTAssertFalse(idea.awaitsVerdict)

        let mentions = try queue.read { try IdeaQueries.fetchMentions($0, ideaID: Int(ideaID)) }
        XCTAssertEqual(mentions.count, 1)
        XCTAssertEqual(mentions.first?.source, "chat")
        XCTAssertEqual(mentions.first?.ref, "chat:\(chat.conversation):\(chat.message)")
        XCTAssertEqual(mentions.first?.quote, body)
        XCTAssertEqual(mentions.first?.saidAt, idea.lastMentionAt)

        let rebuilt = try queue.read {
            try IdeaQueries.chatIdea($0, conversationID: chat.conversation, messageID: chat.message)
        }
        XCTAssertEqual(rebuilt?.id, Int(ideaID))
        XCTAssertNil(try queue.read {
            try IdeaQueries.chatIdea($0, conversationID: chat.conversation, messageID: chat.message + 1)
        })
        // An approved (active) chat-born decision is in the ledger.
        XCTAssertEqual(try queue.read { try IdeaQueries.fetchDecisionLedger($0) }.map(\.id), [Int(ideaID)])
    }

    func testUndoChatIdeaDeletesAnUntouchedItem() throws {
        let queue = try TestDatabase.create()
        let removed = try queue.write { db -> Bool in
            let chat = try makeChat(db)
            let id = try IdeaQueries.createFromChat(
                db, kind: "note", body: "fact", conversationID: chat.conversation, messageID: chat.message)
            let stamp = try XCTUnwrap(try IdeaQueries.fetchOne(db, id: Int(id))).updatedAt
            return try IdeaQueries.undoChatIdea(db, id: id, createdUpdatedAt: stamp)
        }
        XCTAssertTrue(removed)
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ideas") }, 0)
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM idea_mentions") }, 0)
    }

    func testUndoChatIdeaRefusesEditedOrApprovedOrMerged() throws {
        let queue = try TestDatabase.create()
        let stamp = "2026-10-24T10:00:00Z"
        try queue.write { db in
            let chat = try makeChat(db)
            func create() throws -> Int64 {
                let id = try IdeaQueries.createFromChat(
                    db, kind: "note", body: "fact", conversationID: chat.conversation, messageID: chat.message)
                try db.execute(sql: "UPDATE ideas SET updated_at = ? WHERE id = ?", arguments: [stamp, id])
                return id
            }
            // Edited since creation: updated_at moved on.
            let edited = try create()
            try db.execute(sql: "UPDATE ideas SET title = 'x', updated_at = '2026-10-24T11:00:00Z' WHERE id = ?",
                           arguments: [edited])
            XCTAssertFalse(try IdeaQueries.undoChatIdea(db, id: edited, createdUpdatedAt: stamp))
            // No longer active (the owner gave a verdict), even with the same stamp.
            let acted = try create()
            try db.execute(sql: "UPDATE ideas SET status = 'dropped' WHERE id = ?", arguments: [acted])
            XCTAssertFalse(try IdeaQueries.undoChatIdea(db, id: acted, createdUpdatedAt: stamp))
            // Merged into another item.
            let merged = try create()
            let other = try TestDatabase.insertIdea(db, kind: "note", status: "active")
            try db.execute(sql: "UPDATE ideas SET merged_into_id = ? WHERE id = ?", arguments: [other, merged])
            XCTAssertFalse(try IdeaQueries.undoChatIdea(db, id: merged, createdUpdatedAt: stamp))
            // Another item merged into it.
            let survivor = try create()
            try TestDatabase.insertIdea(db, kind: "note", status: "merged", mergedIntoID: Int(survivor))
            XCTAssertFalse(try IdeaQueries.undoChatIdea(db, id: survivor, createdUpdatedAt: stamp))
            // Gone already.
            XCTAssertFalse(try IdeaQueries.undoChatIdea(db, id: 9999, createdUpdatedAt: stamp))
        }
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ideas WHERE chat_born = 1") }, 4)
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

        try queue.write { try IdeaQueries.markAllDecisionsSeen($0) }
        let seen = try queue.read {
            try Int.fetchAll($0, sql: "SELECT id FROM ideas WHERE seen_at IS NOT NULL ORDER BY id")
        }
        XCTAssertEqual(seen, [Int(superseded), Int(mined)], "a hidden chat-born row stays unseen for when it is approved")

        // Approval makes it a ledger decision, unread until seen.
        try queue.write { try IdeaQueries.setStatus($0, id: Int(proposed), status: "active") }
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
