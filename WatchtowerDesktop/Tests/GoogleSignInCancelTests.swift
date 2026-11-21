import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Cancel for a waiting Google browser sign-in (#2132 G1–G4): the cancel trio
/// on `addAccount`, `relogin` and `reloginLegacyCalendar`, the re-read a
/// Cancel ends with, the legacy arguments, and the revoked-calendar alert's
/// routing. The stand-in CLI (`GatedLoginStub`) blocks until the test lets it
/// go, so nothing waits on the clock.
@MainActor
final class GoogleSignInCancelTests: XCTestCase {
    private func stub(ignoreTerm: Bool = false) throws -> GatedLoginStub {
        let stub = try GatedLoginStub(ignoreTerm: ignoreTerm)
        addTeardownBlock { stub.reap() }
        return stub
    }

    private func pool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        return pool
    }

    /// Counts the model's account reads after setup.
    @MainActor
    private final class ReadCounter {
        var reads = 0
    }

    private func makeVM(_ pool: DatabasePool, cli: String) -> (GoogleAccountsViewModel, FakeDaemonRestarter) {
        let daemon = FakeDaemonRestarter()
        let vm = GoogleAccountsViewModel(dbPool: pool, daemon: daemon) { cli }
        vm.loginEnvironment = { [:] }
        return (vm, daemon)
    }

    /// An account that needs a new sign-in.
    private func brokenAccount(_ pool: DatabasePool, vm: GoogleAccountsViewModel) async throws -> GoogleAccount {
        _ = try await pool.write { db in
            try TestDatabase.insertGoogleAccount(db, email: "team@acme.example", calendarEnabled: true, status: "error")
        }
        await vm.refreshAsync()
        return try XCTUnwrap(vm.accounts.first)
    }

    private func countReads(_ vm: GoogleAccountsViewModel) -> ReadCounter {
        let counter = ReadCounter()
        vm.onAccountsChanged = { counter.reads += 1 }
        return counter
    }

    /// The three sign-ins.
    private enum Flow: CaseIterable {
        case add, relogin, legacy
    }

    /// Starts `flow` and returns its run.
    private func start(_ flow: Flow, _ vm: GoogleAccountsViewModel, account: GoogleAccount) throws -> Task<Void, Never> {
        switch flow {
        case .add: vm.addAccount(calendar: true, gmail: false, clientID: "", clientSecret: "")
        case .relogin: vm.relogin(account)
        case .legacy: vm.reloginLegacyCalendar()
        }
        return try XCTUnwrap(vm.signInTask)
    }

    private func place(_ flow: Flow, account: GoogleAccount) -> GoogleAccountsViewModel.SignInPlace {
        flow == .relogin ? .account(account.id) : .section
    }

    // MARK: - The cancel trio

    /// Start → busy with the place's waiting line; Cancel → idle at once, no
    /// error. The killed run ends with one quiet re-read — a row it saved
    /// part-way shows — and no daemon restart.
    func testCancelEndsAWaitingSignInAndRereads() async throws {
        for flow in Flow.allCases {
            let stub = try stub()
            let pool = try pool()
            let (vm, daemon) = makeVM(pool, cli: stub.path)
            let account = try await brokenAccount(pool, vm: vm)
            let counter = countReads(vm)

            let run = try start(flow, vm, account: account)
            XCTAssertTrue(vm.isConnecting, "\(flow)")
            XCTAssertEqual(vm.signIn, place(flow, account: account), "\(flow)")
            _ = try await stub.nextRun(or: run)
            // The CLI saved a row before the Cancel killed it.
            _ = try await pool.write { db in
                try TestDatabase.insertGoogleAccount(db, email: "new@example.com", status: "error")
            }

            vm.cancelConnect()
            XCTAssertFalse(vm.isConnecting, "\(flow)")
            XCTAssertNil(vm.signIn, "\(flow)")
            XCTAssertNil(vm.error, "\(flow)")

            await run.value // the stub died of the SIGTERM
            XCTAssertFalse(vm.isConnecting, "\(flow)")
            XCTAssertNil(vm.error, "a cancel is silent (\(flow))")
            XCTAssertEqual(counter.reads, 1, "one re-read (\(flow))")
            XCTAssertEqual(vm.accounts.count, 2, "the half-saved account shows (\(flow))")
            XCTAssertNil(vm.daemonRestartTask, "\(flow)")
            XCTAssertEqual(daemon.restartCount, 0, "\(flow)")
        }
    }

    /// Cancel after the CLI already exited leaves the model idle, no error.
    func testCancelAfterTheCLIExitedStaysIdle() async throws {
        for flow in Flow.allCases {
            let stub = try stub()
            let pool = try pool()
            let (vm, _) = makeVM(pool, cli: stub.path)
            let account = try await brokenAccount(pool, vm: vm)

            let run = try start(flow, vm, account: account)
            await stub.release(try await stub.nextRun(or: run), exitCode: 0)
            await run.value
            XCTAssertFalse(vm.isConnecting, "\(flow)")
            XCTAssertNil(vm.signIn, "\(flow)")

            vm.cancelConnect()
            XCTAssertFalse(vm.isConnecting, "\(flow)")
            XCTAssertNil(vm.signIn, "\(flow)")
            XCTAssertNil(vm.error, "\(flow)")
        }
    }

    /// Cancel, start again, the first CLI exits: its stale completion leaves
    /// the second run busy.
    func testAStaleCompletionLeavesTheNewRunBusy() async throws {
        for flow in Flow.allCases {
            let stub = try stub(ignoreTerm: true)
            let pool = try pool()
            let (vm, _) = makeVM(pool, cli: stub.path)
            let account = try await brokenAccount(pool, vm: vm)

            let first = try start(flow, vm, account: account)
            let firstPID = try await stub.nextRun(or: first)
            vm.cancelConnect() // SIGTERM is ignored: the first run lives on
            let second = try start(flow, vm, account: account)
            let secondPID = try await stub.nextRun(or: second)

            await stub.release(firstPID, exitCode: 1)
            await first.value
            XCTAssertTrue(vm.isConnecting, "the new run is still busy (\(flow))")
            XCTAssertEqual(vm.signIn, place(flow, account: account), "\(flow)")
            XCTAssertNil(vm.error, "\(flow)")

            vm.cancelConnect()
            await stub.release(secondPID, exitCode: 1)
            await second.value
            XCTAssertFalse(vm.isConnecting, "\(flow)")
            XCTAssertNil(vm.error, "\(flow)")
        }
    }

    /// A CLI that exited 0 although the Cancel came first finished its
    /// connect: it keeps its normal end (re-read and the daemon policy).
    func testCancelledRunThatConnectedEndsLikeAFinishedOne() async throws {
        for flow in Flow.allCases {
            let stub = try stub(ignoreTerm: true)
            let pool = try pool()
            let (vm, daemon) = makeVM(pool, cli: stub.path)
            let account = try await brokenAccount(pool, vm: vm)

            let run = try start(flow, vm, account: account)
            let pid = try await stub.nextRun(or: run)
            vm.cancelConnect()
            await stub.release(pid, exitCode: 0)
            await run.value
            await vm.daemonRestartTask?.value

            XCTAssertFalse(vm.isConnecting, "\(flow)")
            XCTAssertNil(vm.error, "\(flow)")
            XCTAssertEqual(daemon.restartCount, 1, "\(flow)")
        }
    }

    // MARK: - Legacy calendar login

    /// `stub` behind a script that first logs its arguments.
    private func logging(_ stub: GatedLoginStub) throws -> (path: String, log: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("args.log")
        let script = dir.appendingPathComponent("watchtower")
        try "#!/bin/sh\necho \"$@\" >> '\(log.path)'\nexec '\(stub.path)' \"$@\"\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, log)
    }

    private func args(_ log: URL) throws -> [String] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// The alert's legacy Reconnect runs today's command: the CLI resolves
    /// account #1 itself.
    func testLegacyCalendarLoginArguments() async throws {
        let stub = try stub()
        let cli = try logging(stub)
        let (vm, _) = makeVM(try pool(), cli: cli.path)
        vm.reloginLegacyCalendar()
        let run = try XCTUnwrap(vm.signInTask)
        _ = try await stub.nextRun(or: run)
        XCTAssertEqual(try args(cli.log), ["calendar login --app-return"])
        vm.cancelConnect()
        await run.value
    }

    /// The legacy run waits its turn like every other Google sign-in.
    func testLegacyCalendarLoginGuardsAgainstReentry() throws {
        let (vm, _) = makeVM(try pool(), cli: "/usr/bin/true")
        vm.isConnecting = true
        vm.reloginLegacyCalendar()
        XCTAssertEqual(vm.error, "Another connection is already in progress.")
        XCTAssertNil(vm.signIn)
    }

    // MARK: - G4: the revoked-calendar alert's Reconnect

    private func appState(_ vm: GoogleAccountsViewModel) -> AppState {
        let appState = AppState.isolated()
        appState.googleAccountsViewModel = vm
        return appState
    }

    /// The alert names an account that exists: its own Re-login, on Calendar.
    func testReconnectReloginsTheFlaggedAccount() async throws {
        let stub = try stub()
        let cli = try logging(stub)
        let pool = try pool()
        let (vm, _) = makeVM(pool, cli: cli.path)
        let account = try await brokenAccount(pool, vm: vm)
        let appState = appState(vm)

        appState.reconnectGoogleCalendar(accountID: account.id)
        XCTAssertEqual(appState.selectedDestination, .calendar)
        XCTAssertEqual(vm.signIn, .account(account.id))
        let run = try XCTUnwrap(vm.signInTask)
        _ = try await stub.nextRun(or: run)
        XCTAssertEqual(try args(cli.log), ["google login --account \(account.id) --app-return --calendar"])

        vm.cancelConnect()
        await run.value
        XCTAssertFalse(vm.isConnecting)
        XCTAssertNil(vm.error)
    }

    /// No account named, or one that no longer exists: the legacy login.
    func testReconnectWithoutAnAccountRunsTheLegacyLogin() async throws {
        for accountID in [nil, 99] as [Int?] {
            let stub = try stub()
            let cli = try logging(stub)
            let pool = try pool()
            let (vm, _) = makeVM(pool, cli: cli.path)
            _ = try await brokenAccount(pool, vm: vm)
            let appState = appState(vm)

            appState.reconnectGoogleCalendar(accountID: accountID)
            XCTAssertEqual(appState.selectedDestination, .calendar)
            XCTAssertEqual(vm.signIn, .section)
            let run = try XCTUnwrap(vm.signInTask)
            _ = try await stub.nextRun(or: run)
            XCTAssertEqual(try args(cli.log), [GoogleAccountsViewModel.legacyCalendarLoginArgs.joined(separator: " ")])

            vm.cancelConnect()
            await run.value
            XCTAssertFalse(vm.isConnecting)
            XCTAssertNil(vm.error)
        }
    }

    /// N2: before the first accounts read (or after a failed one) the
    /// flagged account is not "gone": it re-logs by its id, never the legacy
    /// account-#1 login.
    func testReconnectBeforeTheFirstReadReloginsTheFlaggedID() async throws {
        let stub = try stub()
        let cli = try logging(stub)
        let (vm, _) = makeVM(try pool(), cli: cli.path)
        XCTAssertFalse(vm.hasRead)
        let appState = appState(vm)

        appState.reconnectGoogleCalendar(accountID: 7)
        XCTAssertEqual(vm.signIn, .account(7))
        let run = try XCTUnwrap(vm.signInTask)
        _ = try await stub.nextRun(or: run)
        XCTAssertEqual(try args(cli.log), ["google login --account 7 --app-return"])

        vm.cancelConnect()
        await run.value
        XCTAssertNil(vm.error)
    }

    // MARK: - Cancel between the launch check and the launch

    /// A Cancel that lands after the launch check found nothing running to
    /// terminate: the child is stopped as soon as it exists, and the run
    /// ends as a cancelled one (a quiet re-read, no daemon restart).
    func testCancelBeforeTheLaunchStopsTheChild() async throws {
        let stub = try stub()
        let pool = try pool()
        let (vm, daemon) = makeVM(pool, cli: stub.path)
        let account = try await brokenAccount(pool, vm: vm)
        let counter = countReads(vm)
        let entered = AsyncGate()
        let held = AsyncGate()
        vm.beforeLaunch = { entered.release(); await held.wait() }

        vm.relogin(account)
        let run = try XCTUnwrap(vm.signInTask)
        await entered.wait()
        vm.cancelConnect()
        held.release()
        // Killed before or after it announced itself; were it left running,
        // exiting 0 here would end it as a connect and fail below, not hang.
        if let pid = try? await stub.nextRun(or: run) {
            await stub.release(pid, exitCode: 0, or: run)
        }
        await run.value

        XCTAssertFalse(vm.isConnecting)
        XCTAssertNil(vm.error)
        XCTAssertEqual(counter.reads, 1)
        XCTAssertNil(vm.daemonRestartTask)
        XCTAssertEqual(daemon.restartCount, 0)
    }
}
