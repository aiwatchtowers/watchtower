import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

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

    /// The Ideas tab never shows decisions — with no explicit `kind`, the
    /// ledger's rows are excluded; only an explicit `kind: "decision"` sees them.
    func testFetchListWithNoKindExcludesDecisions() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, kind: "idea", title: "An idea")
            try TestDatabase.insertIdea(db, kind: "decision", title: "A decision")
            try TestDatabase.insertIdea(db, kind: "note", title: "A note")
        }

        let ideas = try db.read { try IdeaQueries.fetchList($0, kind: nil, status: nil, query: nil, limit: 10) }

        XCTAssertEqual(Set(ideas.map(\.title)), ["An idea", "A note"])
    }

    func testFetchListWithExplicitDecisionKindReturnsDecisions() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, kind: "idea", title: "An idea")
            try TestDatabase.insertIdea(db, kind: "decision", title: "A decision")
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

    /// Decisions are born 'active' and never enter the review queue — mirrors
    /// the Go side's `CountIdeasForReview`, which this is the dual path of.
    func testFetchForReviewExcludesDecisionsEvenWhenFlagged() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, kind: "idea", title: "Proposed idea", status: "proposed")
            try TestDatabase.insertIdea(db, kind: "decision", title: "Flagged decision",
                                        status: "active", needsReview: true)
        }

        let ideas = try db.read { try IdeaQueries.fetchForReview($0) }

        XCTAssertEqual(ideas.map(\.title), ["Proposed idea"])
    }

    func testCountForReviewExcludesDecisionsEvenWhenFlagged() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, kind: "idea", status: "proposed")
            try TestDatabase.insertIdea(db, kind: "decision", status: "active", needsReview: true)
        }

        let count = try db.read { try IdeaQueries.countForReview($0) }

        XCTAssertEqual(count, 1)
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
            // schema (the ChatHistoryViewModelTests precedent). ChatMessageQueries
            // itself stays app-side, so its `ensureTable` DDL is inlined here to
            // let this file live in WatchtowerCoreTests.
            try ChatConversationQueries.ensureTable(db)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS chat_messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
                    role TEXT NOT NULL,
                    text TEXT NOT NULL,
                    created_at REAL NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_chat_messages_conversation ON chat_messages(conversation_id)
            """)
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

    // MARK: - fetchDecisionLedger

    func testFetchDecisionLedgerOnlyReturnsDecisions() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, kind: "idea", title: "An idea")
            try TestDatabase.insertIdea(db, kind: "decision", title: "A decision")
            try TestDatabase.insertIdea(db, kind: "note", title: "A note")
        }

        let ledger = try db.read { try IdeaQueries.fetchDecisionLedger($0) }

        XCTAssertEqual(ledger.map(\.title), ["A decision"])
    }

    /// Ordered by `last_mention_at`, falling back to `updated_at` when a
    /// decision has no mention timestamp (e.g. hand-written via `createManual`
    /// before any mention lands).
    func testFetchDecisionLedgerOrdersByLastMentionAtFallingBackToUpdatedAt() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(
                db, kind: "decision", title: "Old mention",
                lastMentionAt: "2026-04-27T00:00:00Z", updatedAt: "2026-04-29T00:00:00Z")
            try TestDatabase.insertIdea(
                db, kind: "decision", title: "Recent mention",
                lastMentionAt: "2026-04-28T00:00:00Z", updatedAt: "2026-04-27T00:00:00Z")
            try TestDatabase.insertIdea(
                db, kind: "decision", title: "No mention, recently updated",
                lastMentionAt: "", updatedAt: "2026-04-30T00:00:00Z")
        }

        let ledger = try db.read { try IdeaQueries.fetchDecisionLedger($0) }

        XCTAssertEqual(ledger.map(\.title),
                       ["No mention, recently updated", "Recent mention", "Old mention"])
    }

    func testFetchDecisionLedgerRespectsLimit() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, kind: "decision", title: "A")
            try TestDatabase.insertIdea(db, kind: "decision", title: "B")
            try TestDatabase.insertIdea(db, kind: "decision", title: "C")
        }

        let ledger = try db.read { try IdeaQueries.fetchDecisionLedger($0, limit: 2) }

        XCTAssertEqual(ledger.count, 2)
    }

    // MARK: - markDecisionSeen / markAllDecisionsSeen / unreadDecisionCount

    func testMarkDecisionSeenStampsSeenAt() throws {
        let db = try TestDatabase.create()
        let ideaID = try db.write { db in try TestDatabase.insertIdea(db, kind: "decision") }

        try db.write { try IdeaQueries.markDecisionSeen($0, id: Int(ideaID)) }

        let idea = try db.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) }
        XCTAssertNotNil(idea?.seenAt)
        XCTAssertFalse(idea?.seenAt?.isEmpty ?? true)
    }

    /// A decision otherwise seen but re-flagged (`needs_review = 1`, e.g. a
    /// later mention resurfaced it) still counts as unread — seeing it once
    /// doesn't excuse the owner from a fresh flag.
    func testUnreadDecisionCountCountsUnseenAndReflagged() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, kind: "decision", title: "Never seen")
            try TestDatabase.insertIdea(db, kind: "decision", title: "Seen, settled",
                                        seenAt: "2026-04-27T00:00:00Z")
            try TestDatabase.insertIdea(db, kind: "decision", title: "Seen, but reflagged",
                                        needsReview: true, seenAt: "2026-04-27T00:00:00Z")
            try TestDatabase.insertIdea(db, kind: "idea", title: "Not a decision at all")
        }

        let count = try db.read { try IdeaQueries.unreadDecisionCount($0) }

        XCTAssertEqual(count, 2)
    }

    func testMarkDecisionSeenClearsUnreadCountForThatDecision() throws {
        let db = try TestDatabase.create()
        let ideaID = try db.write { db in try TestDatabase.insertIdea(db, kind: "decision") }

        try db.write { try IdeaQueries.markDecisionSeen($0, id: Int(ideaID)) }

        let count = try db.read { try IdeaQueries.unreadDecisionCount($0) }
        XCTAssertEqual(count, 0)
    }

    func testMarkAllDecisionsSeenOnlyTouchesUnseenDecisions() throws {
        let db = try TestDatabase.create()
        let (untouched, ideaAmongDecisions) = try db.write { db -> (Int64, Int64) in
            try TestDatabase.insertIdea(db, kind: "decision", title: "Unseen one")
            try TestDatabase.insertIdea(db, kind: "decision", title: "Unseen two")
            let untouched = try TestDatabase.insertIdea(
                db, kind: "decision", title: "Already seen", seenAt: "2026-04-27T00:00:00Z")
            let ideaAmongDecisions = try TestDatabase.insertIdea(db, kind: "idea", title: "An idea, not a decision")
            return (untouched, ideaAmongDecisions)
        }

        try db.write { try IdeaQueries.markAllDecisionsSeen($0) }

        let count = try db.read { try IdeaQueries.unreadDecisionCount($0) }
        XCTAssertEqual(count, 0)

        let previouslySeen = try db.read { try IdeaQueries.fetchOne($0, id: Int(untouched)) }
        XCTAssertEqual(previouslySeen?.seenAt, "2026-04-27T00:00:00Z",
                       "an already-seen decision's seen_at must not be overwritten")

        let idea = try db.read { try IdeaQueries.fetchOne($0, id: Int(ideaAmongDecisions)) }
        XCTAssertNil(idea?.seenAt, "a non-decision idea must be left untouched")
    }

    // MARK: - mentionSourcesByIdea

    func testMentionSourcesByIdeaReturnsDistinctSourcesPerIdea() throws {
        let db = try TestDatabase.create()
        let ids = try db.write { db -> (a: Int64, b: Int64) in
            let a = try TestDatabase.insertIdea(db, kind: "decision", title: "A")
            let b = try TestDatabase.insertIdea(db, kind: "decision", title: "B")
            try TestDatabase.insertIdeaMention(db, ideaID: a, source: "slack")
            // A second Slack mention must not duplicate "slack" in the result.
            try TestDatabase.insertIdeaMention(db, ideaID: a, source: "slack")
            try TestDatabase.insertIdeaMention(db, ideaID: a, source: "jira")
            try TestDatabase.insertIdeaMention(db, ideaID: b, source: "gmail")
            return (a, b)
        }

        let sources = try db.read { try IdeaQueries.mentionSourcesByIdea($0, ids: [Int(ids.a), Int(ids.b)]) }

        XCTAssertEqual(Set(sources[Int(ids.a)] ?? []), ["slack", "jira"])
        XCTAssertEqual(sources[Int(ids.b)], ["gmail"])
    }

    func testMentionSourcesByIdeaOmitsIdeasWithNoMentions() throws {
        let db = try TestDatabase.create()
        let ideaID = try db.write { db in try TestDatabase.insertIdea(db, kind: "decision") }

        let sources = try db.read { try IdeaQueries.mentionSourcesByIdea($0, ids: [Int(ideaID)]) }

        XCTAssertNil(sources[Int(ideaID)])
    }

    func testMentionSourcesByIdeaEmptyIDsReturnsEmptyMap() throws {
        let db = try TestDatabase.create()
        let sources = try db.read { try IdeaQueries.mentionSourcesByIdea($0, ids: []) }
        XCTAssertTrue(sources.isEmpty)
    }
}

// The `IdeaDetailPane.mentionURL` deeplink tests that used to live here moved to
// WatchtowerDesktopTests/IdeaDetailPaneMentionURLTests.swift — IdeaDetailPane is
// a SwiftUI view and can't be referenced from this Core-only test target.
