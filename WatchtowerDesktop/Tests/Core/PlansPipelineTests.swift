import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class PlansPipelineTests: XCTestCase {
    func testRawCodexPublicationReachesProductionQueriesAndPresentation() throws {
        let queue = try TestDatabase.create()
        let fixture = try queue.write { try PlansPipelineFixture.load($0) }
        let wire = try XCTUnwrap(fixture.envelope.providers.first?.status)
        XCTAssertEqual(fixture.envelope.requestedProvider, "codex")
        XCTAssertTrue(fixture.envelope.providers[0].ok)
        XCTAssertTrue(fixture.status.historyAvailable)
        XCTAssertEqual(fixture.status.limits.count, 2)
        let screen = PlansScreenPresentation(claude: nil, codex: fixture.status, now: fixture.now)
        let codex = screen.providers[1]
        XCTAssertEqual(screen.statusTitle, "Codex may run out before reset")
        XCTAssertEqual(codex.primary?.tone, .warning)
        for limit in fixture.status.limits {
            let history = try XCTUnwrap(fixture.status.history[limit.key])
            XCTAssertEqual(history.count, 2, "foreign scope/reset and unpublished rows in the Go bundle stay excluded")
            XCTAssertEqual(history.last?.takenAt, fixture.status.fetchedAt)
            let expected = try XCTUnwrap(wire.limits.first { $0.key == limit.key })
            let forecast = try fixture.status.forecast(for: limit, now: fixture.now)
            XCTAssertEqual(forecast.line, expected.projection.line, "Swift renders the exact published Go endpoint")
            XCTAssertEqual(forecast.state, expected.projection.state)
            XCTAssertTrue(forecast.drawable)
        }
        XCTAssertNotNil(codex.selected(.weekly)?.line)
        XCTAssertNotNil(codex.selected(.session)?.line)
        XCTAssertEqual(codex.selected(.weekly)?.line?.endPercent, 100)
        XCTAssertEqual(try XCTUnwrap(codex.selected(.session)?.line?.endPercent), 80, accuracy: 0.0000000001)
    }
    func testPositiveRateSafeEndpointCorruptionNeverDraws() throws {
        let queue = try TestDatabase.create()
        let fixture = try queue.write { try PlansPipelineFixture.load($0) }
        let safe = try XCTUnwrap(fixture.status.limits.first { $0.projection.state == "safe" })
        try queue.write { db in
            let raw = try XCTUnwrap(String.fetchOne(db, sql: "SELECT plot_json FROM codex_plan_usage_status"))
            var plot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            var lines = try XCTUnwrap(plot["limits"] as? [String: [String: Any]])
            var candidate = try XCTUnwrap(lines[safe.key])
            let reset = fixture.now.addingTimeInterval(7200)
            let rawLimits = try XCTUnwrap(String.fetchOne(db, sql: "SELECT limits_json FROM codex_plan_usage_status"))
            var limits = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rawLimits.utf8)) as? [[String: Any]])
            let index = try XCTUnwrap(limits.firstIndex { $0["key"] as? String == safe.key })
            limits[index]["percent"] = 40
            limits[index]["resets_at"] = PlanUsageDates.format(reset)
            limits[index]["projection"] = [
                "state": "safe", "rate_per_hour": 10,
                "hit_at": PlanUsageDates.format(fixture.now.addingTimeInterval(21600))
            ]
            candidate["start_percent"] = 40
            candidate["end_at"] = PlanUsageDates.format(reset)
            candidate["end_percent"] = 61
            let encodedLimits = try JSONSerialization.data(withJSONObject: limits, options: [.sortedKeys])
            try db.execute(sql: "UPDATE codex_plan_usage_status SET limits_json = ?",
                           arguments: [try XCTUnwrap(String(data: encodedLimits, encoding: .utf8))])
            try db.execute(sql: "UPDATE codex_plan_usage_samples SET resets_at = ? WHERE limit_key = ?",
                           arguments: [PlanUsageDates.format(reset), safe.key])
            lines[safe.key] = candidate
            plot["limits"] = lines
            let changed = try JSONSerialization.data(withJSONObject: plot, options: [.sortedKeys])
            try db.execute(sql: "UPDATE codex_plan_usage_status SET plot_json = ?",
                           arguments: [try XCTUnwrap(String(data: changed, encoding: .utf8))])
        }
        let changed = try XCTUnwrap(queue.read { try PlanUsageQueries.status($0, provider: .codex) })
        let changedSafe = try XCTUnwrap(changed.limits.first { $0.key == safe.key })
        let result = try changed.forecast(for: changedSafe, now: fixture.now)
        XCTAssertFalse(result.drawable)
        XCTAssertEqual(result.unavailableReason, "invalid_projection")
    }

    func testMissingReceiptFailsClosedAfterExistingEligibilityGates() throws {
        let queue = try TestDatabase.create()
        let fixture = try queue.write { try PlansPipelineFixture.load($0) }
        let safe = try XCTUnwrap(fixture.status.limits.first { $0.projection.state == "safe" })
        let originalScope = try XCTUnwrap(queue.read { try String.fetchOne($0, sql: "SELECT scope FROM codex_plan_usage_status") })
        XCTAssertEqual(fixture.status.publicationIntegrity, .verified)
        try queue.write { try $0.execute(sql: "UPDATE codex_plan_usage_status SET publication_proof = ''") }
        let missing = try XCTUnwrap(queue.read { try PlanUsageQueries.status($0, provider: .codex) })
        XCTAssertEqual(missing.publicationIntegrity, .unverified)
        XCTAssertEqual(try missing.forecast(for: safe, now: fixture.now).unavailableReason, "invalid_projection")
        XCTAssertEqual(try missing.forecast(for: safe, now: fixture.now, enabled: false).unavailableReason, "disabled")
        XCTAssertEqual(try missing.forecast(for: safe, now: fixture.now.addingTimeInterval(901)).unavailableReason, "stale")
        try queue.write { try $0.execute(sql: "UPDATE codex_plan_usage_status SET identity_known = 0, scope = ''") }
        let unknown = try XCTUnwrap(queue.read { try PlanUsageQueries.status($0, provider: .codex) })
        XCTAssertEqual(try unknown.forecast(for: safe, now: fixture.now).unavailableReason, "identity_unknown")
        try queue.write { db in
            try db.execute(sql: "UPDATE codex_plan_usage_status SET identity_known = 1, scope = ?, plot_json = '{}'",
                           arguments: [originalScope])
        }
        let legacy = try XCTUnwrap(queue.read { try PlanUsageQueries.status($0, provider: .codex) })
        XCTAssertEqual(try legacy.forecast(for: safe, now: fixture.now).unavailableReason, "endpoints_unavailable")
    }

}
