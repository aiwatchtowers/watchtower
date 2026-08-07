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

    func testFetchMentionsOrderedByCreatedAtAscending() throws {
        let db = try TestDatabase.create()
        let ideaID = try db.write { db -> Int64 in
            let ideaID = try TestDatabase.insertIdea(db)
            try TestDatabase.insertIdeaMention(db, ideaID: ideaID, quote: "second", createdAt: "2026-04-27T00:00:02Z")
            try TestDatabase.insertIdeaMention(db, ideaID: ideaID, quote: "first", createdAt: "2026-04-27T00:00:01Z")
            return ideaID
        }

        let mentions = try db.read { try IdeaQueries.fetchMentions($0, ideaID: Int(ideaID)) }

        XCTAssertEqual(mentions.map(\.quote), ["first", "second"])
    }

    // MARK: - setStatus

    func testSetStatusClearsNeedsReview() throws {
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

    func testMergeReparentsMentionsAndFollowsLink() throws {
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

    func testMarkConvertedSetsStatusAndTargetLink() throws {
        let db = try TestDatabase.create()
        let ideaID = try db.write { db in try TestDatabase.insertIdea(db, status: "active") }

        try db.write { try IdeaQueries.markConverted($0, id: Int(ideaID), targetID: 42) }

        let idea = try db.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) }
        XCTAssertEqual(idea?.status, .converted)
        XCTAssertEqual(idea?.convertedTargetID, 42)
    }
}
