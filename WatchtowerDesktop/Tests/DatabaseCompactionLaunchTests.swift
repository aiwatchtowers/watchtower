import Foundation
import SwiftUI
import ViewInspector
@testable import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport
import XCTest

/// The launch's migrate → compact → open order and the daemon-start gate
/// around the compaction step (#850, spec D5). The step runs against a fake
/// CLI and child; nothing spawns a process.
@MainActor
final class DatabaseCompactionLaunchTests: XCTestCase {
    private let calls = LaunchLog()
    private let child = LaunchFakeChild()
    private let sleeper = LaunchFakeSleeper()

    override func tearDown() async throws {
        // A child the test left running exits, so no launch stays parked.
        child.exit(status: 0)
        sleeper.releaseAll()
    }

    // MARK: - Order

    func testLaunchOrderMigrateCompactOpen() async {
        let due = makeAppState(due: true)
        let launch = Task { await due.appState.migrateCompactOpen() }
        await until { due.appState.databaseCompactionInProgress && self.calls.items.contains("startCompact") }
        child.exit(status: 0, stdout: #"{"compacted":true,"reason":"migration:134"}"#)
        _ = await launch.value
        XCTAssertEqual(calls.items, ["migrate", "check", "stopDaemon", "startCompact", "open"])

        let notDueCalls = LaunchLog()
        let notDue = makeAppState(due: false, calls: notDueCalls)
        _ = await notDue.appState.migrateCompactOpen()
        XCTAssertEqual(notDueCalls.items, ["migrate", "check", "open"])
    }

    func testOnboardingOpenStillMigrates() async {
        let made = makeAppState(due: true)
        let failure = await made.appState.openDatabaseForOnboarding()
        XCTAssertNotNil(failure, "the fake open throws")
        XCTAssertEqual(calls.items, ["migrate", "open"], "no compaction outside the launch")
    }

    // MARK: - Daemon gate

    func testDaemonStartsAreNoOpsDuringCompaction() async throws {
        let made = makeAppState(due: true)
        let appState = made.appState
        let daemon = made.daemon
        let launch = Task { await appState.migrateCompactOpen() }
        await until { appState.databaseCompactionInProgress && self.calls.items.contains("startCompact") }

        appState.ensureDaemonRunning()
        appState.bringUpDaemonInBackground(startOnly: false)
        appState.startDaemonFromBanner()
        try await appState.restartOnChain(daemon)
        let disconnected = await appState.disconnectSlackOnQueue(
            stop: {}, disconnect: { true }, start: { self.calls.append("slackStart") }
        )
        await appState.daemonStartChain?.value
        XCTAssertTrue(disconnected)
        XCTAssertEqual(daemon.starts, 0)
        XCTAssertEqual(daemon.restarts, 0)
        XCTAssertFalse(appState.isStartingDaemon)
        XCTAssertFalse(calls.items.contains("slackStart"))

        child.exit(status: 0)
        _ = await launch.value
        // The launch goes on to its own `ensureDaemonRunning`.
        appState.ensureDaemonRunning()
        await appState.daemonStartChain?.value
        XCTAssertEqual(daemon.starts, 1)
    }

    /// Starts enqueued before the step began, held behind a slow item, re-check
    /// the gate when they run: none starts a daemon while the step compacts.
    func testQueuedStartsRecheckTheGateWhenTheyRun() async throws {
        let made = makeAppState(due: true)
        let appState = made.appState
        let daemon = made.daemon
        let blocker = LaunchFakeSleeper()
        appState.enqueueDaemonStart { await blocker.sleep() }
        await until { blocker.pendingCount == 1 }

        appState.ensureDaemonRunning()
        appState.bringUpDaemonInBackground(startOnly: false)
        appState.startDaemonFromBanner()
        let beforeRestart = appState.daemonStartChain
        let restart = Task { try await appState.restartOnChain(daemon) }
        await until { appState.daemonStartChain != beforeRestart }
        let beforeDisconnect = appState.daemonStartChain
        let disconnect = Task {
            await appState.disconnectSlackOnQueue(stop: {}, disconnect: { true }, start: { self.calls.append("slackStart") })
        }
        await until { appState.daemonStartChain != beforeDisconnect }
        XCTAssertTrue(appState.isStartingDaemon, "the banner Start is queued, not refused")

        // The step's daemon stop queues behind the blocker and the starts.
        let launch = Task { await appState.migrateCompactOpen() }
        await until { self.calls.items.contains("check") && appState.databaseCompactionInProgress }
        XCTAssertFalse(calls.items.contains("stopDaemon"), "the stop waits for the start already running")
        blocker.releaseAll()
        await until { self.calls.items.contains("startCompact") }
        XCTAssertEqual(calls.items, ["migrate", "check", "stopDaemon", "startCompact"])
        try await restart.value
        let disconnected = await disconnect.value
        await appState.daemonStartChain?.value
        XCTAssertTrue(disconnected)
        XCTAssertEqual(daemon.starts, 0)
        XCTAssertEqual(daemon.restarts, 0)
        XCTAssertFalse(appState.isStartingDaemon)
        XCTAssertFalse(calls.items.contains("slackStart"))

        child.exit(status: 0)
        _ = await launch.value
    }

    /// The gate is up from before the migration: a restart asked for while
    /// `db migrate` runs starts no daemon during the step either.
    func testRestartDuringMigrateIsDeferred() async throws {
        let migrateGate = DispatchSemaphore(value: 0)
        // Never leave the migrate thread parked, even on a failed assertion.
        defer { migrateGate.signal() }
        let made = makeAppState(due: true, migrateGate: migrateGate)
        let appState = made.appState
        let launch = Task { await appState.migrateCompactOpen() }
        await until { self.calls.items.contains("migrate") }
        XCTAssertTrue(appState.daemonStartBlocked("test"))

        try await appState.restartOnChain(made.daemon)
        appState.bringUpDaemonInBackground(startOnly: false)
        migrateGate.signal()
        await until { appState.databaseCompactionInProgress && self.calls.items.contains("startCompact") }
        await appState.daemonStartChain?.value
        XCTAssertEqual(made.daemon.restarts, 0)
        XCTAssertEqual(made.daemon.starts, 0)

        child.exit(status: 0)
        _ = await launch.value
        XCTAssertFalse(appState.daemonStartBlocked("test"), "the gate drops once the steps end")
    }

    // MARK: - Daemon restore

    /// The step stopped the daemon and the database then did not open: a
    /// finished install brings the daemon back.
    func testOpenFailureAfterStopRestoresDaemon() async {
        let made = makeAppState(due: true)
        made.appState.onboarding.goTo(.complete)
        await launchThroughOpenFailure(made.appState)
        await made.appState.daemonStartChain?.value
        XCTAssertTrue(made.appState.databaseCompaction.stoppedDaemon)
        XCTAssertEqual(made.daemon.starts, 1)
    }

    func testOpenFailureDuringOnboardingDoesNotStartDaemon() async {
        let made = makeAppState(due: true)
        await launchThroughOpenFailure(made.appState)
        await made.appState.daemonStartChain?.value
        XCTAssertTrue(made.appState.needsOnboarding)
        XCTAssertEqual(made.daemon.starts, 0)
    }

    func testOpenFailureWithoutStopDoesNotStartDaemon() async {
        let made = makeAppState(due: false)
        made.appState.onboarding.goTo(.complete)
        await launchThroughOpenFailure(made.appState)
        await made.appState.daemonStartChain?.value
        XCTAssertFalse(made.appState.databaseCompaction.stoppedDaemon)
        XCTAssertEqual(made.daemon.starts, 0)
    }

    /// A restart refused while `db migrate` runs, compaction not due (the
    /// daemon never stopped), and the database then does not open: the
    /// restore restarts the running daemon so it reads the new config.
    func testOpenFailureReplaysRestartDeferredDuringMigrate() async throws {
        let migrateGate = DispatchSemaphore(value: 0)
        defer { migrateGate.signal() }
        let made = makeAppState(due: false, migrateGate: migrateGate)
        made.daemon.running = true
        made.appState.onboarding.goTo(.complete)
        let launch = Task { await made.appState.migrateCompactOpen() }
        await until { self.calls.items.contains("migrate") }
        try await made.appState.restartOnChain(made.daemon)
        XCTAssertEqual(made.daemon.restarts, 0)

        migrateGate.signal()
        guard case .failure(let error) = await launch.value else {
            return XCTFail("the fake open throws")
        }
        await made.appState.handleLaunchDatabaseFailure(error)
        await made.appState.daemonStartChain?.value
        XCTAssertFalse(made.appState.databaseCompaction.stoppedDaemon)
        XCTAssertEqual(made.daemon.restarts, 1)
        XCTAssertEqual(made.daemon.starts, 0)
        XCTAssertFalse(made.appState.deferredRestartDuringLaunch, "the flag is cleared once replayed")
    }

    func testDaemonStartsWorkAgainAfterStep() async {
        let made = makeAppState(due: false)
        _ = await made.appState.migrateCompactOpen()
        XCTAssertEqual(made.appState.databaseCompaction.phase, .finished)
        XCTAssertFalse(made.appState.databaseCompactionInProgress)

        made.appState.startDaemonFromBanner()
        await made.appState.daemonStartChain?.value
        XCTAssertEqual(made.daemon.starts, 1)
    }

    // MARK: - Quit

    /// Review Focus 1: ⌘Q while the step compacts SIGTERMs the child before
    /// the daemon stop, and the launch starts no daemon after it.
    func testQuitDuringCompactionTerminatesChild() async throws {
        child.exitsOnTerminate = true
        let made = makeAppState(due: true)
        let appState = made.appState
        let launch = Task { await appState.migrateCompactOpen() }
        await until { appState.databaseCompactionInProgress && self.calls.items.contains("startCompact") }

        await TrayAppDelegate.stopDaemonForQuit(appState) { self.calls.append("quitStopDaemon") }
        XCTAssertEqual(child.terminateCount, 1)
        _ = await launch.value
        let items = calls.items
        XCTAssertEqual(Array(items.prefix(5)), ["migrate", "check", "stopDaemon", "startCompact", "terminate"])
        XCTAssertLessThan(
            try XCTUnwrap(items.firstIndex(of: "terminate")), try XCTUnwrap(items.firstIndex(of: "quitStopDaemon")),
            "the child goes before the daemon stop"
        )

        appState.ensureDaemonRunning()
        await appState.daemonStartChain?.value
        XCTAssertEqual(made.daemon.starts, 0, "a quitting app starts no daemon")
    }

    func testQuitBeforeTheStepSkipsIt() async {
        let made = makeAppState(due: true)
        await TrayAppDelegate.stopDaemonForQuit(made.appState) {}
        _ = await made.appState.migrateCompactOpen()
        XCTAssertEqual(calls.items, ["migrate", "open"])
        XCTAssertEqual(child.terminateCount, 0)
    }

    func testQuitAfterTheStepLeavesDaemonStartsAlone() async {
        let made = makeAppState(due: false)
        _ = await made.appState.migrateCompactOpen()
        await TrayAppDelegate.stopDaemonForQuit(made.appState) {}
        XCTAssertFalse(made.appState.quitDuringCompaction)
        made.appState.ensureDaemonRunning()
        await made.appState.daemonStartChain?.value
        XCTAssertEqual(made.daemon.starts, 1)
    }

    // MARK: - Splash and notice

    func testSplashShowsProgressAndSkipFrom15Seconds() async throws {
        let made = makeAppState(due: true, dbBytes: 2_000_000_000)
        let step = made.appState.databaseCompaction
        let launch = Task { await made.appState.migrateCompactOpen() }
        await until { self.sleeper.pendingCount == 1 }

        let splash = SplashView(compaction: step)
        let line = DatabaseCompactionStep.progressLine(dbBytes: 2_000_000_000, elapsedSeconds: 0)
        XCTAssertNoThrow(try splash.inspect().find(text: line))
        XCTAssertNoThrow(try splash.inspect().find(text: "This happens rarely, usually after an update."))
        XCTAssertThrowsError(try splash.inspect().find(button: "Skip for now"))

        for elapsed in 1...15 {
            sleeper.releaseOne()
            await until { step.elapsedSeconds == elapsed && self.sleeper.pendingCount == 1 }
        }
        try splash.inspect().find(button: "Skip for now").tap()
        XCTAssertEqual(child.terminateCount, 1)

        child.exit(status: 4)
        _ = await launch.value
        XCTAssertThrowsError(try splash.inspect().find(text: "This happens rarely, usually after an update."))
    }

    func testNoticeDismisses() throws {
        var dismissed = false
        let notice = DatabaseCompactionNoticeView(text: "Watchtower could not optimize its database.") {
            dismissed = true
        }
        XCTAssertNoThrow(try notice.inspect().find(text: "Watchtower could not optimize its database."))
        try notice.inspect().find(ViewType.Button.self).tap()
        XCTAssertTrue(dismissed)
    }

    // MARK: - Helpers

    /// `initialize()`'s path through `migrateCompactOpen` when the (fake)
    /// open throws; a due step's child exits 0.
    private func launchThroughOpenFailure(_ appState: AppState) async {
        let launch = Task { await appState.migrateCompactOpen() }
        await until { appState.databaseCompaction.phase == .finished || self.calls.items.contains("startCompact") }
        child.exit(status: 0)
        guard case .failure(let error) = await launch.value else {
            return XCTFail("the fake open throws")
        }
        await appState.handleLaunchDatabaseFailure(error)
    }

    private func makeAppState(
        due: Bool,
        dbBytes: Int64 = 1_000,
        calls: LaunchLog? = nil,
        migrateGate: DispatchSemaphore? = nil
    ) -> (appState: AppState, daemon: FakeDaemon) {
        let calls = calls ?? self.calls
        let sleeper = sleeper
        let cli = LaunchFakeCLI(calls: calls, due: due, dbBytes: dbBytes, child: child)
        child.calls = calls
        let step = DatabaseCompactionStep(
            cli: cli,
            stopDaemon: { calls.append("stopDaemon") },
            sleep: { _ in await sleeper.sleep() },
            log: { _ in }
        )
        let appState = AppState.isolated(
            migrateDatabase: {
                calls.append("migrate")
                migrateGate?.wait()
            },
            openDatabase: {
                calls.append("open")
                throw CocoaError(.fileNoSuchFile)
            },
            databaseCompaction: step
        )
        let daemon = FakeDaemon()
        appState.daemonControlOverride = daemon
        appState.daemonStartWaitBound = .milliseconds(50)
        appState.daemonStartPollInterval = .milliseconds(5)
        return (appState, daemon)
    }

    /// Yields the main actor until `condition` holds; fails after a bounded
    /// number of turns rather than hanging.
    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("condition never held", file: file, line: line)
    }
}

