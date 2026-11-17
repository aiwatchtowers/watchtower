import Foundation
@testable import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport
import XCTest

/// The always-on daemon (mobile Inbox spec §3 "Always on from launch"):
/// every launch that opens the database starts it after the compaction
/// step, with `--no-sync` until onboarding finishes; the finish restarts it
/// with sync; the tower's Retry and version restart go through the start
/// queue. A fake daemon; nothing spawns a process.
@MainActor
final class DaemonLaunchSequenceTests: XCTestCase {
    private var dbManager: DatabaseManager?
    private var dbPath: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
    }

    override func tearDown() async throws {
        await AppState.stopIsolatedSidebarCounts()
        if let dbPath { TestDatabase.cleanup(path: dbPath) }
    }

    private func makeAppState(open: @escaping @Sendable () throws -> DatabaseManager) -> (AppState, FakeDaemon) {
        let appState = AppState.isolated(openDatabase: open)
        let daemon = FakeDaemon()
        appState.daemonControlOverride = daemon
        return (appState, daemon)
    }

    private func opensTheTestDatabase() throws -> @Sendable () throws -> DatabaseManager {
        let manager = try XCTUnwrap(dbManager)
        return { manager }
    }

    func testLaunchStartsADaemonWithNoSyncBeforeOnboardingFinishes() async throws {
        let (appState, daemon) = makeAppState(open: try opensTheTestDatabase())
        var phaseAtStart: DatabaseCompactionStep.Phase?
        daemon.onStart = { [weak appState] in phaseAtStart = appState?.databaseCompaction.phase }

        await appState.openDatabaseAndStartDaemon()
        await appState.daemonStartChain?.value

        XCTAssertTrue(appState.needsOnboarding)
        XCTAssertEqual(daemon.startNoSync, [true], "one start, without sync")
        XCTAssertEqual(phaseAtStart, .finished, "after the compaction step")
    }

    func testOnboardingFinishRestartsWithoutNoSync() async throws {
        let (appState, daemon) = makeAppState(open: try opensTheTestDatabase())
        await appState.openDatabaseAndStartDaemon()
        await appState.daemonStartChain?.value
        XCTAssertTrue(daemon.running)

        // What onboarding's finish runs (`OnboardingCompletion.finish`'s startDaemon).
        appState.bringUpDaemonInBackground(startOnly: false)
        await appState.daemonStartChain?.value

        XCTAssertEqual(daemon.startNoSync, [true])
        XCTAssertEqual(daemon.restartNoSync, [false], "the finish restarts it with sync")
    }

    func testLaunchAfterOnboardingStartsWithSync() async throws {
        let (appState, daemon) = makeAppState(open: try opensTheTestDatabase())
        appState.onboarding.goTo(.complete)

        await appState.openDatabaseAndStartDaemon()
        await appState.daemonStartChain?.value

        XCTAssertFalse(appState.needsOnboarding)
        XCTAssertEqual(daemon.startNoSync, [false])
    }

    /// A fresh install has no workspace, so its launch cannot open the
    /// database and starts nothing (`sync --daemon` needs a workspace);
    /// onboarding's open, once Goals created one, starts the daemon without sync.
    func testFreshInstallStartsTheDaemonWhenOnboardingOpensTheDatabase() async throws {
        let opens = OpenAttempts(manager: try XCTUnwrap(dbManager))
        let (appState, daemon) = makeAppState { try opens.open() }

        await appState.openDatabaseAndStartDaemon()
        await appState.daemonStartChain?.value
        XCTAssertTrue(appState.needsOnboarding)
        XCTAssertEqual(daemon.starts, 0, "no workspace yet")

        let failure = await appState.openDatabaseForOnboarding()
        await appState.daemonStartChain?.value

        XCTAssertNil(failure)
        XCTAssertEqual(daemon.startNoSync, [true])
    }

    /// Two Retries before the start completes queue one start: the second
    /// joins the first. The daemon dies right after starting, so a second
    /// queued item would find it down and start again — only the join
    /// keeps the count at one.
    func testTowerRetryAfterDownEnqueuesADaemonStart() async throws {
        let (appState, daemon) = makeAppState(open: try opensTheTestDatabase())
        appState.needsOnboarding = true
        daemon.diesAfterStart = true
        daemon.holdStart = true

        let first = Task { await appState.startDaemonForTower() }
        await untilTurn { daemon.isStartParked }
        let second = Task { await appState.startDaemonForTower() }
        await Task.yield()
        XCTAssertEqual(daemon.starts, 1)

        // Nothing parks after this: a second queued start (no join) would
        // run at once and be counted, not hang.
        daemon.holdStart = false
        daemon.releaseStart()
        await first.value
        await second.value
        await appState.daemonStartChain?.value
        XCTAssertEqual(daemon.startNoSync, [true], "one start, never a second while one is queued")

        // Once it has run, a new Retry queues a new start.
        await appState.startDaemonForTower()
        XCTAssertEqual(daemon.starts, 2)
    }

    /// "Run setup again" re-enters onboarding with a syncing daemon: a start
    /// or restart meanwhile keeps sync.
    func testRunSetupAgainKeepsSync() async throws {
        let (appState, daemon) = makeAppState(open: try opensTheTestDatabase())
        appState.needsOnboarding = true
        XCTAssertTrue(appState.daemonRunsWithoutSync, "a first run")

        appState.startOnboarding(enabledFeatureIDs: [], configuredLanguage: nil)
        daemon.running = true
        _ = await appState.restartDaemonForTower()

        XCTAssertTrue(appState.needsOnboarding)
        XCTAssertFalse(appState.daemonRunsWithoutSync)
        XCTAssertEqual(daemon.restartNoSync, [false])
    }

    func testTowerVersionMismatchRestartsOnTheQueue() async throws {
        let (appState, daemon) = makeAppState(open: try opensTheTestDatabase())
        appState.onboarding.goTo(.complete)
        appState.needsOnboarding = false
        daemon.running = true

        let restarted = await appState.restartDaemonForTower()

        XCTAssertTrue(restarted)
        XCTAssertEqual(daemon.restartNoSync, [false])

        daemon.restartError = DaemonRestartError.cliNotFound
        let failed = await appState.restartDaemonForTower()
        XCTAssertFalse(failed)
        XCTAssertNotNil(appState.daemonStartFailure)
    }
}

/// The first open fails (a fresh install: no workspace); later ones open.
private final class OpenAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private let manager: DatabaseManager

    init(manager: DatabaseManager) {
        self.manager = manager
    }

    func open() throws -> DatabaseManager {
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        guard attempt > 1 else { throw WatchtowerDatabaseError.databaseNotFound }
        return manager
    }
}
