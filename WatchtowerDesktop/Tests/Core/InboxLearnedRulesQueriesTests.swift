import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

// MARK: - InboxLearnedRulesQueries Tests

final class InboxLearnedRulesQueriesTests: XCTestCase {

    private let nowISO = "2026-04-23T10:00:00Z"

    private func makePool() throws -> DatabasePool {
        let (pool, _) = try TestDatabase.createPool()
        return pool
    }

    // MARK: - listAll

    func test_INBOX_05_list_rules_ordered_by_weight() throws {
        // BEHAVIOR INBOX-05 — see docs/inventory/inbox-pulse.md
        // Learned tab lists rules ordered so the most impactful are visible first.
        // Do not weaken or remove without explicit owner approval.
        let pool = try makePool()
        let q = InboxLearnedRulesQueries(dbPool: pool)
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, evidence_count, last_updated)
                    VALUES ('source_mute', 'a', -0.9, 'user_rule', 0, ?)
                    """,
                arguments: [nowISO]
            )
            try db.execute(
                sql: """
                    INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, evidence_count, last_updated)
                    VALUES ('source_boost', 'b', 0.5, 'implicit', 5, ?)
                    """,
                arguments: [nowISO]
            )
        }
        let out = try q.listAll()
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].scopeKey, "a")  // ABS(-0.9) = 0.9 > ABS(0.5) = 0.5
        XCTAssertEqual(out[1].scopeKey, "b")
    }

    func testListAllEmptyWhenNoRules() throws {
        let pool = try makePool()
        let q = InboxLearnedRulesQueries(dbPool: pool)
        let out = try q.listAll()
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - upsertManual

    func testUpsertManualCreatesNewRule() throws {
        let pool = try makePool()
        let q = InboxLearnedRulesQueries(dbPool: pool)
        try q.upsertManual(ruleType: "source_mute", scopeKey: "sender:U1", weight: -0.9)
        let all = try q.listAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].ruleType, "source_mute")
        XCTAssertEqual(all[0].scopeKey, "sender:U1")
        XCTAssertEqual(all[0].weight, -0.9)
        XCTAssertEqual(all[0].source, "user_rule")
    }

    func testUpsertManualUpdatesExistingRule() throws {
        let pool = try makePool()
        let q = InboxLearnedRulesQueries(dbPool: pool)
        try q.upsertManual(ruleType: "source_mute", scopeKey: "sender:U1", weight: -0.5)
        try q.upsertManual(ruleType: "source_mute", scopeKey: "sender:U1", weight: -0.9)
        let all = try q.listAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].weight, -0.9)
        XCTAssertEqual(all[0].source, "user_rule")
    }

    func test_INBOX_06_manual_rule_overrides_implicit() throws {
        // BEHAVIOR INBOX-06 — see docs/inventory/inbox-pulse.md
        // Manual rule upsert overrides an existing implicit rule on the same scope.
        // Do not weaken or remove without explicit owner approval.
        let pool = try makePool()
        let q = InboxLearnedRulesQueries(dbPool: pool)
        // Insert an implicit rule first
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, evidence_count, last_updated)
                    VALUES ('source_mute', 'sender:U1', -0.3, 'implicit', 3, ?)
                    """,
                arguments: [nowISO]
            )
        }
        // Now upsert manual — should override source to 'user_rule'
        try q.upsertManual(ruleType: "source_mute", scopeKey: "sender:U1", weight: -0.9)
        let all = try q.listAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].source, "user_rule")
        XCTAssertEqual(all[0].weight, -0.9)
    }

    // MARK: - delete

    func testDeleteRule() throws {
        let pool = try makePool()
        let q = InboxLearnedRulesQueries(dbPool: pool)
        try q.upsertManual(ruleType: "source_mute", scopeKey: "sender:U1", weight: -0.9)
        XCTAssertEqual(try q.listAll().count, 1)
        try q.delete(ruleType: "source_mute", scopeKey: "sender:U1")
        XCTAssertEqual(try q.listAll().count, 0)
    }

    func testDeleteNonExistentRuleIsNoop() throws {
        let pool = try makePool()
        let q = InboxLearnedRulesQueries(dbPool: pool)
        XCTAssertNoThrow(try q.delete(ruleType: "source_mute", scopeKey: "sender:X"))
        XCTAssertEqual(try q.listAll().count, 0)
    }

    // MARK: - observeAll

    func testObserveAllReturnsValueObservation() throws {
        let pool = try makePool()
        let q = InboxLearnedRulesQueries(dbPool: pool)
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, evidence_count, last_updated)
                    VALUES ('source_mute', 'sender:U1', -0.9, 'user_rule', 0, ?)
                    """,
                arguments: [nowISO]
            )
        }
        var receivedRules: [InboxLearnedRule] = []
        let exp = expectation(description: "observation fires")
        let obs = q.observeAll()
        let cancellable = obs.start(
            in: pool,
            scheduling: .immediate
        ) { error in
            XCTFail("Observation error: \(error)")
        } onChange: { rules in
            receivedRules = rules
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(receivedRules.count, 1)
        XCTAssertEqual(receivedRules[0].scopeKey, "sender:U1")
        _ = cancellable
    }
}
