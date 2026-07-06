import XCTest
import GRDB
@testable import WatchtowerDesktop

// MARK: - SituationQueries Tests

final class SituationQueriesTests: XCTestCase {

    // MARK: - fetchFeed

    func testFetchFeedReturnsOpenOrderedByRankDescThenUpdatedAtDesc() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertSituation(db, title: "Low rank", status: "open", rank: 1)
            try TestDatabase.insertSituation(db, title: "High rank", status: "open", rank: 9)
            try TestDatabase.insertSituation(db, title: "Done, excluded", status: "done", rank: 20)
            try TestDatabase.insertSituation(
                db, title: "Same rank, older", status: "open", rank: 5,
                updatedAt: "2026-04-27T00:00:00Z"
            )
            try TestDatabase.insertSituation(
                db, title: "Same rank, newer", status: "open", rank: 5,
                updatedAt: "2026-04-29T00:00:00Z"
            )
        }

        let feed = try db.read { try SituationQueries.fetchFeed($0, limit: 10, offset: 0) }

        XCTAssertEqual(feed.map(\.title), [
            "High rank",
            "Same rank, newer",
            "Same rank, older",
            "Low rank"
        ])
        XCTAssertTrue(feed.allSatisfy { $0.status == .open })
    }

    func testFetchFeedRespectsLimitAndOffset() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertSituation(db, title: "A", rank: 3)
            try TestDatabase.insertSituation(db, title: "B", rank: 2)
            try TestDatabase.insertSituation(db, title: "C", rank: 1)
        }
        let page = try db.read { try SituationQueries.fetchFeed($0, limit: 1, offset: 1) }
        XCTAssertEqual(page.map(\.title), ["B"])
    }

    // MARK: - fetchByID / openCount

    func testFetchByIDReturnsNilWhenMissing() throws {
        let db = try TestDatabase.create()
        let situation = try db.read { try SituationQueries.fetchByID($0, id: 999) }
        XCTAssertNil(situation)
    }

    func testOpenCountCountsOnlyOpenStatus() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertSituation(db, status: "open")
            try TestDatabase.insertSituation(db, status: "open")
            try TestDatabase.insertSituation(db, status: "done")
            try TestDatabase.insertSituation(db, status: "snoozed")
        }
        let count = try db.read { try SituationQueries.openCount($0) }
        XCTAssertEqual(count, 2)
    }

    // MARK: - memberSignals

    func testMemberSignalsOrderedByMessageTSAscending() throws {
        let db = try TestDatabase.create()
        let situationID = try db.write { db -> Int64 in
            let situationID = try TestDatabase.insertSituation(db)
            let item2 = try TestDatabase.insertInboxItem(db, channelID: "C1", messageTS: "1700000200.000000", snippet: "second")
            let item1 = try TestDatabase.insertInboxItem(db, channelID: "C1", messageTS: "1700000100.000000", snippet: "first")
            let item3 = try TestDatabase.insertInboxItem(db, channelID: "C1", messageTS: "1700000300.000000", snippet: "third")
            try TestDatabase.linkSituationSignal(db, situationID: situationID, inboxItemID: item2)
            try TestDatabase.linkSituationSignal(db, situationID: situationID, inboxItemID: item1)
            try TestDatabase.linkSituationSignal(db, situationID: situationID, inboxItemID: item3)
            return situationID
        }

        let members = try db.read { try SituationQueries.memberSignals($0, situationID: Int(situationID)) }

        XCTAssertEqual(members.map(\.snippet), ["first", "second", "third"])
    }

    func testMemberSignalsEmptyWhenNoLinks() throws {
        let db = try TestDatabase.create()
        let situationID = try db.write { try TestDatabase.insertSituation($0) }
        let members = try db.read { try SituationQueries.memberSignals($0, situationID: Int(situationID)) }
        XCTAssertTrue(members.isEmpty)
    }

    // MARK: - done / dismiss / snooze

    func testDoneSetsStatusAndResolvedReason() throws {
        let db = try TestDatabase.create()
        let id = try db.write { try TestDatabase.insertSituation($0, status: "open") }

        try db.write { try SituationQueries.done($0, id: Int(id)) }

        let (status, reason) = try db.read { db -> (String, String) in
            let row = try Row.fetchOne(db, sql: "SELECT status, resolved_reason FROM situations WHERE id = ?", arguments: [id])!
            return (row["status"] as String, row["resolved_reason"] as String)
        }
        XCTAssertEqual(status, "done")
        XCTAssertEqual(reason, "user_done")
    }

    func testDismissSetsStatusAndResolvedReason() throws {
        let db = try TestDatabase.create()
        let id = try db.write { try TestDatabase.insertSituation($0, status: "open") }

        try db.write { try SituationQueries.dismiss($0, id: Int(id)) }

        let (status, reason) = try db.read { db -> (String, String) in
            let row = try Row.fetchOne(db, sql: "SELECT status, resolved_reason FROM situations WHERE id = ?", arguments: [id])!
            return (row["status"] as String, row["resolved_reason"] as String)
        }
        XCTAssertEqual(status, "dismissed")
        XCTAssertEqual(reason, "user_dismissed")
    }

    func testSnoozeSetsStatusAndUntil() throws {
        let db = try TestDatabase.create()
        let id = try db.write { try TestDatabase.insertSituation($0, status: "open") }

        try db.write { try SituationQueries.snooze($0, id: Int(id), until: "2026-05-10T00:00:00Z") }

        let situation = try db.read { try SituationQueries.fetchByID($0, id: Int(id)) }
        let s = try XCTUnwrap(situation)
        XCTAssertEqual(s.status, .snoozed)
        XCTAssertEqual(s.snoozeUntil, "2026-05-10T00:00:00Z")
    }

    // MARK: - markConverted

    func testMarkConvertedLinksAndSetsStatus() throws {
        let db = try TestDatabase.create()
        let id = try db.write { try TestDatabase.insertSituation($0, status: "open") }

        try db.write { try SituationQueries.markConverted($0, id: Int(id), targetID: 42, trackID: nil) }

        let situation = try db.read { try SituationQueries.fetchByID($0, id: Int(id)) }
        let s = try XCTUnwrap(situation)
        XCTAssertEqual(s.status, .converted)
        XCTAssertEqual(s.convertedTargetID, 42)
        XCTAssertNil(s.convertedTrackID)
    }

    func testMarkConvertedWithTrack() throws {
        let db = try TestDatabase.create()
        let id = try db.write { try TestDatabase.insertSituation($0, status: "open") }

        try db.write { try SituationQueries.markConverted($0, id: Int(id), targetID: nil, trackID: 17) }

        let situation = try db.read { try SituationQueries.fetchByID($0, id: Int(id)) }
        let s = try XCTUnwrap(situation)
        XCTAssertEqual(s.status, .converted)
        XCTAssertNil(s.convertedTargetID)
        XCTAssertEqual(s.convertedTrackID, 17)
    }

    // MARK: - recordFeedback

    func testRecordFeedbackNegativeOneCreatesChannelMuteRuleForEachMemberScope() throws {
        let db = try TestDatabase.create()
        let situationID = try db.write { db -> Int64 in
            let situationID = try TestDatabase.insertSituation(db)
            let itemA = try TestDatabase.insertInboxItem(db, channelID: "C-alpha", messageTS: "1700000100.000000")
            let itemB = try TestDatabase.insertInboxItem(db, channelID: "C-beta", messageTS: "1700000200.000000")
            // A second signal in the same channel as itemA — must not produce a duplicate rule.
            let itemA2 = try TestDatabase.insertInboxItem(db, channelID: "C-alpha", messageTS: "1700000300.000000")
            try TestDatabase.linkSituationSignal(db, situationID: situationID, inboxItemID: itemA)
            try TestDatabase.linkSituationSignal(db, situationID: situationID, inboxItemID: itemB)
            try TestDatabase.linkSituationSignal(db, situationID: situationID, inboxItemID: itemA2)
            return situationID
        }

        try db.write { try SituationQueries.recordFeedback($0, situationID: Int(situationID), rating: -1) }

        let rules = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT rule_type, scope_key, weight, source, evidence_count FROM inbox_learned_rules
                ORDER BY scope_key
                """)
        }
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0]["scope_key"] as String, "channel:C-alpha")
        XCTAssertEqual(rules[1]["scope_key"] as String, "channel:C-beta")
        for row in rules {
            XCTAssertEqual(row["rule_type"] as String, "source_mute")
            XCTAssertEqual(row["weight"] as Double, -1.0)
            XCTAssertEqual(row["source"] as String, "user_rule")
            XCTAssertEqual(row["evidence_count"] as Int, 1)
        }
    }

    func testRecordFeedbackNegativeOneUpsertsExistingRule() throws {
        let db = try TestDatabase.create()
        let situationID = try db.write { db -> Int64 in
            try TestDatabase.insertLearnedRule(
                db, scopeKey: "channel:C-alpha", weight: -0.3, source: "implicit", evidenceCount: 2
            )
            let situationID = try TestDatabase.insertSituation(db)
            let item = try TestDatabase.insertInboxItem(db, channelID: "C-alpha")
            try TestDatabase.linkSituationSignal(db, situationID: situationID, inboxItemID: item)
            return situationID
        }

        try db.write { try SituationQueries.recordFeedback($0, situationID: Int(situationID), rating: -1) }

        let row = try db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT weight, source, evidence_count FROM inbox_learned_rules WHERE scope_key = 'channel:C-alpha'
                """)!
        }
        XCTAssertEqual(row["weight"] as Double, -1.0)
        XCTAssertEqual(row["source"] as String, "user_rule")
        XCTAssertEqual(row["evidence_count"] as Int, 3)
    }

    func testRecordFeedbackPositiveOneCreatesNoRule() throws {
        let db = try TestDatabase.create()
        let situationID = try db.write { db -> Int64 in
            let situationID = try TestDatabase.insertSituation(db)
            let item = try TestDatabase.insertInboxItem(db, channelID: "C-alpha")
            try TestDatabase.linkSituationSignal(db, situationID: situationID, inboxItemID: item)
            return situationID
        }

        try db.write { try SituationQueries.recordFeedback($0, situationID: Int(situationID), rating: 1) }

        let count = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_learned_rules") ?? 0
        }
        XCTAssertEqual(count, 0)
    }
}
