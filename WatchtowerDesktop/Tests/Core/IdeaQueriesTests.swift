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

        let ideas = try db.read { try IdeaQueries.fetchForReview($0, kind: "idea") }

        XCTAssertEqual(Set(ideas.map(\.title)), ["Proposed", "Active but flagged"])
    }

    /// The review queue is scoped to the Ideas tab's active segment, so a
    /// flagged note is reviewed under Notes rather than mixed into Ideas.
    /// The sidebar badge (`countForReview`) stays global.
    func testFetchForReview_FiltersByKind() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, kind: "idea", title: "Proposed idea", status: "proposed")
            try TestDatabase.insertIdea(db, kind: "note", title: "Proposed note", status: "proposed")
        }

        let ideas = try db.read { try IdeaQueries.fetchForReview($0, kind: "idea") }
        XCTAssertEqual(ideas.map(\.title), ["Proposed idea"])

        let notes = try db.read { try IdeaQueries.fetchForReview($0, kind: "note") }
        XCTAssertEqual(notes.map(\.title), ["Proposed note"])

        let count = try db.read { try IdeaQueries.countForReview($0) }
        XCTAssertEqual(count, 2, "the sidebar badge counts both kinds regardless of the active segment")
    }

    /// An active search must narrow the review queue too — review items that
    /// don't match a search staying on screen read as a broken search. The
    /// predicate is the same title/essence/mention-quote triple as `fetchList`.
    func testFetchForReviewQueryFiltersQueue() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, title: "DevOps knowledge base", status: "proposed")
            let quoted = try TestDatabase.insertIdea(db, title: "Release notes automation", status: "proposed")
            try TestDatabase.insertIdeaMention(db, ideaID: quoted, quote: "the DevOps team asked for this")
            try TestDatabase.insertIdea(db, title: "SumSub umbrella account", status: "proposed")
        }

        let matched = try db.read { try IdeaQueries.fetchForReview($0, kind: "idea", query: "DevOps") }
        XCTAssertEqual(Set(matched.map(\.title)), ["DevOps knowledge base", "Release notes automation"])

        let all = try db.read { try IdeaQueries.fetchForReview($0, kind: "idea") }
        XCTAssertEqual(all.count, 3, "no query keeps the queue unfiltered")
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
    /// Asked for explicitly, a flagged decision still doesn't come back.
    func testFetchForReviewExcludesDecisionsEvenWhenFlagged() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, kind: "idea", title: "Proposed idea", status: "proposed")
            try TestDatabase.insertIdea(db, kind: "decision", title: "Flagged decision",
                                        status: "active", needsReview: true)
        }

        let decisions = try db.read { try IdeaQueries.fetchForReview($0, kind: "decision") }

        XCTAssertTrue(decisions.isEmpty)
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
            try Self.createChatTables(db)
            try Self.insertChat(db, ideaID: ideaID, messages: 1)
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
    /// A resurfaced idea the owner acts on via snooze/merge/supersede/convert/
    /// markDecisionSeen/markAllDecisionsSeen would otherwise stay in the
    /// "For review" list (or, for decisions, the unread ledger) forever.
    func testIdeas04_EveryOwnerActionClearsNeedsReview() throws {
        let db = try TestDatabase.create()

        func flaggedIdea() throws -> Int {
            let id = try db.write { db in
                try TestDatabase.insertIdea(db, status: "rejected", needsReview: true, reviewReason: "brought up again")
            }
            return Int(id)
        }

        func flaggedDecision() throws -> Int {
            let id = try db.write { db in
                try TestDatabase.insertIdea(
                    db, kind: "decision", status: "active", needsReview: true, reviewReason: "brought up again")
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

        let decisionSeen = try flaggedDecision()
        try db.write { try IdeaQueries.markDecisionSeen($0, id: decisionSeen) }

        let allDecisionsSeen = try flaggedDecision()
        try db.write { try IdeaQueries.markAllDecisionsSeen($0) }

        for (label, id) in [("snooze", snoozed), ("merge", merged),
                            ("supersede", superseded), ("markConverted", converted),
                            ("markDecisionSeen", decisionSeen), ("markAllDecisionsSeen", allDecisionsSeen)] {
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

    /// A decision seen once, then re-flagged by a later mention, is exactly
    /// what `unreadDecisionCount`'s `seen_at IS NULL OR needs_review = 1`
    /// predicate calls unread — `markAllDecisionsSeen` must catch it too, not
    /// just rows that were never seen at all, or a re-flagged decision has no
    /// bulk way to clear (IDEA-04).
    func testMarkAllDecisionsSeenClearsReflaggedDecision() throws {
        let db = try TestDatabase.create()
        let ideaID = try db.write { db in try TestDatabase.insertIdea(db, kind: "decision") }

        try db.write { try IdeaQueries.markDecisionSeen($0, id: Int(ideaID)) }
        try db.write {
            try $0.execute(
                sql: "UPDATE ideas SET needs_review = 1, review_reason = 'resurfaced' WHERE id = ?",
                arguments: [ideaID])
        }

        try db.write { try IdeaQueries.markAllDecisionsSeen($0) }

        let idea = try db.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) }
        XCTAssertEqual(idea?.needsReview, false, "the re-flag must be cleared")

        let count = try db.read { try IdeaQueries.unreadDecisionCount($0) }
        XCTAssertEqual(count, 0)
    }

    // MARK: - delete

    func testDelete_RemovesRowMentionsAndChat() throws {
        let db = try TestDatabase.create()
        let (doomedID, keptID) = try db.write { db -> (Int64, Int64) in
            try Self.createChatTables(db)
            let doomedID = try TestDatabase.insertIdea(db, title: "Throw this away")
            try TestDatabase.insertIdeaMention(db, ideaID: doomedID, quote: "first sighting")
            try TestDatabase.insertIdeaMention(db, ideaID: doomedID, quote: "second sighting")
            try Self.insertChat(db, ideaID: doomedID, messages: 2)
            let keptID = try TestDatabase.insertIdea(db, title: "Keep this")
            try TestDatabase.insertIdeaMention(db, ideaID: keptID, quote: "unrelated sighting")
            try Self.insertChat(db, ideaID: keptID, messages: 1)
            return (doomedID, keptID)
        }

        try db.write { try IdeaQueries.delete($0, id: Int(doomedID)) }

        XCTAssertNil(try db.read { try IdeaQueries.fetchOne($0, id: Int(doomedID)) })
        XCTAssertTrue(try db.read { try IdeaQueries.fetchMentions($0, ideaID: Int(doomedID)) }.isEmpty)
        XCTAssertEqual(try Self.chatCounts(db, ideaID: doomedID).conversations, 0)
        XCTAssertEqual(try Self.chatCounts(db, ideaID: doomedID).messages, 0)

        XCTAssertNotNil(try db.read { try IdeaQueries.fetchOne($0, id: Int(keptID)) })
        XCTAssertEqual(try db.read { try IdeaQueries.fetchMentions($0, ideaID: Int(keptID)) }.count, 1)
        XCTAssertEqual(try Self.chatCounts(db, ideaID: keptID).conversations, 1)
        XCTAssertEqual(try Self.chatCounts(db, ideaID: keptID).messages, 1)
    }

    /// `similar_to_id` and `superseded_by_id` carry no foreign key, so without
    /// an explicit null-out the survivors would keep pointing at an id that no
    /// longer exists. (`merged_into_id` needs no such pass — a row carrying it
    /// is deleted with the chain, see `testDelete_CascadesToMergedChildren`.)
    func testDelete_NullsBackReferencesOnSurvivors() throws {
        let db = try TestDatabase.create()
        let ids = try db.write { db -> (doomed: Int64, similar: Int64, superseded: Int64) in
            try Self.createChatTables(db)
            let doomed = try TestDatabase.insertIdea(db, title: "Canonical")
            let similar = try TestDatabase.insertIdea(db, title: "Similar to it", similarToID: Int(doomed))
            let superseded = try TestDatabase.insertIdea(db, title: "Superseded by it", supersededByID: Int(doomed))
            return (doomed, similar, superseded)
        }

        try db.write { try IdeaQueries.delete($0, id: Int(ids.doomed)) }

        let similar = try db.read { try IdeaQueries.fetchOne($0, id: Int(ids.similar)) }
        XCTAssertNotNil(similar)
        XCTAssertNil(similar?.similarToID)

        let superseded = try db.read { try IdeaQueries.fetchOne($0, id: Int(ids.superseded)) }
        XCTAssertNotNil(superseded)
        XCTAssertNil(superseded?.supersededByID)
    }

    /// A merged child's mentions moved onto the survivor at merge time
    /// (IDEA-03), so what's left is a husk whose only content is the
    /// `merged_into_id` redirect the Go consolidator follows. Deleting the
    /// survivor takes the husk — and its chat — with it, rather than leaving
    /// the redirect pointing at a row that no longer exists.
    func testDelete_CascadesToMergedChildren() throws {
        let db = try TestDatabase.create()
        let (survivorID, mergedID, unrelatedID) = try db.write { db -> (Int64, Int64, Int64) in
            try Self.createChatTables(db)
            let survivorID = try TestDatabase.insertIdea(db, title: "Canonical")
            try Self.insertChat(db, ideaID: survivorID, messages: 1)
            let mergedID = try TestDatabase.insertIdea(
                db, title: "Merged away", status: "merged", mergedIntoID: Int(survivorID))
            try Self.insertChat(db, ideaID: mergedID, messages: 2)
            let unrelatedID = try TestDatabase.insertIdea(db, title: "Untouched")
            try Self.insertChat(db, ideaID: unrelatedID, messages: 1)
            return (survivorID, mergedID, unrelatedID)
        }

        try db.write { try IdeaQueries.delete($0, id: Int(survivorID)) }

        XCTAssertNil(try db.read { try IdeaQueries.fetchOne($0, id: Int(mergedID)) },
                     "the merged husk goes with its survivor")
        XCTAssertEqual(try Self.chatCounts(db, ideaID: mergedID).conversations, 0)
        XCTAssertEqual(try Self.chatCounts(db, ideaID: mergedID).messages, 0)

        XCTAssertNotNil(try db.read { try IdeaQueries.fetchOne($0, id: Int(unrelatedID)) })
        XCTAssertEqual(try Self.chatCounts(db, ideaID: unrelatedID).conversations, 1)
        XCTAssertEqual(try Self.chatCounts(db, ideaID: unrelatedID).messages, 1)
    }

    /// The cascade is recursive: C merged into B merged into A dies whole.
    func testDelete_CascadesThroughAMergeChain() throws {
        let db = try TestDatabase.create()
        let ids = try db.write { db -> (a: Int64, b: Int64, c: Int64) in
            try Self.createChatTables(db)
            let a = try TestDatabase.insertIdea(db, title: "A")
            let b = try TestDatabase.insertIdea(db, title: "B", status: "merged", mergedIntoID: Int(a))
            let c = try TestDatabase.insertIdea(db, title: "C", status: "merged", mergedIntoID: Int(b))
            for id in [a, b, c] {
                try TestDatabase.insertIdeaMention(db, ideaID: id, quote: "said on \(id)")
                try Self.insertChat(db, ideaID: id, messages: 1)
            }
            return (a, b, c)
        }

        try db.write { try IdeaQueries.delete($0, id: Int(ids.a)) }

        for id in [ids.a, ids.b, ids.c] {
            XCTAssertNil(try db.read { try IdeaQueries.fetchOne($0, id: Int(id)) })
            XCTAssertTrue(try db.read { try IdeaQueries.fetchMentions($0, ideaID: Int(id)) }.isEmpty)
            XCTAssertEqual(try Self.chatCounts(db, ideaID: id).conversations, 0)
            XCTAssertEqual(try Self.chatCounts(db, ideaID: id).messages, 0)
        }
    }

    /// A survivor's hint pointing at a doomed CHILD is nulled too — the whole
    /// chain is gone, not just the id the owner clicked delete on.
    func testDelete_NullsBackReferencesPointingAtACascadedChild() throws {
        let db = try TestDatabase.create()
        let (survivorID, pointerID) = try db.write { db -> (Int64, Int64) in
            try Self.createChatTables(db)
            let survivorID = try TestDatabase.insertIdea(db, title: "Canonical")
            let mergedID = try TestDatabase.insertIdea(
                db, title: "Merged away", status: "merged", mergedIntoID: Int(survivorID))
            let pointerID = try TestDatabase.insertIdea(
                db, title: "Looks similar to the husk", similarToID: Int(mergedID))
            return (survivorID, pointerID)
        }

        try db.write { try IdeaQueries.delete($0, id: Int(survivorID)) }

        let pointer = try db.read { try IdeaQueries.fetchOne($0, id: Int(pointerID)) }
        XCTAssertNotNil(pointer)
        XCTAssertNil(pointer?.similarToID)
    }

    func testDelete_UnknownIDIsACleanNoOp() throws {
        let db = try TestDatabase.create()
        let ideaID = try db.write { db -> Int64 in
            try Self.createChatTables(db)
            return try TestDatabase.insertIdea(db, title: "Untouched")
        }

        try db.write { try IdeaQueries.delete($0, id: 999) }

        XCTAssertNotNil(try db.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) })
    }

    /// An idea nobody ever opened a Discuss chat for deletes just the same.
    func testDelete_NoChatIsCleanSuccess() throws {
        let db = try TestDatabase.create()
        let ideaID = try db.write { db -> Int64 in
            try Self.createChatTables(db)
            return try TestDatabase.insertIdea(db, title: "Never discussed")
        }

        try db.write { try IdeaQueries.delete($0, id: Int(ideaID)) }

        XCTAssertNil(try db.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) })
    }

    // MARK: - countIdeasAndNotes

    func testCountIdeasAndNotesCountsBothKindsAndSkipsDecisions() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, kind: "idea")
            try TestDatabase.insertIdea(db, kind: "note")
            try TestDatabase.insertIdea(db, kind: "decision")
        }

        XCTAssertEqual(try db.read { try IdeaQueries.countIdeasAndNotes($0) }, 2)
    }

    // MARK: - reviewCountsByKind

    func testReviewCountsByKindCountsEachSegmentSeparately() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, kind: "idea", status: "proposed")
            try TestDatabase.insertIdea(db, kind: "idea", status: "active", needsReview: true)
            try TestDatabase.insertIdea(db, kind: "idea", status: "active")
            try TestDatabase.insertIdea(db, kind: "note", status: "proposed")
            try TestDatabase.insertIdea(db, kind: "decision", status: "active", needsReview: true)
        }

        let counts = try db.read { try IdeaQueries.reviewCountsByKind($0) }

        XCTAssertEqual(counts, ["idea": 2, "note": 1], "settled entries and decisions never count")
    }

    /// A kind with nothing waiting is absent, not zero — the segment label
    /// renders a count only when the key is there.
    func testReviewCountsByKindOmitsAKindWithNothingWaiting() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, kind: "idea", status: "proposed")
            try TestDatabase.insertIdea(db, kind: "note", status: "active")
        }

        let counts = try db.read { try IdeaQueries.reviewCountsByKind($0) }

        XCTAssertEqual(counts, ["idea": 1])
    }

    // MARK: - Chat fixtures

    /// The chat tables are created lazily at runtime by `DatabaseManager`, not
    /// by the test schema. `ChatMessageQueries` stays app-side, so its
    /// `ensureTable` DDL is mirrored here to let this file live in
    /// WatchtowerCoreTests.
    private static func createChatTables(_ db: Database) throws {
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
    }

    private static func insertChat(_ db: Database, ideaID: Int64, messages: Int) throws {
        try db.execute(sql: """
            INSERT INTO chat_conversations (context_type, context_id, title, created_at, updated_at)
            VALUES ('idea', ?, 'Discuss', 0, 0)
            """, arguments: [ideaID])
        let conversationID = db.lastInsertedRowID
        for index in 0..<messages {
            try db.execute(sql: """
                INSERT INTO chat_messages (conversation_id, role, text, created_at)
                VALUES (?, 'user', ?, 0)
                """, arguments: [conversationID, "message \(index)"])
        }
    }

    private static func chatCounts(_ db: DatabaseQueue, ideaID: Int64) throws -> (conversations: Int, messages: Int) {
        try db.read { db in
            let conversations = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM chat_conversations WHERE context_type = 'idea' AND context_id = ?
                """, arguments: [ideaID]) ?? 0
            let messages = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM chat_messages WHERE conversation_id IN (
                    SELECT id FROM chat_conversations WHERE context_type = 'idea' AND context_id = ?
                )
                """, arguments: [ideaID]) ?? 0
            return (conversations, messages)
        }
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
