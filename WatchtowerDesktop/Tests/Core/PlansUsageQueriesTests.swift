import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class PlansUsageQueriesTests: XCTestCase {
    private let scopeA = String(repeating: "a", count: 64)
    private let scopeB = String(repeating: "b", count: 64)
    private let limits = """
    [{"key":"quota","label":"5 hours","group":"session","percent":40,"window_duration_minutes":300,
      "resets_at":"2026-11-02T11:00:00Z","projection":{"state":"safe","hit_at":null,"rate_per_hour":0}}]
    """

    private func writeStatus(_ db: Database, scope: String, known: Bool, state: String = "ok", plot: String = "{}") throws {
        try db.execute(sql: "DELETE FROM codex_plan_usage_status")
        try db.execute(sql: """
            INSERT INTO codex_plan_usage_status
            (id,state,plan,fetched_at,updated_at,limits_json,scope,identity_known,ordinary_usage_allowed,plot_json)
            VALUES (1,?,'plus','2026-11-02T09:00:00Z','2026-11-02T09:00:00Z',?,?,?,0,?)
            """, arguments: [state, limits, scope, known, plot])
    }

    private func sample(_ db: Database, scope: String, at: String, reset: String = "2026-11-02T11:00:00Z") throws {
        try db.execute(sql: "INSERT INTO codex_plan_usage_samples VALUES (?,?,?,40,?)",
                       arguments: [scope, "quota", at, reset])
    }

    func testCodexHistoryIsScopedResetBoundedAndPublishedOnly() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try writeStatus(db, scope: scopeA, known: true)
            try sample(db, scope: scopeA, at: "2026-11-02T08:59:00Z")
            try sample(db, scope: scopeA, at: "2026-11-02T08:58:00Z", reset: "2026-11-02T11:01:00Z")
            try sample(db, scope: scopeA, at: "2026-11-02T08:57:00Z", reset: "2026-11-02T11:01:01Z")
            try sample(db, scope: scopeA, at: "2026-11-02T09:00:01Z")
            try sample(db, scope: scopeA, at: "2026-11-02T05:00:00Z")
            try sample(db, scope: scopeB, at: "2026-11-02T08:56:00Z")
        }
        let status = try XCTUnwrap(queue.read { try PlanUsageQueries.status($0, provider: .codex) })
        XCTAssertEqual(status.history["quota"]?.count, 2)
        XCTAssertTrue(status.historyAvailable)
        XCTAssertEqual(status.ordinaryUsageAllowed, false)
        XCTAssertEqual(status.provider, .codex)
        try queue.write { try writeStatus($0, scope: scopeB, known: true) }
        let switched = try XCTUnwrap(queue.read { try PlanUsageQueries.status($0, provider: .codex) })
        XCTAssertEqual(switched.history["quota"]?.count, 1, "previous account is excluded")
    }

    func testUnknownIdentitySuccessShowsOwnValuesButFailureHidesRetainedValues() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try writeStatus(db, scope: "", known: false)
            try sample(db, scope: scopeA, at: "2026-11-02T08:59:00Z")
        }
        let current = try XCTUnwrap(queue.read { try PlanUsageQueries.status($0, provider: .codex) })
        XCTAssertEqual(current.limits.first?.percent, 40)
        XCTAssertFalse(current.historyAvailable)
        XCTAssertTrue(current.history.isEmpty)
        let fetched = try XCTUnwrap(current.fetchedAt)
        XCTAssertEqual(try current.forecast(for: XCTUnwrap(current.limits.first), now: fetched).unavailableReason, "identity_unknown")
        try queue.write { try writeStatus($0, scope: "", known: false, state: "error") }
        let failed = try XCTUnwrap(queue.read { try PlanUsageQueries.status($0, provider: .codex) })
        XCTAssertTrue(failed.limits.isEmpty)
        XCTAssertTrue(failed.history.isEmpty)
    }

    func testMalformedPlotAndUnknownRawStateAreReadFailures() throws {
        let queue = try TestDatabase.create()
        for plot in ["null", "[]", "{", "{\"schema_version\":2}"] {
            try queue.write { try writeStatus($0, scope: scopeA, known: true, plot: plot) }
            XCTAssertThrowsError(try queue.read { try PlanUsageQueries.status($0, provider: .codex) })
        }
        try queue.write { db in
            try writeStatus(db, scope: scopeA, known: true)
            try db.execute(sql: "UPDATE codex_plan_usage_status SET limits_json = ?",
                           arguments: [limits.replacingOccurrences(of: "safe", with: "unknown")])
        }
        XCTAssertThrowsError(try queue.read { try PlanUsageQueries.status($0, provider: .codex) })
    }

    func testLegacyClaudeHistoryAlsoExcludesUnpublishedAndDifferentReset() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO plan_usage_status (id,state,fetched_at,updated_at,limits_json)
                VALUES (1,'ok','2026-11-02T09:00:00Z','2026-11-02T09:00:00Z',?)
                """, arguments: [limits])
            try db.execute(sql: """
                INSERT INTO plan_usage_samples VALUES
                ('2026-11-02T08:59:00Z','quota',40,'2026-11-02T11:00:00Z'),
                ('2026-11-02T09:00:01Z','quota',41,'2026-11-02T11:00:00Z'),
                ('2026-11-02T08:58:00Z','quota',39,'2026-11-02T11:01:01Z')
                """)
        }
        let status = try XCTUnwrap(queue.read { try PlanUsageQueries.status($0) })
        XCTAssertEqual(status.limits.first?.windowDurationMinutes, 300)
        XCTAssertEqual(status.history["quota"]?.count, 1)
    }
}