// MARK: - Fakes

private final class LaunchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var items: [String] { lock.withLock { stored } }
    func append(_ item: String) { lock.withLock { stored.append(item) } }
}

private struct LaunchFakeCLI: CompactionCLI {
    let calls: LaunchLog
    let due: Bool
    let dbBytes: Int64
    let child: LaunchFakeChild

    func check() async throws -> CompactionCheck {
        calls.append("check")
        return CompactionCheck(
            due: due, reason: due ? "migration:134" : "", dbBytes: dbBytes, walBytes: 0,
            freeDiskBytes: 10 * dbBytes, needsDiskBytes: 2 * dbBytes, diskOk: true
        )
    }

    func startCompact() throws -> any CompactionChild {
        calls.append("startCompact")
        return child
    }
}

/// A `db compact` child that exits when the test says (or on terminate, when
/// `exitsOnTerminate`).
private final class LaunchFakeChild: CompactionChild, @unchecked Sendable {
    private let lock = NSLock()
    private var result: CompactionExit?
    private var waiter: CheckedContinuation<CompactionExit, Never>?
    private var terminates = 0
    private var exitOnTerminate = false
    private var log: LaunchLog?

    var calls: LaunchLog? {
        get { lock.withLock { log } }
        set { lock.withLock { log = newValue } }
    }

