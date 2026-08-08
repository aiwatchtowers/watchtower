import XCTest
import GRDB
@testable import WatchtowerDesktop

// MARK: - IdeaQueries Tests

final class IdeaQueriesTests: XCTestCase {

    // MARK: - fetchList

    func testFetchListFiltersByKind() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, kind: "idea", title: "An idea")
            try TestDatabase.insertIdea(db, kind: "decision", title: "A decision")
            try TestDatabase.insertIdea(db, kind: "note", title: "A note")
        }

        let ideas = try db.read { try IdeaQueries.fetchList($0, kind: "decision", status: nil, query: nil, limit: 10) }

        XCTAssertEqual(ideas.map(\.title), ["A decision"])
    }

    func testFetchListFiltersByStatus() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, title: "Proposed", status: "proposed")
            try TestDatabase.insertIdea(db, title: "Active", status: "active")
            try TestDatabase.insertIdea(db, title: "Dropped", status: "dropped")
        }

        let ideas = try db.read { try IdeaQueries.fetchList($0, kind: nil, status: "active", query: nil, limit: 10) }

        XCTAssertEqual(ideas.map(\.title), ["Active"])
    }

    func testFetchListQueryMatchesTitleOrEssence() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, title: "Ship weekly digest", essence: "")
            try TestDatabase.insertIdea(db, title: "Unrelated", essence: "mentions digest work too")
            try TestDatabase.insertIdea(db, title: "Nothing relevant", essence: "")
        }

        let ideas = try db.read { try IdeaQueries.fetchList($0, kind: nil, status: nil, query: "digest", limit: 10) }

        XCTAssertEqual(Set(ideas.map(\.title)), ["Ship weekly digest", "Unrelated"])
    }

    func testFetchListQueryMatchesMentionQuote() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            let ideaID = try TestDatabase.insertIdea(db, title: "Renaming the dashboard")
            try TestDatabase.insertIdeaMention(db, ideaID: ideaID, quote: "we should rename the sidebar tab")
            try TestDatabase.insertIdea(db, title: "Completely unrelated idea")
        }

        let ideas = try db.read { try IdeaQueries.fetchList($0, kind: nil, status: nil, query: "sidebar", limit: 10) }

        XCTAssertEqual(ideas.map(\.title), ["Renaming the dashboard"])
    }

    func testFetchListOrderedByUpdatedAtDescending() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, title: "Older", updatedAt: "2026-04-27T00:00:00Z")
            try TestDatabase.insertIdea(db, title: "Newer", updatedAt: "2026-04-29T00:00:00Z")
        }

        let ideas = try db.read { try IdeaQueries.fetchList($0, kind: nil, status: nil, query: nil, limit: 10) }

        XCTAssertEqual(ideas.map(\.title), ["Newer", "Older"])
    }

    func testFetchListRespectsLimit() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, title: "A")
            try TestDatabase.insertIdea(db, title: "B")
            try TestDatabase.insertIdea(db, title: "C")
        }

        let ideas = try db.read { try IdeaQueries.fetchList($0, kind: nil, status: nil, query: nil, limit: 2) }

        XCTAssertEqual(ideas.count, 2)
    }

    // MARK: - fetchForReview / countForReview

    func testFetchForReviewIncludesProposedAndNeedsReview() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, title: "Proposed", status: "proposed")
            try TestDatabase.insertIdea(db, title: "Active but flagged", status: "active", needsReview: true)
            try TestDatabase.insertIdea(db, title: "Active, settled", status: "active")
            try TestDatabase.insertIdea(db, title: "Dropped", status: "dropped")
        }

        let ideas = try db.read { try IdeaQueries.fetchForReview($0) }

        XCTAssertEqual(Set(ideas.map(\.title)), ["Proposed", "Active but flagged"])
    }

    func testCountForReviewMatchesFetchForReview() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, status: "proposed")
            try TestDatabase.insertIdea(db, status: "active", needsReview: true)
            try TestDatabase.insertIdea(db, status: "active")
        }

        let count = try db.read { try IdeaQueries.countForReview($0) }

        XCTAssertEqual(count, 2)
    }

    // MARK: - fetchOne / fetchMentions

    func testFetchOneReturnsNilWhenMissing() throws {
        let db = try TestDatabase.create()
        let idea = try db.read { try IdeaQueries.fetchOne($0, id: 999) }
        XCTAssertNil(idea)
    }

    /// Ordered by when things were SAID, not when the rows were written — the
    /// consolidator writes a whole batch in one transaction, so `created_at`
    /// is identical across it and carries no chronology at all. Matches the Go
    /// reader `db.ListIdeaMentions` (`ORDER BY said_at, id`); the two are a
    /// dual path and must agree.
    func testFetchMentionsOrderedBySaidAtAscending() throws {
        let db = try TestDatabase.create()
        let ideaID = try db.write { db -> Int64 in
            let ideaID = try TestDatabase.insertIdea(db)
            // Written first but said last, with one shared created_at, exactly
            // as a single consolidator transaction would leave them.
            let sameWrite = "2026-04-28T00:00:00Z"
            try TestDatabase.insertIdeaMention(
                db, ideaID: ideaID, quote: "second", saidAt: "2026-04-27T00:00:02Z", createdAt: sameWrite)
            try TestDatabase.insertIdeaMention(
                db, ideaID: ideaID, quote: "first", saidAt: "2026-04-27T00:00:01Z", createdAt: sameWrite)
            return ideaID
        }

        let mentions = try db.read { try IdeaQueries.fetchMentions($0, ideaID: Int(ideaID)) }

        XCTAssertEqual(mentions.map(\.quote), ["first", "second"])
    }

    /// The registry list must not pay for the review queue: filtering review
    /// items out in Swift after a LIMITed fetch silently shortens the page.
    func testFetchListExcludingReviewQueueDoesNotSpendTheLimitOnReviewItems() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, title: "R1", status: "proposed")
            try TestDatabase.insertIdea(db, title: "R2", status: "active", needsReview: true)
            try TestDatabase.insertIdea(db, title: "Reg1", status: "active")
            try TestDatabase.insertIdea(db, title: "Reg2", status: "dropped")
        }

        let ideas = try db.read {
            try IdeaQueries.fetchList($0, kind: nil, status: nil, query: nil, limit: 2, excludingReviewQueue: true)
        }

        XCTAssertEqual(Set(ideas.map(\.title)), ["Reg1", "Reg2"])
    }

    // MARK: - setStatus

    func testIdeas04_SetStatusClearsNeedsReview() throws {
        let db = try TestDatabase.create()
        let ideaID = try db.write { db in
            try TestDatabase.insertIdea(db, status: "proposed", needsReview: true, reviewReason: "ambiguous merge")
        }

        try db.write { try IdeaQueries.setStatus($0, id: Int(ideaID), status: "active") }

        let idea = try db.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) }
        XCTAssertEqual(idea?.status, .active)
        XCTAssertEqual(idea?.needsReview, false)
        XCTAssertEqual(idea?.reviewReason, "")
    }

    // MARK: - snooze

    func testSnoozeSetsStatusNotNowAndSnoozeUntil() throws {
        let db = try TestDatabase.create()
        let ideaID = try db.write { db in try TestDatabase.insertIdea(db, status: "proposed") }

        try db.write { try IdeaQueries.snooze($0, id: Int(ideaID), until: "2026-05-01T00:00:00Z") }

        let idea = try db.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) }
        XCTAssertEqual(idea?.status, .notNow)
        XCTAssertEqual(idea?.snoozeUntil, "2026-05-01T00:00:00Z")
    }

    // MARK: - merge

    func testIdeas03_MergeReparentsMentionsAndFollowsLink() throws {
        let db = try TestDatabase.create()
        let (sourceID, targetID) = try db.write { db -> (Int64, Int64) in
            let sourceID = try TestDatabase.insertIdea(db, title: "Duplicate idea")
            let targetID = try TestDatabase.insertIdea(db, title: "Canonical idea")
            try TestDatabase.insertIdeaMention(db, ideaID: sourceID, quote: "one")
            try TestDatabase.insertIdeaMention(db, ideaID: sourceID, quote: "two")
            return (sourceID, targetID)
        }

        try db.write { try IdeaQueries.merge($0, id: Int(sourceID), into: Int(targetID)) }

        let source = try db.read { try IdeaQueries.fetchOne($0, id: Int(sourceID)) }
        XCTAssertEqual(source?.status, .merged)
        XCTAssertEqual(source?.mergedIntoID, Int(targetID))

        let sourceMentions = try db.read { try IdeaQueries.fetchMentions($0, ideaID: Int(sourceID)) }
        XCTAssertTrue(sourceMentions.isEmpty)

        let targetMentions = try db.read { try IdeaQueries.fetchMentions($0, ideaID: Int(targetID)) }
        XCTAssertEqual(Set(targetMentions.map(\.quote)), ["one", "two"])
    }

    // MARK: - supersede

    func testSupersedeSetsStatusAndLink() throws {
        let db = try TestDatabase.create()
        let (oldID, newID) = try db.write { db -> (Int64, Int64) in
            let oldID = try TestDatabase.insertIdea(db, title: "Old decision")
            let newID = try TestDatabase.insertIdea(db, title: "New decision")
            return (oldID, newID)
        }

        try db.write { try IdeaQueries.supersede($0, id: Int(oldID), by: Int(newID)) }

        let old = try db.read { try IdeaQueries.fetchOne($0, id: Int(oldID)) }
        XCTAssertEqual(old?.status, .superseded)
        XCTAssertEqual(old?.supersededByID, Int(newID))
    }

    // MARK: - setRating

    func testSetRatingStoresRatingAndComment() throws {
        let db = try TestDatabase.create()
        let ideaID = try db.write { db in try TestDatabase.insertIdea(db) }

        try db.write { try IdeaQueries.setRating($0, id: Int(ideaID), rating: 1, comment: "great idea") }

        let idea = try db.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) }
        XCTAssertEqual(idea?.ownerRating, 1)
        XCTAssertEqual(idea?.ratingComment, "great idea")
    }

    // MARK: - createManual

    func testCreateManualCreatesActiveOwnerIdeaWithOwnerMention() throws {
        let db = try TestDatabase.create()

        let ideaID = try db.write {
            try IdeaQueries.createManual($0, kind: "decision", title: "Use SQLite for the vault index", essence: "It's simple and rebuildable.")
        }

        let idea = try db.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) }
        XCTAssertEqual(idea?.kind, .decision)
        XCTAssertEqual(idea?.title, "Use SQLite for the vault index")
        XCTAssertEqual(idea?.status, .active)
        XCTAssertEqual(idea?.source, "owner")

        let mentions = try db.read { try IdeaQueries.fetchMentions($0, ideaID: Int(ideaID)) }
        XCTAssertEqual(mentions.count, 1)
        XCTAssertEqual(mentions.first?.source, "owner")
        XCTAssertEqual(mentions.first?.quote, "It's simple and rebuildable.")
    }

    // MARK: - markConverted

    func testIdeas03_MarkConvertedSetsStatusAndTargetLink() throws {
        let db = try TestDatabase.create()
        let ideaID = try db.write { db in try TestDatabase.insertIdea(db, status: "active") }

        try db.write { try IdeaQueries.markConverted($0, id: Int(ideaID), targetID: 42) }

        let idea = try db.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) }
        XCTAssertEqual(idea?.status, .converted)
        XCTAssertEqual(idea?.convertedTargetID, 42)
    }

    /// IDEA-03's "links, not deletes" for convert, asserted on the things that
    /// would actually be lost: the mention chronology and the Discuss chat.
    func testIdeas03_MarkConvertedKeepsMentionsAndChat() throws {
        let db = try TestDatabase.create()
        let ideaID = try db.write { db -> Int64 in
            let ideaID = try TestDatabase.insertIdea(db, status: "active")
            try TestDatabase.insertIdeaMention(db, ideaID: ideaID, quote: "first sighting", saidAt: "2026-04-27T00:00:01Z")
            try TestDatabase.insertIdeaMention(db, ideaID: ideaID, quote: "second sighting", saidAt: "2026-04-27T00:00:02Z")
            // The chat tables are created lazily at runtime, not by the test
            // schema (the ChatHistoryViewModelTests precedent).
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
            try db.execute(sql: """
                INSERT INTO chat_conversations (context_type, context_id, title, created_at, updated_at)
                VALUES ('idea', ?, 'Discuss', 0, 0)
                """, arguments: [ideaID])
            let conversationID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO chat_messages (conversation_id, role, text, created_at)
                VALUES (?, 'user', 'what do we do with this?', 0)
                """, arguments: [conversationID])
            return ideaID
        }

        try db.write { try IdeaQueries.markConverted($0, id: Int(ideaID), targetID: 42) }

        let idea = try db.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) }
        XCTAssertEqual(idea?.status, .converted, "the row survives conversion")

        let mentions = try db.read { try IdeaQueries.fetchMentions($0, ideaID: Int(ideaID)) }
        XCTAssertEqual(mentions.map(\.quote), ["first sighting", "second sighting"],
                       "conversion is a link — the mentions stay on the converted idea")

        let (conversations, messages) = try db.read { db -> (Int, Int) in
            let c = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM chat_conversations WHERE context_type = 'idea' AND context_id = ?
                """, arguments: [ideaID]) ?? 0
            let m = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM chat_messages WHERE conversation_id IN (
                    SELECT id FROM chat_conversations WHERE context_type = 'idea' AND context_id = ?
                )
                """, arguments: [ideaID]) ?? 0
            return (c, m)
        }
        XCTAssertEqual(conversations, 1, "the Discuss chat survives conversion")
        XCTAssertEqual(messages, 1, "and so do its messages")
    }

    // MARK: - IDEA-04 clearability

    /// Every owner action has to clear `needs_review`, not just `setStatus`.
    /// A resurfaced idea the owner acts on via snooze/merge/supersede/convert
    /// would otherwise stay in the "For review" list forever.
    func testIdeas04_EveryOwnerActionClearsNeedsReview() throws {
        let db = try TestDatabase.create()

        func flaggedIdea() throws -> Int {
            let id = try db.write { db in
                try TestDatabase.insertIdea(db, status: "rejected", needsReview: true, reviewReason: "brought up again")
            }
            return Int(id)
        }

        let snoozed = try flaggedIdea()
        try db.write { try IdeaQueries.snooze($0, id: snoozed, until: nil) }

        let merged = try flaggedIdea()
        let mergeTarget = try flaggedIdea()
        try db.write { try IdeaQueries.merge($0, id: merged, into: mergeTarget) }

        let superseded = try flaggedIdea()
        try db.write { try IdeaQueries.supersede($0, id: superseded, by: nil) }

        let converted = try flaggedIdea()
        try db.write { try IdeaQueries.markConverted($0, id: converted, targetID: 7) }

        for (label, id) in [("snooze", snoozed), ("merge", merged),
                            ("supersede", superseded), ("markConverted", converted)] {
            let idea = try db.read { try IdeaQueries.fetchOne($0, id: id) }
            XCTAssertEqual(idea?.needsReview, false, "\(label) must clear needs_review")
            XCTAssertEqual(idea?.reviewReason, "", "\(label) must clear review_reason")
        }
    }

    /// A hand-written idea must not sort to the bottom of every
    /// `last_mention_at` list with an empty timestamp — the Go writer stamps it
    /// (`InsertIdeaMentionTx`), so this dual path does too.
    func testCreateManualStampsLastMentionAt() throws {
        let db = try TestDatabase.create()

        let ideaID = try db.write {
            try IdeaQueries.createManual($0, kind: "idea", title: "Hand-written", essence: "typed by the owner")
        }

        let idea = try db.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) }
        XCTAssertFalse(idea?.lastMentionAt.isEmpty ?? true, "last_mention_at must be stamped")

        let mentions = try db.read { try IdeaQueries.fetchMentions($0, ideaID: Int(ideaID)) }
        XCTAssertEqual(mentions.first?.saidAt, idea?.lastMentionAt,
                       "the owner mention's said_at is what last_mention_at reflects")
    }

    // MARK: - Slack deeplink

    /// `channels.id`/`messages.channel_id` carry the Slack multi-account
    /// namespace ("<accountID>:") since migration 00048, but slack.com/archives
    /// wants the bare id — a namespaced one 404s.
    func testMentionURLStripsSlackAccountNamespace() throws {
        let url = slackMentionURL(ref: "3:C08ABCDEF|1723456789.001200")

        XCTAssertEqual(url, "https://slack.com/archives/C08ABCDEF/p1723456789001200")
    }

    /// A pre-migration bare channel id still has to work, and a ref whose
    /// prefix is not an account number must not be truncated.
    func testMentionURLLeavesNonNamespacedChannelIDsAlone() throws {
        XCTAssertEqual(slackMentionURL(ref: "C08ABCDEF|1723456789.001200"),
                       "https://slack.com/archives/C08ABCDEF/p1723456789001200")
        XCTAssertEqual(slackMentionURL(ref: "weird:C08ABCDEF|1723456789.001200"),
                       "https://slack.com/archives/weird:C08ABCDEF/p1723456789001200")
    }

    /// Builds a slack mention through a GRDB `Row` — `IdeaMention` is a
    /// database record with only `init(row:)`.
    private func slackMentionURL(ref: String) -> String? {
        let mention = IdeaMention(row: [
            "id": 1, "idea_id": 1, "source": "slack", "ref": ref,
            "quote": "", "author": "", "said_at": "", "created_at": ""
        ])
        return IdeaDetailPane.mentionURL(mention, jiraSiteURL: nil)?.absoluteString
    }
}
