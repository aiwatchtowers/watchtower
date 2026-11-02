import XCTest
import Observation
import GRDB
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

@MainActor
final class PlansUsageCenterTests: XCTestCase {
    private func envelope(provider: String, error: String? = nil, enabled: Bool = true) -> Data {
        let errorJSON = error.map { "{\"code\":\"\($0)\",\"message\":\"safe\"}" } ?? "null"
        let outcome = error == "feature_disabled" ? "disabled" : (error == nil ? "updated" : "busy")
        return Data("""
        {"schema_version":1,"requested_provider":"\(provider)","refresh_requested":true,"feature_enabled":\(enabled),
         "providers":[{"provider":"\(provider)","ok":\(error == nil ? "true" : "false"),"error":\(errorJSON),
         "refresh_outcome":"\(outcome)","status":null}]}
        """.utf8)
    }

    func testRepeatedRefreshWaitsForSameTaskAndSurvivesCallerCancellation() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let cli = HeldCLIRunner(stdout: envelope(provider: "codex", error: "busy"))
        let center = PlanUsageCenter(dbPool: pool, runner: cli)
        let first = Task { await center.refresh(.codex) }
        await awaitStarted(cli)
        first.cancel() // A disappearing caller does not own the app-wide operation.
        let started = expectation(description: "second caller")
        let second = Task {
            started.fulfill()
            return await center.refresh(.codex)
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(cli.invocations.count, 1)
        XCTAssertTrue(center.refreshingProviders.contains(.codex))
        cli.release()
        let a = await first.value
        let b = await second.value
        XCTAssertEqual(a?.code, "busy")
        XCTAssertEqual(b?.code, "busy")
        XCTAssertFalse(center.isRefreshing)
        XCTAssertEqual(center.refreshErrors[.codex]?.code, "busy")
    }

