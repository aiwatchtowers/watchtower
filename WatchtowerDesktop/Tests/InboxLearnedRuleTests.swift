import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

// MARK: - InboxLearnedRule Model Tests

final class InboxLearnedRuleTests: XCTestCase {

    func testInboxLearnedRuleFetches() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, evidence_count, last_updated)
                VALUES ('source_mute','sender:U1',-0.7,'implicit',10,'2026-04-23T10:00:00Z')
            """)
        }
        let rules = try db.read { db in try InboxLearnedRule.fetchAll(db) }
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].scopeKey, "sender:U1")
        XCTAssertEqual(rules[0].weight, -0.7)
    }

    func testInboxLearnedRuleFields() throws {
        let db = try TestDatabase.create()
        try db.write { try TestDatabase.insertLearnedRule($0) }
        let rule = try XCTUnwrap(db.read {
            try InboxLearnedRule.fetchOne($0, sql: "SELECT * FROM inbox_learned_rules LIMIT 1")
        })
        XCTAssertEqual(rule.ruleType, "source_mute")
        XCTAssertEqual(rule.scopeKey, "sender:U1")
        XCTAssertEqual(rule.weight, -0.5)
        XCTAssertEqual(rule.source, "implicit")
        XCTAssertEqual(rule.evidenceCount, 3)
        XCTAssertEqual(rule.lastUpdated, "2026-04-23T10:00:00Z")
    }

    func testInboxLearnedRuleInsertAndFetch() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            var rule = InboxLearnedRule(
                id: nil,
                ruleType: "source_boost",
                scopeKey: "sender:U2",
                weight: 0.8,
                source: "explicit_feedback",
                evidenceCount: 1,
                lastUpdated: "2026-04-23T12:00:00Z"
            )
            try rule.insert(db)
        }
        let rules = try db.read { try InboxLearnedRule.fetchAll($0) }
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].ruleType, "source_boost")
        XCTAssertEqual(rules[0].source, "explicit_feedback")
        XCTAssertNotNil(rules[0].id)
    }

    func testInboxLearnedRuleEquatable() throws {
        let r1 = InboxLearnedRule(
            id: 1, ruleType: "source_mute", scopeKey: "sender:U1",
            weight: -0.5, source: "implicit", evidenceCount: 3,
            lastUpdated: "2026-04-23T10:00:00Z"
        )
        let r2 = InboxLearnedRule(
            id: 1, ruleType: "source_mute", scopeKey: "sender:U1",
            weight: -0.5, source: "implicit", evidenceCount: 3,
            lastUpdated: "2026-04-23T10:00:00Z"
        )
        XCTAssertEqual(r1, r2)
    }

    func testInboxLearnedRuleMultipleRows() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertLearnedRule(db, scopeKey: "sender:U1", weight: -0.5)
            try TestDatabase.insertLearnedRule(db, scopeKey: "sender:U2", weight: 0.8, source: "explicit_feedback", ruleType: "source_boost")
        }
        let rules = try db.read { try InboxLearnedRule.fetchAll($0) }
        XCTAssertEqual(rules.count, 2)
    }
}