    var terminateCount: Int { lock.withLock { terminates } }
    var exitsOnTerminate: Bool {
        get { lock.withLock { exitOnTerminate } }
        set { lock.withLock { exitOnTerminate = newValue } }
    }

    func terminate() {
        let exits = lock.withLock { terminates += 1; return exitOnTerminate }
        calls?.append("terminate")
        if exits { exit(status: 4, stdout: #"{"compacted":false,"skipped":"interrupted"}"#) }
    }

    func kill() {}

    func exit(status: Int32, stdout: String = "") {
        let exit = CompactionExit(status: status, stdout: Data(stdout.utf8), stderr: "")
        let resume: CheckedContinuation<CompactionExit, Never>? = lock.withLock {
            guard result == nil else { return nil }
            result = exit
            defer { waiter = nil }
            return waiter
        }
        resume?.resume(returning: exit)
    }

    func waitForExit() async -> CompactionExit {
        await withCheckedContinuation { continuation in
            let ready: CompactionExit? = lock.withLock {
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// A one-second sleep that returns only when the test releases it.
private final class LaunchFakeSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Void, Never>] = []

    var pendingCount: Int { lock.withLock { pending.count } }

    func sleep() async {
        await withCheckedContinuation { continuation in
            lock.withLock { pending.append(continuation) }
        }
    }

    func releaseOne() {
        let next = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        next?.resume()
    }

    func releaseAll() {
        let all = lock.withLock { defer { pending = [] }; return pending }
        all.forEach { $0.resume() }
    }
}
