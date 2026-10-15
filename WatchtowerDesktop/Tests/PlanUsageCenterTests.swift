import XCTest
import GRDB
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

@MainActor
final class PlanUsageCenterTests: XCTestCase {
    final class StubRunner: CLIRunnerProtocol {
        var calls: [[String]] = []
        func run(args: [String]) async throws -> Data { calls.append(args); return Data() }
    }

    private var pool: DatabasePool!
    private var path: String!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    func testReloadAndLabels() async throws {
        let limitsJSON = """
        [{"key":"session","label":"5-hour","group":"session","percent":92,"resets_at":"2026-10-15T12:00:00Z","severity":"warning",
        "projection":{"state":"hit","hit_at":null,"rate_per_hour":0}},
        {"key":"weekly_all","label":"Weekly","group":"weekly","percent":59,"resets_at":"2026-10-19T16:00:00Z","severity":"normal",
        "projection":{"state":"safe","hit_at":null,"rate_per_hour":0}}]
        """
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO plan_usage_status (id, state, plan, fetched_at, limits_json, breakdown_json, updated_at)
                VALUES (1, 'ok', 'max', '2026-10-15T09:59:00Z',
                ?, '[]', '2026-10-15T09:59:00Z')
                """, arguments: [limitsJSON])
        }
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-15T10:00:00Z"))
        let runner = StubRunner()
        let center = PlanUsageCenter(dbPool: pool, runner: runner) { now }
        var seen: PlanUsageStatus?
        center.onStatus = { seen = $0 }
        await center.reload()
        XCTAssertEqual(center.menuBarLabel(showText: true), "⚠︎ 5h 92% · 7d 59%")
        XCTAssertNil(center.menuBarLabel(showText: false))
        XCTAssertEqual(center.trayLines.count, 2)
        XCTAssertEqual(seen?.plan, "max")
        await center.refresh()
        XCTAssertEqual(runner.calls, [["usage", "plan", "--now"]])
    }

    func testNoStatusYieldsNoLabelOrRows() async {
        let center = PlanUsageCenter(dbPool: pool, runner: nil)
        await center.reload()
        XCTAssertNil(center.status)
        XCTAssertNil(center.menuBarLabel(showText: true))
        XCTAssertTrue(center.trayLines.isEmpty)
    }

    private func insertStatus(state: String, fetchedAt: String, percent: Double) async throws {
        let limits = """
        [{"key":"session","label":"5-hour","group":"session","percent":\(percent),"resets_at":"2026-10-15T12:00:00Z","severity":"normal",
        "projection":{"state":"safe","hit_at":null,"rate_per_hour":0}},
        {"key":"weekly_all","label":"Weekly","group":"weekly","percent":59,"resets_at":"2026-10-19T16:00:00Z","severity":"normal",
        "projection":{"state":"safe","hit_at":null,"rate_per_hour":0}}]
        """
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO plan_usage_status (id, state, plan, fetched_at, limits_json, breakdown_json, updated_at)
                VALUES (1, ?, 'max', ?, ?, '[]', ?)
                """, arguments: [state, fetchedAt, limits, fetchedAt])
        }
    }

    func testCalmStatusHasNoWarningMark() async throws {
        try await insertStatus(state: "ok", fetchedAt: "2026-10-15T09:59:00Z", percent: 4)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-15T10:00:00Z"))
        let center = PlanUsageCenter(dbPool: pool, runner: nil) { now }
        await center.reload()
        XCTAssertEqual(center.menuBarLabel(showText: true), "5h 4% · 7d 59%")
    }

    func testStaleStatusKeepsTextWithoutWarningMark() async throws {
        try await insertStatus(state: "ok", fetchedAt: "2026-10-15T09:00:00Z", percent: 92)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-15T10:00:00Z"))
        let center = PlanUsageCenter(dbPool: pool, runner: nil) { now }
        await center.reload()
        XCTAssertEqual(center.menuBarLabel(showText: true), "5h 92% · 7d 59%")
    }

    func testNonOkStateWithoutLimitsShowsNoLabel() async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO plan_usage_status (id, state, reason, fetched_at, limits_json, breakdown_json, updated_at)
                VALUES (1, 'unavailable', 'no_credentials', NULL, '[]', '[]', '2026-10-15T09:59:00Z')
                """)
        }
        let center = PlanUsageCenter(dbPool: pool, runner: nil)
        await center.reload()
        XCTAssertNil(center.menuBarLabel(showText: true))
        XCTAssertTrue(center.trayLines.isEmpty)
    }
}
