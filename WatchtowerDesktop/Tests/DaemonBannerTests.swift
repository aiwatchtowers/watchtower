import XCTest
import GRDB
import Observation
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// #577: the app-wide "Watchtower isn't running" banner, its Start, and the
/// one daemon start chain.
/// A features CLI that reports memory on: a Turn on only restarts.
private final class EnabledFeaturesRunner: CLIRunnerProtocol, @unchecked Sendable {
    func run(args: [String]) async throws -> Data {
        let row = #"{"id":"memory","title":"memory","description":"d","tagline":"t","benefits":[],"icon":"i","#
            + #""state":"enabled","core":false,"parent":"","config_key":"memory.enabled","#
            + #""cost":"light","feeds_into":[],"sub_toggles":[]}"#
        return Data((#"{"features":["# + row + "]}").utf8)
    }
}

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
        appState.daemonStartWaitBound = .milliseconds(200)
        appState.daemonStartPollInterval = .milliseconds(5)
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

    /// A Turn on during a banner Start waits for its alive check: its
    /// restart's stop half must not read as "started but stopped again".
    func testTurnOnDuringBannerStartIsNoFalseFailure() async {
        let appState = AppState.isolated(featuresRunner: EnabledFeaturesRunner())
        let daemon = FakeDaemon()
        appState.daemonControlOverride = daemon
        appState.daemonStartWaitBound = .seconds(5)
        appState.daemonStartPollInterval = .milliseconds(10)
        daemon.runningAfterChecks = 5
        daemon.stopsDuringRestart = true
        daemon.holdRestart = true

        appState.startDaemonFromBanner()
        let turnOn = Task { await appState.turnOnFeatureFromEmptyState("memory") }
        for _ in 0..<200 where !daemon.isRestartParked { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(daemon.isRestartParked)
        XCTAssertEqual(daemon.starts, 1, "the banner's start ran first")
        XCTAssertNil(appState.daemonStartFailure, "its alive check ran before the restart")
        daemon.releaseRestart()
        await turnOn.value
        await appState.daemonStartChain?.value
        XCTAssertNil(appState.daemonStartFailure)
        XCTAssertNil(appState.emptyStateTurnOnError(for: "memory"))
    }

    // MARK: - Owner's stop and Dismiss

    func testDismissHidesUntilANewStop() async throws {
        let appState = AppState.isolated()
        let fake = try XCTUnwrap(appState.readinessEnvironmentOverride as? FakeReadinessEnvironment)
        let center = appState.readinessCenter
        center.start(pool: try makePool())
        defer { center.stop() }
        await waitUntil { !center.readiness.isEmpty }
        appState.daemonManager.isRunning = false
        fake.daemonRunning = false
        fake.daemonNotRunningSince = fake.now.addingTimeInterval(-60)
        center.refresh()
        XCTAssertEqual(appState.daemonBanner, .stopped)

        appState.dismissDaemonBanner()
        XCTAssertNil(appState.daemonBanner)

        // A start, then a new stop: a new down stretch shows it again.
        appState.daemonManager.isRunning = true
        appState.daemonManager.isRunning = false
        XCTAssertEqual(appState.daemonBanner, .stopped)
    }

    /// One Dismiss hides a failure and "isn't running" together.
    func testDismissHidesBoth() async throws {
        let appState = try await downAppState()
        appState.daemonStartFailure = "boom"
        XCTAssertEqual(appState.daemonBanner, .failed("boom"))
        appState.dismissDaemonBanner()
        XCTAssertNil(appState.daemonBanner)
    }

    /// The daemon stopped, then a Start that fails: the failure shows.
    func testStopThenFailedStartShowsTheBanner() async throws {
        let appState = try await downAppState()
        let daemon = FakeDaemon()
        daemon.startSucceeds = false
        appState.daemonControlOverride = daemon
        XCTAssertEqual(appState.daemonBanner, .stopped)
        appState.startDaemonFromBanner()
        await appState.daemonStartChain?.value
        XCTAssertEqual(appState.daemonBanner, .failed(AppState.daemonStartFailureText(nil)))
    }

    /// A pid file that shows up late (migrations after an update) is no
    /// failure; the banner says Starting… meanwhile and ignores a second Start.
    func testSlowPidIsNoFalseFailure() async {
        let daemon = FakeDaemon()
        daemon.runningAfterChecks = 10
        let appState = makeAppState(daemon)
        appState.daemonStartWaitBound = .seconds(5)
        appState.startDaemonFromBanner()
        XCTAssertEqual(appState.daemonBanner, .starting)
        appState.startDaemonFromBanner()
        await appState.daemonStartChain?.value
        XCTAssertEqual(daemon.starts, 1, "a second Start while starting is ignored")
        XCTAssertNil(appState.daemonStartFailure)
        XCTAssertFalse(appState.isStartingDaemon)
    }

    /// An AppState whose readiness says the daemon has been down past the grace.
    private func downAppState() async throws -> AppState {
        let appState = AppState.isolated()
        appState.daemonStartWaitBound = .milliseconds(200)
        appState.daemonStartPollInterval = .milliseconds(5)
        let fake = try XCTUnwrap(appState.readinessEnvironmentOverride as? FakeReadinessEnvironment)
        let center = appState.readinessCenter
        center.start(pool: try makePool())
        addTeardownBlock { @MainActor in center.stop() }
        await waitUntil { !center.readiness.isEmpty }
        appState.daemonManager.isRunning = false
        fake.daemonRunning = false
        fake.daemonNotRunningSince = fake.now.addingTimeInterval(-60)
        center.refresh()
        return appState
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
