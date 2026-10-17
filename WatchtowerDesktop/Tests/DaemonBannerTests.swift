import XCTest
import GRDB
import Observation
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// #577: the app-wide "Watchtower isn't running" banner, its Start, and the
/// one daemon start chain.
@MainActor
final class DaemonBannerTests: XCTestCase {
    private var poolPaths: [String] = []

    override func tearDown() {
        poolPaths.forEach(TestDatabase.cleanup(path:))
        poolPaths = []
        super.tearDown()
    }

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.createPool()
        poolPaths.append(path)
        return pool
    }

    private func makeAppState(_ daemon: FakeDaemon) -> AppState {
        let appState = AppState.isolated()
        appState.daemonControlOverride = daemon
        appState.daemonStartVerifyDelay = .zero
        return appState
    }

    /// Waits (bounded) until `condition` holds, re-checking on every change
    /// of what it reads — no sleeping.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async {
        let met = expectation(description: "condition")
        func check() {
            if condition() {
                met.fulfill()
                return
            }
            withObservationTracking { _ = condition() } onChange: {
                Task { @MainActor in check() }
            }
        }
        check()
        await fulfillment(of: [met], timeout: timeout)
    }

    // MARK: - Start

    func testStartWhenAlreadyRunningIsNoFailure() async {
        let daemon = FakeDaemon()
        daemon.running = true
        let appState = makeAppState(daemon)
        appState.daemonStartFailure = "old"
        appState.startDaemonFromBanner()
        await appState.daemonStartChain?.value
        XCTAssertEqual(daemon.starts, 0)
        XCTAssertNil(appState.daemonStartFailure)
    }

    func testStartThatStaysUpClearsTheBanner() async {
        let daemon = FakeDaemon()
        let appState = makeAppState(daemon)
        appState.startDaemonFromBanner()
        await appState.daemonStartChain?.value
        XCTAssertEqual(daemon.starts, 1)
        XCTAssertNil(appState.daemonStartFailure)
    }

    func testStartThatDiesShowsTheFailureWithLogs() async {
        let daemon = FakeDaemon()
        daemon.diesAfterStart = true
        let appState = makeAppState(daemon)
        appState.startDaemonFromBanner()
        await appState.daemonStartChain?.value
        XCTAssertEqual(appState.daemonStartFailure, AppState.daemonDiedAfterStartText)
        XCTAssertEqual(appState.daemonBanner, .failed(AppState.daemonDiedAfterStartText))
    }

    func testFailedStartShowsTheFailure() async {
        let daemon = FakeDaemon()
        daemon.startSucceeds = false
        let appState = makeAppState(daemon)
        appState.startDaemonFromBanner()
        await appState.daemonStartChain?.value
        XCTAssertEqual(appState.daemonStartFailure, AppState.daemonStartFailureText(nil))
    }

    /// Two paths at once run one after the other: the second sees the
    /// first's daemon and starts nothing.
    func testStartsAreSerialized() async {
        let daemon = FakeDaemon()
        daemon.holdRestart = true
        let appState = makeAppState(daemon)
        let restart = appState.enqueueDaemonStart { try? await daemon.restartWaiting() }
        appState.startDaemonFromBanner()
        // FakeDaemon is not observable: yield (bounded) until the restart parks.
        for _ in 0..<10_000 where !daemon.isRestartParked { await Task.yield() }
        XCTAssertTrue(daemon.isRestartParked)
        XCTAssertEqual(daemon.starts, 0, "the banner's start waits for the restart")
        daemon.releaseRestart()
        await restart.value
        await appState.daemonStartChain?.value
        XCTAssertEqual(daemon.starts, 0, "already running after the restart")
        XCTAssertNil(appState.daemonStartFailure)
    }

    // MARK: - Shown after the grace

    func testBannerFollowsNotRunningSince() async throws {
        let appState = AppState.isolated()
        XCTAssertTrue(appState.readinessEnvironmentOverride is FakeReadinessEnvironment)
        let center = appState.readinessCenter
        let fake = try XCTUnwrap(appState.readinessEnvironmentOverride as? FakeReadinessEnvironment)
        center.start(pool: try makePool())
        defer { center.stop() }
        await waitUntil { !center.readiness.isEmpty }
        XCTAssertNil(appState.daemonBanner)

        fake.daemonRunning = false
        fake.daemonNotRunningSince = fake.now.addingTimeInterval(-5)
        center.refresh()
        XCTAssertNil(appState.daemonBanner, "a restart's few seconds show nothing")

        fake.daemonNotRunningSince = fake.now.addingTimeInterval(-FeatureReadiness.daemonDownGrace)
        center.refresh()
        XCTAssertEqual(appState.daemonBanner, .stopped)

        fake.daemonRunning = true
        fake.daemonNotRunningSince = nil
        center.refresh()
        XCTAssertNil(appState.daemonBanner)
    }

    /// The live environment follows `DaemonManager`: a status flip
    /// re-evaluates without a tick (a running row is preparing only while
    /// the daemon runs).
    func testCenterReevaluatesOnDaemonManagerChange() async throws {
        let dir = NSTemporaryDirectory() + "watchtower_test_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let manager = DaemonManager()
        manager.isRunning = true
        let environment = LiveReadinessEnvironment(
            daemon: manager, visibility: FeatureVisibilityStore(), configPath: dir + "/config.yaml"
        ) { dir }
        let pool = try makePool()
        let startedAt = ISO8601DateFormatter().string(from: Date())
        try await pool.write { db in
            try db.execute(
                sql: "INSERT INTO pipeline_runs (pipeline, status, started_at) VALUES ('knowledge-index', 'running', ?)",
                arguments: [startedAt])
        }
        let center = ReadinessCenter(environment: environment, tickInterval: .seconds(3600))
        center.start(pool: pool)
        defer { center.stop() }
        await waitUntil { if case .preparing = center.readiness(for: .knowledgeIndex) { true } else { false } }

        manager.isRunning = false
        await waitUntil { if case .preparing = center.readiness(for: .knowledgeIndex) { false } else { true } }
        XCTAssertFalse(center.daemonDown, "just went down: within the grace")
    }
}