    func testProviderRetryDoesNotStartSiblingAndPartialErrorIsConsumed() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let cli = CapturedRunner(result: CLICapturedResult(stdout: envelope(provider: "codex", error: "busy"), exitCode: 1))
        let center = PlanUsageCenter(dbPool: pool, runner: cli)
        let result = await center.refresh(.codex)
        XCTAssertEqual(result?.code, "busy")
        XCTAssertEqual(cli.calls, [["usage", "plans", "--json", "--now", "--provider", "codex"]])
        XCTAssertNil(center.refreshErrors[.claude])
    }

    func testIndependentReadFailureDoesNotFreezeHealthyProvider() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO plan_usage_status (id,state,updated_at) VALUES (1,'ok','2026-11-02T09:00:00Z');
                DROP TABLE codex_plan_usage_status;
                """)
        }
        let center = PlanUsageCenter(dbPool: pool, runner: nil)
        await center.reload()
        XCTAssertNotNil(center.status)
        XCTAssertNil(center.codexStatus)
        XCTAssertNil(center.readErrors[.claude])
        XCTAssertEqual(center.readErrors[.codex]?.code, "storage")
        XCTAssertEqual(center.loadedProviders, [.claude, .codex])
    }

    func testStopDuringReadDropsLateResults() async throws {
        let (initial, path) = try TestDatabase.createPool()
        try initial.close()
        defer { TestDatabase.cleanup(path: path) }
        let entered = expectation(description: "read entered")
        let release = DispatchSemaphore(value: 0)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction("hold_plan_read", argumentCount: 0) { _ in
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return 1
            })
        }
        let pool = try DatabasePool(path: path, configuration: configuration)
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO plan_usage_status (id,state,updated_at) VALUES (1,'ok','2026-11-02T09:00:00Z')")
            try db.execute(sql: "ALTER TABLE plan_usage_status RENAME TO saved_plan_usage_status")
            try db.execute(sql: "CREATE VIEW plan_usage_status AS SELECT * FROM saved_plan_usage_status WHERE hold_plan_read() = 1")
        }
        var clock = Date(timeIntervalSince1970: 1_793_610_000)
        let center = PlanUsageCenter(dbPool: pool, runner: nil) { clock }
        let task = Task { await center.reload() }
        await fulfillment(of: [entered], timeout: 3)
        let stoppedAt = center.presentationNow
        clock = clock.addingTimeInterval(901)
        center.stop()
        release.signal()
        await task.value
        XCTAssertNil(center.status)
        XCTAssertFalse(center.loadedProviders.contains(.claude))
        XCTAssertEqual(center.presentationNow, stoppedAt, "a stopped provider read must not advance presentation time")
    }

    func testStopDuringBackfillReadDoesNotStartProviderReadsOrNotify() async throws {
        let (initial, path) = try TestDatabase.createPool()
        try initial.close()
        defer { TestDatabase.cleanup(path: path) }
        let entered = expectation(description: "backfill read entered")
        let release = DispatchSemaphore(value: 0)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction("hold_backfill_read", argumentCount: 0) { _ in
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return 1
            })
        }
        let pool = try DatabasePool(path: path, configuration: configuration)
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO plan_usage_status (id,state,fetched_at,updated_at,limits_json)
                VALUES (1,'ok','2026-11-02T09:59:00Z','2026-11-02T09:59:00Z',
                '[{"key":"session","label":"5 hours","group":"session","percent":92,
                  "resets_at":"2026-11-02T12:00:00Z","projection":{"state":"hit","hit_at":null,"rate_per_hour":0}}]');
                INSERT INTO history_backfill
                (source_kind,account_id,floor_ts,upper_ts,reached_ts,status,waiting,started_at,updated_at)
                VALUES ('slack',1,0,2592000,1555200,'running','','2026-11-02T09:00:00Z','2026-11-02T09:00:00Z');
                ALTER TABLE history_backfill RENAME TO saved_history_backfill;
                CREATE VIEW history_backfill AS SELECT * FROM saved_history_backfill WHERE hold_backfill_read() = 1;
                """)
        }
        let at = try XCTUnwrap(PlanUsageDates.parse("2026-11-02T10:00:00Z"))
        let notifier = RecordingNotifier()
        let suite = "PlansUsageCenterTests.backfill.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var clock = at
        let center = PlanUsageCenter(dbPool: pool, runner: nil, notifier: notifier, defaults: defaults) { clock }
        var callbacks = 0
        center.onStatus = { _ in callbacks += 1 }
        let task = Task { await center.reload() }
        await fulfillment(of: [entered], timeout: 3)
        let stoppedAt = center.presentationNow
        clock = clock.addingTimeInterval(901)
        center.stop()
        release.signal()
        await task.value
        XCTAssertNil(center.status)
        XCTAssertNil(center.codexStatus)
        XCTAssertNil(center.backfillLine)
        XCTAssertTrue(center.loadedProviders.isEmpty)
        XCTAssertEqual(callbacks, 0)
        XCTAssertTrue(notifier.notices.isEmpty)
        XCTAssertEqual(center.presentationNow, stoppedAt, "a stopped backfill read must not publish a late clock tick")
    }

    func testSuccessfulFeatureLoadReenablesWithoutAnotherLimitsRefresh() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            let limits = """
            [{"key":"session","label":"5 hours","group":"session","percent":4,"window_duration_minutes":300,
              "resets_at":"2026-11-02T12:00:00Z","projection":{"state":"safe","hit_at":null,"rate_per_hour":0}}]
            """
            try db.execute(sql: """
                INSERT INTO plan_usage_status (id,state,fetched_at,updated_at,limits_json)
                VALUES (1,'ok','2026-11-02T09:59:00Z','2026-11-02T09:59:00Z',?);
                """, arguments: [limits])
        }
        let config = FeatureRunner(state: "disabled")
        let app = AppState.isolated(featuresRunner: config)
        let manager = app.featureManager
        app.wireFeatureVisibility()
        await manager.load()
        let cli = CapturedRunner(result: CLICapturedResult(
            stdout: envelope(provider: "codex", error: "feature_disabled", enabled: false), exitCode: 3))
        app.initPlanUsage(dbPool: pool, cliRunner: cli, notifier: nil)
        let center = try XCTUnwrap(app.planUsageCenter)
        center.stop()
        defer { center.stop() }
        _ = await center.refresh(.codex)
        await center.reload()
        XCTAssertFalse(center.featureEnabled, "retained ok row is not current config evidence")
        XCTAssertNil(center.menuBarLabel(showText: true))

        config.state = "enabled"
        manager.pending[PlanUsageCenter.featureID] = false // staged UI state is not persisted config.
        await manager.load()
        XCTAssertNil(manager.loadError)
        XCTAssertTrue(app.featureVisibility.disabledFeatureIDs.contains(PlanUsageCenter.featureID))
        XCTAssertTrue(center.featureEnabled, "the successful actual feature load is authoritative")
        await center.reload()
        XCTAssertTrue(center.featureEnabled)
        XCTAssertNil(center.refreshErrors[.codex])
        XCTAssertEqual(cli.calls.count, 1, "periodic DB read does not fetch subscription limits")
        XCTAssertEqual(center.providerStatus(.claude)?.state, "ok")
        XCTAssertNotNil(center.menuBarLabel(showText: true))
        XCTAssertFalse(center.trayLines.isEmpty)
        XCTAssertNotEqual(try center.presentation(.claude).summary, PlansPresentation.reasonText("disabled"))
    }

    func testOlderDisabledEnvelopeDoesNotOverrideNewerFeatureEnableEvent() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let at = try XCTUnwrap(PlanUsageDates.parse("2026-11-02T10:00:00Z"))
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO plan_usage_status (id,state,fetched_at,updated_at,limits_json)
                VALUES (1,'ok','2026-11-02T09:59:00Z','2026-11-02T09:59:00Z',
                '[{"key":"session","label":"5 hours","group":"session","percent":4,
                  "resets_at":"2026-11-02T12:00:00Z","projection":{"state":"safe","hit_at":null,"rate_per_hour":0}}]');
                """)
        }
        let cli = HeldCLIRunner(stdout: envelope(provider: "codex", error: "feature_disabled", enabled: false))
        let center = PlanUsageCenter(dbPool: pool, runner: cli) { at }
        center.setFeatureEnabled(false)
        let refresh = Task { await center.refresh(.codex) }
        await awaitStarted(cli)
        center.setFeatureEnabled(true)
        cli.release()
        let result = await refresh.value
        XCTAssertEqual(result?.code, "feature_disabled", "the completed operation keeps its historical result")
        await center.reload()
        XCTAssertTrue(center.featureEnabled)
        XCTAssertNil(center.providerError(.codex), "obsolete error must not retain disabled copy")
        XCTAssertEqual(center.menuBarLabel(showText: true), "Claude 5h 4%")
        XCTAssertFalse(center.trayLines.isEmpty)
        XCTAssertNotEqual(try center.presentation(.codex).summary, PlansPresentation.reasonText("disabled"))
    }

    func testUnchangedSnapshotReloadInvalidatesMenuWhenClockMakesCodexStale() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO codex_plan_usage_status
                (id,state,fetched_at,updated_at,scope,identity_known,limits_json)
                VALUES (1,'ok','2026-11-02T09:00:00Z','2026-11-02T09:00:00Z',?,1,
                '[{"key":"quota","label":"5 hours","group":"session","percent":42,"window_duration_minutes":300,
                  "resets_at":"2026-11-02T11:00:00Z","projection":{"state":"collecting","hit_at":null,"rate_per_hour":0}}]');
                """, arguments: [String(repeating: "a", count: 64)])
        }
        var clock = try XCTUnwrap(PlanUsageDates.parse("2026-11-02T09:00:00Z"))
        let center = PlanUsageCenter(dbPool: pool, runner: nil) { clock }
        await center.reload()
        XCTAssertEqual(center.menuBarLabel(showText: true), "Codex 5h 42%")
        let changed = ObservationFlag()
        let trayChanged = ObservationFlag()
        let cardChanged = ObservationFlag()
        withObservationTracking {
            _ = center.menuBarLabel(showText: true)
        } onChange: {
            changed.mark()
        }
        withObservationTracking {
            _ = center.trayLines
        } onChange: {
            trayChanged.mark()
        }
        withObservationTracking {
            do { _ = try center.presentation(.codex) } catch { XCTFail("valid fixture must produce a card: \(error)") }
        } onChange: {
            cardChanged.mark()
        }
        clock = clock.addingTimeInterval(901)
        await center.reload() // Same DB row, fresh values compare equal.
        XCTAssertTrue(changed.value, "the menu label must invalidate when freshness changes without a DB write")
        XCTAssertNil(center.menuBarLabel(showText: true))
        XCTAssertTrue(trayChanged.value)
        XCTAssertTrue(cardChanged.value)
        XCTAssertTrue(center.trayLines.isEmpty)
        XCTAssertTrue(try center.presentation(.codex).isStale)
        XCTAssertTrue(try center.presentation(.codex).limits.isEmpty)
    }

    final class ObservationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var changed = false
        var value: Bool { lock.withLock { changed } }
        func mark() { lock.withLock { changed = true } }
    }

    final class RecordingNotifier: PlanUsageNotifying {
        var notices: [PlanUsageNotice] = []
        func sendPlanUsageNotice(_ notice: PlanUsageNotice) { notices.append(notice) }
    }

    final class FeatureRunner: CLIRunnerProtocol {
        var state: String
        init(state: String) { self.state = state }
        func run(args: [String]) async throws -> Data {
            Data("""
            {"features":[{"id":"claude-plan-limits","title":"Plans","description":"","tagline":"","benefits":[],
            "icon":"gauge","state":"\(state)","core":false,"parent":"","config_key":"plan_usage.enabled",
            "cost":"none","feeds_into":[],"sub_toggles":[]}]}
            """.utf8)
        }
    }

    final class CapturedRunner: CLIRunnerProtocol {
        let result: CLICapturedResult
        var calls: [[String]] = []
        init(result: CLICapturedResult) { self.result = result }
        func run(args: [String]) async throws -> Data { result.stdout }
        func capture(args: [String], timeout: TimeInterval) async throws -> CLICapturedResult {
            calls.append(args)
            return result
        }
    }
}
