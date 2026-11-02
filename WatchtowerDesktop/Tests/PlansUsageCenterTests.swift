import XCTest
import GRDB
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

@MainActor
final class PlansUsageCenterTests: XCTestCase {
    private func envelope(provider: String, error: String? = nil) -> Data {
        let errorJSON = error.map { "{\"code\":\"\($0)\",\"message\":\"safe\"}" } ?? "null"
        return Data("""
        {"schema_version":1,"requested_provider":"\(provider)","refresh_requested":true,"feature_enabled":true,
         "providers":[{"provider":"\(provider)","ok":\(error == nil ? "true" : "false"),"error":\(errorJSON),
         "refresh_outcome":"\(error == nil ? "updated" : "busy")","status":null}]}
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
        let center = PlanUsageCenter(dbPool: pool, runner: nil)
        let task = Task { await center.reload() }
        await fulfillment(of: [entered], timeout: 3)
        center.stop()
        release.signal()
        await task.value
        XCTAssertNil(center.status)
        XCTAssertFalse(center.loadedProviders.contains(.claude))
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
