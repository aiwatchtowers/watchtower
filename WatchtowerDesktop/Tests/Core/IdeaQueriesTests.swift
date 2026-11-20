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

        let ideas = try db.read { try IdeaQueries.fetchList($0, kind: "decision", limit: 10) }

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

        let ideas = try db.read { try IdeaQueries.fetchList($0, kind: nil, limit: 10) }

        XCTAssertEqual(Set(ideas.map(\.title)), ["An idea", "A note"])
    }

    func testFetchListWithExplicitDecisionKindReturnsDecisions() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, kind: "idea", title: "An idea")
            try TestDatabase.insertIdea(db, kind: "decision", title: "A decision")
        }

        let ideas = try db.read { try IdeaQueries.fetchList($0, kind: "decision", limit: 10) }

        XCTAssertEqual(ideas.map(\.title), ["A decision"])
    }

    func testFetchListOrderedByUpdatedAtDescending() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, title: "Older", updatedAt: "2026-04-27T00:00:00Z")
            try TestDatabase.insertIdea(db, title: "Newer", updatedAt: "2026-04-29T00:00:00Z")
        }

        let ideas = try db.read { try IdeaQueries.fetchList($0, kind: nil, limit: 10) }

        XCTAssertEqual(ideas.map(\.title), ["Newer", "Older"])
    }

    func testFetchListRespectsLimit() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertIdea(db, title: "A")
            try TestDatabase.insertIdea(db, title: "B")
            try TestDatabase.insertIdea(db, title: "C")
        }

        let ideas = try db.read { try IdeaQueries.fetchList($0, kind: nil, limit: 2) }

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
            try IdeaQueries.fetchList($0, kind: nil, limit: 2, excludingReviewQueue: true)
        }

        XCTAssertEqual(Set(ideas.map(\.title)), ["Reg1", "Reg2"])
    }

    // MARK: - setStatus

    // MARK: - snooze

    // MARK: - merge

    // MARK: - supersede

    // MARK: - setRating

    // MARK: - createManual

    // MARK: - markConverted

    // MARK: - IDEA-04 clearability

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

    // MARK: - delete

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
