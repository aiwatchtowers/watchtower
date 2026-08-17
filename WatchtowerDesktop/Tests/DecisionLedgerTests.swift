import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// VM-level coverage for the Decisions segment's ledger flows
/// (`DigestViewModel.ledgerDecisions`/`unreadDecisionCount`/mark-seen/
/// supersede/reverse/rating). `IdeaQueriesTests` covers the underlying
/// `IdeaQueries` reads/writes directly; this file covers the view model that
/// wires them into the Digests tab's Decisions segment.
final class DecisionLedgerTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    // MARK: - Load

    @MainActor
    func testLoadExposesLedgerDecisionsSortedNewestMentionedFirst() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertIdea(db, kind: "decision", title: "Older", lastMentionAt: "2026-01-01T00:00:00Z")
            try TestDatabase.insertIdea(db, kind: "decision", title: "Newer", lastMentionAt: "2026-06-01T00:00:00Z")
            // Non-decision kinds must not leak into the ledger.
            try TestDatabase.insertIdea(db, kind: "idea", title: "An idea")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.ledgerDecisions.map(\.title), ["Newer", "Older"])
    }

    @MainActor
    func testLoadFallsBackToUpdatedAtWhenNoMention() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertIdea(
                db, kind: "decision", title: "No mention yet",
                lastMentionAt: "", updatedAt: "2026-07-01T00:00:00Z"
            )
            try TestDatabase.insertIdea(
                db, kind: "decision", title: "Mentioned",
                lastMentionAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"
            )
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        // "No mention yet" sorts by its updated_at (2026-07), ahead of the
        // 2026-01 mention.
        XCTAssertEqual(vm.ledgerDecisions.map(\.title), ["No mention yet", "Mentioned"])
    }

    @MainActor
    func testOldestFirstSortReversesTheLedger() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertIdea(db, kind: "decision", title: "Older", lastMentionAt: "2026-01-01T00:00:00Z")
            try TestDatabase.insertIdea(db, kind: "decision", title: "Newer", lastMentionAt: "2026-06-01T00:00:00Z")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()
        XCTAssertEqual(vm.ledgerDecisions.map(\.title), ["Newer", "Older"])

        vm.setSortOrder(.oldestFirst)
        XCTAssertEqual(vm.ledgerDecisions.map(\.title), ["Older", "Newer"])

        vm.setSortOrder(.newestFirst)
        XCTAssertEqual(vm.ledgerDecisions.map(\.title), ["Newer", "Older"])
    }

    // MARK: - Unread / mark-seen

    @MainActor
    func testUnreadDecisionCountReflectsUnseenAndReflagged() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertIdea(db, kind: "decision", title: "Unseen", seenAt: nil)
            try TestDatabase.insertIdea(db, kind: "decision", title: "Seen", seenAt: "2026-01-01T00:00:00Z")
            try TestDatabase.insertIdea(
                db, kind: "decision", title: "Reflagged",
                needsReview: true, seenAt: "2026-01-01T00:00:00Z"
            )
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.unreadDecisionCount, 2)
    }

    @MainActor
    func testMarkDecisionSeenDropsUnreadCount() throws {
        let ideaID = try dbManager.dbPool.write { db in
            try TestDatabase.insertIdea(db, kind: "decision", title: "Unseen", seenAt: nil)
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()
        XCTAssertEqual(vm.unreadDecisionCount, 1)

        vm.markDecisionSeen(id: Int(ideaID))

        XCTAssertEqual(vm.unreadDecisionCount, 0)
        XCTAssertNotNil(vm.ledgerDecisions.first { $0.id == Int(ideaID) }?.seenAt)
    }

    @MainActor
    func testMarkAllDecisionsSeenClearsUnreadCount() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertIdea(db, kind: "decision", title: "A", seenAt: nil)
            try TestDatabase.insertIdea(db, kind: "decision", title: "B", seenAt: nil)
            try TestDatabase.insertIdea(db, kind: "decision", title: "C", seenAt: "2026-01-01T00:00:00Z")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()
        XCTAssertEqual(vm.unreadDecisionCount, 2)

        vm.markAllDecisionsSeen()

        XCTAssertEqual(vm.unreadDecisionCount, 0)
        // Every previously-unseen row is now stamped, matching what the
        // Decisions toolbar's "Mark all read" button (DigestListView) drives.
        XCTAssertTrue(vm.ledgerDecisions.allSatisfy { $0.seenAt != nil })
    }

    // MARK: - Mention sources (row glyphs)

    @MainActor
    func testLoadExposesDecisionMentionSources() throws {
        let ideaID = try dbManager.dbPool.write { db -> Int64 in
            let id = try TestDatabase.insertIdea(db, kind: "decision", title: "A call")
            try TestDatabase.insertIdeaMention(db, ideaID: id, source: "slack")
            try TestDatabase.insertIdeaMention(db, ideaID: id, source: "jira")
            return id
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(Set(vm.decisionMentionSources[Int(ideaID)] ?? []), ["slack", "jira"])
    }

    @MainActor
    func testDecisionMentionSourcesSurvivesReloadAfterAWrite() throws {
        let ideaID = try dbManager.dbPool.write { db -> Int64 in
            let id = try TestDatabase.insertIdea(db, kind: "decision", title: "A call", seenAt: nil)
            try TestDatabase.insertIdeaMention(db, ideaID: id, source: "meeting")
            return id
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()
        XCTAssertEqual(vm.decisionMentionSources[Int(ideaID)], ["meeting"])

        // reloadLedger() (invoked internally by every write action) must keep
        // refreshing the source map, not just the decisions/unread count.
        vm.markDecisionSeen(id: Int(ideaID))

        XCTAssertEqual(vm.decisionMentionSources[Int(ideaID)], ["meeting"])
    }

    // MARK: - Supersede / reverse

    @MainActor
    func testSupersedeSetsStatusAndSupersededByID() throws {
        let ids = try dbManager.dbPool.write { db -> (old: Int64, new: Int64) in
            let old = try TestDatabase.insertIdea(db, kind: "decision", title: "Old plan", status: "active")
            let new = try TestDatabase.insertIdea(db, kind: "decision", title: "New plan", status: "active")
            return (old, new)
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        vm.supersede(id: Int(ids.old), by: Int(ids.new))

        let updated = try XCTUnwrap(vm.ledgerDecisions.first { $0.id == Int(ids.old) })
        XCTAssertEqual(updated.status, .superseded)
        XCTAssertEqual(updated.supersededByID, Int(ids.new))
    }

    @MainActor
    func testSupersedeWithoutReplacementLeavesSupersededByIDNil() throws {
        let ideaID = try dbManager.dbPool.write { db in
            try TestDatabase.insertIdea(db, kind: "decision", title: "Old plan", status: "active")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()
        vm.supersede(id: Int(ideaID))

        let updated = try XCTUnwrap(vm.ledgerDecisions.first { $0.id == Int(ideaID) })
        XCTAssertEqual(updated.status, .superseded)
        XCTAssertNil(updated.supersededByID)
    }

    @MainActor
    func testReverseSetsStatusReversed() throws {
        let ideaID = try dbManager.dbPool.write { db in
            try TestDatabase.insertIdea(db, kind: "decision", title: "A call", status: "active")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()
        vm.reverse(id: Int(ideaID))

        let updated = try XCTUnwrap(vm.ledgerDecisions.first { $0.id == Int(ideaID) })
        XCTAssertEqual(updated.status, .reversed)
    }

    // MARK: - Rating

    @MainActor
    func testSetRatingPersistsRatingAndComment() throws {
        let ideaID = try dbManager.dbPool.write { db in
            try TestDatabase.insertIdea(db, kind: "decision", title: "A call")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        let ok = vm.setRating(id: Int(ideaID), rating: 1, comment: "Good call")
        XCTAssertTrue(ok)

        let updated = try XCTUnwrap(vm.ledgerDecisions.first { $0.id == Int(ideaID) })
        XCTAssertEqual(updated.ownerRating, 1)
        XCTAssertEqual(updated.ratingComment, "Good call")
    }
}
